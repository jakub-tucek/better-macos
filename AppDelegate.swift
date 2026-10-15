import AppKit
import SwiftUI
import ServiceManagement
import CoreBluetooth
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: DisplayController?
    private var bluetooth: BluetoothModule?
    private var audio: AudioModule?
    private var spaces: SpacesModule?
    private var screenEdges: ScreenEdgeController?
    private var layoutFresh = false
    private lazy var controlLifecycle = SystemControlLifecycle(startCursor: { [weak self] layout in
        guard let self else { return }
        if screenEdges == nil { screenEdges = ScreenEdgeController() }
        try screenEdges?.start(layout: layout)
    }, stopCursor: { [weak self] in self?.screenEdges?.stop() })
    private let animations = AnimationPreferences()
    private let menuBarSpacing = MenuBarSpacing()
    private var menuBar: MenuBarModule?
    private var quitGuard: QuitGuard?
    private var keepAwake: KeepAwakeModule?
    private var windowPositions: WindowPositions?
    private var clipboard: ClipboardModule?
    private let injectedMouseLifecycle: MouseLifecycle?
    private lazy var mouseLifecycle = injectedMouseLifecycle ?? MouseLifecycle(settings: modules)
    private let sourceUpdater = SourceUpdater()
    private let animationQueue = DispatchQueue(label: "fix-mac-os.animation-preferences")
    private let modules: ModuleSettings
    private let preferences: UserDefaults
    private let model: DashboardModel
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var activeSetupDraft: SetupDraft?
    private let uiStore: UISettingsStore
    private var setupPermissionManager: CBCentralManager?
    private let safety = SafetySupervisor()
    private let logger = Logger(subsystem: "io.github.jakub-tucek.mac-utils", category: "Safety")
    private lazy var displayRefresh = DisplayRefreshGate { [weak self] in self?.refreshDisplaySnapshot() }
    private let recoveryQueue = DispatchQueue(label: "mac-utils.display-recovery", qos: .userInitiated)
    private var item: NSStatusItem!
    private var recovering = false
    private var rollbackTimer: Timer?
    private var rollbackDeadline: Date?
    private var rollbackUUID: String?
    private var arrangementWindow: NSWindow?
    private var openArrangementWhenReady = CommandLine.arguments.contains("--arrange")
    private var screenObserver: NSObjectProtocol?
    private var guiTestTarget: String?
    private var guiTestStarted = false
    private var guiTestFinished = false
    private var guiTestOriginalOutput: String?
    private let commandRunner: CommandRunning
    private let transactions = HostTransactions()
    private let terminationReply: (NSApplication, Bool) -> Void

     init(commandRunner: CommandRunning = CommandRunner(), spaces: SpacesModule? = nil, windowPositions: WindowPositions? = nil, clipboard: ClipboardModule? = nil, mouseLifecycle: MouseLifecycle? = nil, model: DashboardModel = DashboardModel(), preferences: UserDefaults = .standard,
         terminationReply: @escaping (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }) {
         self.commandRunner = commandRunner
         self.preferences = preferences
         self.modules = ModuleSettings(defaults: preferences)
         self.uiStore = UISettingsStore(defaults: preferences)
        self.model = model
        self.spaces = spaces
        self.windowPositions = windowPositions
        self.clipboard = clipboard
        self.injectedMouseLifecycle = mouseLifecycle
        self.terminationReply = terminationReply
        super.init()
         configureActions()
         windowPositions?.acceptsActions = { [weak self] in self?.transactions.acceptsActions == true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let legacyInstall = !(preferences.persistentDomain(forName: "local.jakub.monitor-toggle") ?? [:]).isEmpty
        let existingInstall = uiStore.isExistingInstall || legacyInstall
        model.widgetLayout = uiStore.loadLayout(modules: modules.enabled, existing: existingInstall)
        if !existingInstall {
            // A fresh install is inert until explicit Finish. Legacy installs keep every choice.
            for module in AppModule.allCases { modules.set(module, enabled: false) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--test-connect-in-gui"), index + 1 < CommandLine.arguments.count {
            guiTestTarget = CommandLine.arguments[index + 1]
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preserve-audio-output"), index + 1 < CommandLine.arguments.count {
            guiTestOriginalOutput = CommandLine.arguments[index + 1]
        }
        mouseLifecycle.onChange = { [weak self] in
            guard let self else { return }
            model.updateMouseRecovery(required: mouseLifecycle.recoveryRequired, message: mouseLifecycle.errorMessage)
            model.mouseOverrideActive = mouseLifecycle.module?.active == true
            refreshMouseCapability()
        }
        mouseLifecycle.start()
        if menuBarSpacing.recoveryRequired {
            do { try menuBarSpacing.restore() } catch { showError(error) }
        } else if !modules.enabled.contains(.menuBar) {
            do { try menuBarSpacing.restore(preserveChoice: true) } catch { showError(error) }
        }
        sourceUpdater.onChange = { [weak self] in
            guard let self else { return }
            model.updateStatus = sourceUpdater.status
            model.updateChecking = sourceUpdater.isChecking
            model.updateAvailable = sourceUpdater.canInstall
        }
        sourceUpdater.start()
        safety.onStatusChanged = { [weak self] status in
            guard let self else { return }
            if model.watchdogStatus != status { logger.notice("Watchdog status: \(status, privacy: .public)") }
            model.watchdogStatus = status
            model.watchdogReady = safety.isReady
            spaces?.isAvailable = safety.isReady
            if !safety.isReady { spaces?.suspend() }
            refreshPreferences()
            if safety.isReady { displayRefresh.requestRefresh() }
        }
        do { try safety.start() }
        catch { showError(ToggleError(message: "Could not start the recovery watchdog: \(error.localizedDescription)")) }
        displayRefresh.onSettlingChanged = { [weak self] settling in
            guard let self else { return }
            logger.notice("Display refresh settling: \(settling, privacy: .public)")
            model.displaySettling = settling
            if settling { layoutFresh = false }
            refreshPreferences()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Fix macOS")
        item.button?.target = self
        item.button?.action = #selector(toggleDashboard)
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 430, height: 580)
        popover.contentViewController = NSHostingController(rootView: QuickActionsView(model: model))
        updateModules()
        if animations.recoveryRequired {
            setAnimations(false, recoverOnly: true)
        } else if modules.enabled.contains(.spaces) && animations.needsUpdate {
            setAnimations(true, preserveChoice: true)
        }
        refreshPreferences()
        refreshBluetooth()
        displayRefresh.requestRefresh()
        if CommandLine.arguments.contains("--request-bluetooth-access") {
            DispatchQueue.main.async { [weak self] in self?.bluetooth?.requestBluetoothAccess() }
        }
        // Saved gesture activation waits for the watchdog and settled displays.
        switch UILaunchRoute.launch(arguments: CommandLine.arguments) {
        case .settings(let group):
            DispatchQueue.main.async { [weak self] in self?.showSettings(group) }
        case .widget(let kind):
            model.launchWidget = kind
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        case .home:
            if !existingInstall { DispatchQueue.main.async { [weak self] in self?.showSetup() } }
        }
        if CommandLine.arguments.contains("--show-dashboard"), !DashboardNavigation.launch(arguments: CommandLine.arguments).isSetup {
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        }
    }

    // Host-side barrier, not a UI-only disable: callbacks retained by views also
    // consult it at invocation time. Cleanup paths deliberately bypass this gate.
    private var actionHost: AppDelegate? { transactions.acceptsActions ? self : nil }

    private func configureActions() {
        model.onOpenSettings = { [weak self] group in self?.actionHost?.showSettings(group) }
        model.onRunSetup = { [weak self] in self?.actionHost?.showSetup() }
        model.onSaveWidgets = { [weak self] layout in
            guard let self, transactions.acceptsActions else { return }
            var value = layout; value.normalize(); uiStore.save(value); model.widgetLayout = value
        }
        model.onSkipSetup = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            uiStore.complete(); activeSetupDraft?.discardCheckpoint(); SetupDraft.clearCheckpoint(defaults: preferences); setupWindow?.close(); showDashboard()
        }
        model.onFinishSetup = { [weak self] draft, completion in
            guard let self, transactions.acceptsActions else { completion(["Setup was not applied: the app is shutting down."]); return }
            applySetup(draft, completion: completion)
        }
        model.onAccessibilitySettings = { [weak self] in
            guard self?.actionHost != nil,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
            NSWorkspace.shared.open(url)
        }
        model.onAudioSelect = { [weak self] uid, direction in self?.actionHost?.audio?.select(uid, direction: direction) }
        model.onAudioAutomatic = { [weak self] in self?.actionHost?.audio?.automatic = $0 }
        model.onAudioResume = { [weak self] in self?.actionHost?.audio?.resume() }
        model.onAudioPreferences = { [weak self] values, direction in self?.actionHost?.audio?.setPreferences(values, direction: direction) }
        model.onAudioFallback = { [weak self] uid, direction in self?.actionHost?.audio?.setFallback(uid, direction: direction) }
        model.onClipboardRecording = { [weak self] in self?.actionHost?.clipboard?.history.setRecording($0) }
        model.onClipboardOpen = { [weak self] in self?.actionHost?.popover.performClose(nil); self?.actionHost?.clipboard?.show() }
        model.onClipboardClear = { [weak self] in self?.actionHost?.clipboard?.clear() }
        model.onClipboardPersistence = { [weak self] in self?.actionHost?.clipboard?.setPersistence($0) }
        model.onClipboardDays = { [weak self] days in
            guard let module = self?.actionHost?.clipboard else { return }
            module.setRetentionDays(days)
        }
        model.onClipboardExclusions = { [weak self] in self?.actionHost?.clipboard?.setExclusions($0) }
        model.onRestoreMouse = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            mouseLifecycle.restore()
            if !mouseLifecycle.recoveryRequired { refreshMouseCapability(forceDraft: true) }
        }
        model.onRefreshMouse = { [weak self] in self?.actionHost?.refreshMouseCapability(forceDraft: true) }
        model.onApplyMouse = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            mouseLifecycle.apply(acceleration: model.mouseAcceleration, speed: model.mouseTracking)
        }
        model.onKeepAwakeStart = { [weak self] in self?.actionHost?.performKeepAwake { try $0.start() } }
        model.onKeepAwakeStop = { [weak self] in self?.actionHost?.performKeepAwake { try $0.stop() } }
        model.onKeepAwakeExtend = { [weak self] in self?.actionHost?.performKeepAwake { try $0.extend() } }
        model.onKeepAwakeResume = { [weak self] in self?.actionHost?.performKeepAwake { try $0.resumeApps() } }
        model.onKeepAwakeRemoveApp = { [weak self] id in self?.actionHost?.performKeepAwake { try $0.setApp(id, name: id, selected: false) } }
        model.onKeepAwakeAddApp = { [weak self] in
            guard self?.actionHost != nil else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose apps that keep the Mac awake"
            panel.allowedContentTypes = [.applicationBundle]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                self?.actionHost?.performKeepAwake { try $0.setApp(id, name: url.deletingPathExtension().lastPathComponent, selected: true) }
            }
        }
        model.onKeepAwakeMinutesChanged = { [weak self] in self?.actionHost?.keepAwake?.selectedMinutes = $0 }
        model.onKeepDisplayAwakeChanged = { [weak self] enabled in self?.actionHost?.performKeepAwake { try $0.setKeepDisplayAwake(enabled) } }
        model.onQuitGuardChanged = { [weak self] enabled in
            guard let self, transactions.acceptsActions else { return }
            do { try quitGuard?.setEnabled(enabled) } catch { showError(error) }
            refreshQuitGuard()
        }
        model.onQuitGuardDurationChanged = { [weak self] in self?.actionHost?.quitGuard?.duration = $0 }
        model.onRetryQuitGuard = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            do { try quitGuard?.startIfEnabled() } catch { showError(error) }
            refreshQuitGuard()
        }
        model.onCompactMenuBarChanged = { [weak self] enabled in
            guard let self, transactions.acceptsActions else { return }
            do { try menuBarSpacing.setEnabled(enabled) } catch { showError(error) }
            refreshMenuBar()
        }
        model.onRestoreMenuBarSpacing = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            do { try menuBarSpacing.restore() } catch { showError(error) }
            refreshMenuBar()
        }
        model.onMenuBarHidingChanged = { [weak self] in self?.actionHost?.menuBar?.setEnabled($0) }
        model.onToggleMenuBar = { [weak self] in self?.actionHost?.menuBar?.toggle() }
        model.onModuleChanged = { [weak self] module, enabled in self?.actionHost?.setModule(module, enabled: enabled) }
        model.onMonitorChanged = { [weak self] uuid, enabled in self?.actionHost?.setMonitor(uuid, enabled: enabled) }
        model.onMonitorDisableModeChanged = { [weak self] confirm in
            guard let self, transactions.acceptsActions else { return }
            UserDefaults.standard.set(confirm, forKey: "monitors.confirmDisable")
            refreshPreferences()
        }
        model.onMatchScreenEdgesChanged = { [weak self] enabled in
            guard let self, transactions.acceptsActions else { return }
            UserDefaults.standard.set(enabled, forKey: "arrangement.matchEdges")
            refreshPreferences()
            updateScreenEdges()
        }
        model.onKeepDisabled = { [weak self] uuid in
            guard let self, transactions.acceptsActions, rollbackUUID == uuid else { return }
            clearRollback()
        }
        model.onRestoreAll = { [weak self] in self?.actionHost?.restoreAll() }
        model.onArrangeDisplays = { [weak self] in self?.actionHost?.showArrangementEditor() }
        model.onKeepArrangement = { [weak self] in
            guard let self, transactions.acceptsActions, !recovering, rollbackUUID == "layout" else { return }
            UserDefaults.standard.removeObject(forKey: "pendingArrangement")
            UserDefaults.standard.synchronize()
            model.pendingArrangement = false
            clearRollback()
        }
        model.onAutoDeviceChanged = { [weak self] address, enabled in self?.actionHost?.bluetooth?.setAutoReconnect(enabled, for: address) }
        model.onManualConnection = { [weak self] in self?.actionHost?.bluetooth?.toggleConnection($0) }
        model.onAutomaticReconnectChanged = { [weak self] in self?.actionHost?.bluetooth?.autoEnabled = $0 }
        model.onBluetoothPowerOn = { [weak self] in self?.actionHost?.bluetooth?.turnBluetoothOn() }
        model.onBluetoothAccessRequested = { [weak self] in self?.actionHost?.bluetooth?.requestBluetoothAccess() }
        model.onProtectAudioChanged = { [weak self] enabled in self?.actionHost?.bluetooth?.protectOtherAudio = enabled; self?.actionHost?.refreshBluetooth() }
        model.onSwitchAudioChanged = { [weak self] enabled in self?.actionHost?.bluetooth?.switchAudioOutput = enabled; self?.actionHost?.refreshBluetooth() }
        model.onProtectedDeviceChanged = { [weak self] address, enabled in
            guard let self, transactions.acceptsActions else { return }
            if enabled { bluetooth?.protectedAudioAddresses.insert(address) }
            else { bluetooth?.protectedAudioAddresses.remove(address) }
            refreshBluetooth()
        }
        model.onTakeOverLegacy = { [weak self] in self?.actionHost?.bluetooth?.takeOverLegacyService() }
        model.onSpacesChanged = { [weak self] enabled in
            guard let self, transactions.acceptsActions else { return }
            guard !enabled || controlState.inputReady else {
                showError(ToggleError(message: "Wait for the watchdog and pending display changes before enabling Space interception.")); return
            }
            do { try spaces?.setEnabled(enabled) } catch { showError(error) }
            refreshPreferences()
        }
        model.onAnimationsChanged = { [weak self] enabled in self?.actionHost?.setAnimations(enabled) }
        model.onRestoreAnimations = { [weak self] in self?.actionHost?.setAnimations(false, recoverOnly: true) }
        model.onCheckUpdates = { [weak self] in self?.actionHost?.sourceUpdater.check(force: true) }
        model.onInstallUpdate = { [weak self] in
            do { try self?.actionHost?.sourceUpdater.install() } catch { self?.showError(error) }
        }
        model.onSpeedChanged = { [weak self] speed in self?.actionHost?.spaces?.speed = speed; self?.actionHost?.refreshPreferences() }
        model.onLoginChanged = { [weak self] enabled in
            guard let self, transactions.acceptsActions else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { showError(error) }
            refreshPreferences()
        }
        model.onClose = { [weak self] in self?.popover.performClose(nil) }
        model.onQuit = { NSApp.terminate(nil) }
    }

    private func setModule(_ module: AppModule, enabled: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        guard transactions.acceptsActions, !model.stoppingModules.contains(module) else { completion(false); return }
        if module == .clipboard && !enabled && clipboard?.history.flushPendingStorage() == false {
            model.errorMessage = "Clipboard disk cleanup is pending. Retry after storage becomes available."
            completion(false)
            return
        }
        if module == .mouse {
            guard mouseLifecycle.setEnabled(enabled) else { completion(false); return }
            updateModules()
            completion(true)
            return
        }
        if module == .keepAwake && !enabled {
            do { try keepAwake?.deactivate() } catch { keepAwake?.activate(); showError(error); completion(false); return }
        }
        if module == .menuBar && !enabled {
            do { try menuBarSpacing.restore(preserveChoice: true) }
            catch { refreshMenuBar(); showError(error); completion(false); return }
        }
        if module == .spaces {
            guard !model.animationsBusy else { completion(false); return }
            if !animations.enabled && !animations.recoveryRequired {
                modules.set(module, enabled: enabled); updateModules(); completion(true); return
            }
            setAnimations(enabled && animations.enabled, preserveChoice: true) { [weak self] in
                guard let self else { return }
                modules.set(module, enabled: enabled)
                updateModules()
            } resultCompletion: { completion($0) }
            return
        }
        if module == .monitors || module == .arrangement {
            guard !recovering else { showError(ToggleError(message: "Wait for the current display operation to finish.")); completion(false); return }
            if !enabled && (model.disabledMonitorCount > 0 || model.pendingArrangement || rollbackUUID != nil) {
                model.stoppingModules.insert(module)
                restoreAll { [weak self] restored in
                    guard let self else { return }
                    model.stoppingModules.remove(module)
                    if restored { modules.set(module, enabled: false); updateModules() }
                    completion(restored)
                }
                return
            }
        }
        modules.set(module, enabled: enabled)
        updateModules()
        completion(true)
    }

    private func performKeepAwake(_ action: (KeepAwakeModule) throws -> Void) {
        guard let keepAwake else { return }
        do { try action(keepAwake) } catch { showError(error) }
        refreshKeepAwake()
    }

    private func refreshKeepAwake() {
        model.keepAwakeActive = keepAwake?.active ?? false
        model.keepAwakeCanStop = keepAwake?.canStop ?? false
        model.keepAwakeRemaining = keepAwake?.remaining ?? 0
        model.keepAwakeMinutes = keepAwake?.selectedMinutes ?? 30
        model.keepAwakeApps = keepAwake?.selectedApps ?? [:]
        model.keepAwakeAppNames = keepAwake?.activeAppNames ?? []
        model.keepAwakeAppsPaused = keepAwake?.appsPaused ?? false
        model.keepAwakeProtectionFailed = keepAwake?.protectionFailed ?? false
        model.keepDisplayAwake = keepAwake?.keepDisplayAwake ?? false
        item?.button?.image = NSImage(systemSymbolName: model.keepAwakeActive ? DashboardTab.keepAwake.symbol : "slider.horizontal.3", accessibilityDescription: model.keepAwakeActive ? "Fix macOS — Keep awake active" : "Fix macOS")
        item?.button?.toolTip = model.keepAwakeProtectionFailed ? "Fix macOS — keep awake needs retry" : (model.keepAwakeActive ? "Fix macOS — keeping awake" : "Fix macOS")
        publishModuleStatus()
    }

    private func refreshQuitGuard() {
        model.quitGuardEnabled = quitGuard?.enabled ?? false
        model.quitGuardActive = quitGuard?.isRunning ?? false
        model.quitGuardDuration = quitGuard?.duration ?? 3
        publishModuleStatus()
    }

    private func refreshMenuBar() {
        model.compactMenuBar = menuBarSpacing.enabled
        model.menuBarRecoveryRequired = menuBarSpacing.recoveryRequired
        model.menuBarHiding = menuBar?.enabled ?? false
        model.menuBarHidden = menuBar?.hidden ?? false
        publishModuleStatus()
    }

    private func updateModules() {
        model.enabledModules = modules.enabled
        if modules.enabled.contains(.windows) {
            if windowPositions == nil {
                let module = WindowPositions()
                module.acceptsActions = { [weak self] in self?.transactions.acceptsActions == true }
                module.onWake = { [weak self] in self?.displayRefresh.requestRefresh() }
                module.start()
                windowPositions = module
            }
        } else {
            windowPositions?.stop()
            windowPositions = nil
        }
        model.windowPositions = windowPositions
        if !modules.enabled.isDisjoint(with: [.audio, .bluetooth]) {
            if audio == nil {
                let module = AudioModule()
                audio = module
                module.onChange = { [weak self] in self?.refreshAudio() }
                module.bluetoothProtection = { [weak self] in
                    guard let self else { return .unavailable }
                    return bluetooth?.audioProtection ?? (modules.enabled.contains(.bluetooth) ? .unavailable : .clear)
                }
                module.bluetoothRequestIsCurrent = { [weak self] name in self?.bluetooth?.audioRequestIsCurrent(name: name) == true }
                module.bluetoothPolicyGeneration = { [weak self] in self?.bluetooth?.audioPolicyGeneration }
                module.suspendRouting = guiTestTarget != nil
                module.automaticAllowed = modules.enabled.contains(.audio)
                module.start()
            }
            audio?.automaticAllowed = modules.enabled.contains(.audio)
        } else { audio?.stop(); audio = nil }
        refreshAudio()
        if modules.enabled.contains(.clipboard) {
            if clipboard == nil {
                let module = ClipboardModule()
                clipboard = module
                module.onChange = { [weak self] in self?.refreshClipboard() }
                module.onError = { [weak self] in self?.model.errorMessage = $0 }
                module.start()
            }
        } else {
            clipboard?.stop()
            clipboard = nil
        }
        refreshClipboard()
        mouseLifecycle.reconcile()
        if modules.enabled.contains(.keepAwake) {
            if keepAwake == nil {
                let module = KeepAwakeModule()
                keepAwake = module
                module.onChange = { [weak self] in self?.refreshKeepAwake() }
                module.onError = { [weak self] in self?.showError($0) }
                module.activate()
            }
        } else {
            keepAwake?.onChange = nil
            keepAwake = nil
        }
        refreshKeepAwake()
        if modules.enabled.contains(.quitGuard) {
            if quitGuard == nil {
                let module = QuitGuard()
                quitGuard = module
                module.onChange = { [weak self] in self?.refreshQuitGuard() }
                module.onError = { [weak self] error in
                    self?.showError(error)
                    self?.model.tab = .keyboard
                    self?.showDashboard()
                }
                do { try module.startIfEnabled() } catch { showError(error) }
            }
        } else {
            quitGuard?.onChange = nil
            quitGuard?.stop()
            quitGuard = nil
        }
        refreshQuitGuard()
        if modules.enabled.contains(.menuBar) {
            if menuBar == nil {
                let module = MenuBarModule()
                module.onChange = { [weak self] in self?.refreshMenuBar() }
                module.onError = { [weak self] error in
                    self?.showError(error)
                    self?.model.tab = .menuBar
                    self?.showDashboard()
                }
                menuBar = module
                module.start()
                if menuBarSpacing.needsApply && !menuBarSpacing.recoveryRequired {
                    do { try menuBarSpacing.setEnabled(true) } catch { showError(error) }
                }
            }
        } else {
            menuBar?.stop()
            menuBar = nil
        }
        refreshMenuBar()
        if modules.enabled.contains(.bluetooth) {
            if bluetooth == nil {
                let module = BluetoothModule()
                bluetooth = module
                module.onAudioOutputRequested = { [weak self] name in self?.audio?.bluetoothConnected(name: name) }
                module.suspendAutomaticReconnection = guiTestTarget != nil
                module.onChange = { [weak self] in self?.refreshBluetooth() }
                module.onError = { [weak self] in self?.showError($0) }
                module.start()
            }
        } else if let module = bluetooth, !model.stoppingModules.contains(.bluetooth) {
            model.stoppingModules.insert(.bluetooth)
            module.onChange = nil
            module.onError = nil
            module.stop { [weak self, weak module] in
                guard let self, bluetooth === module else { return }
                bluetooth = nil
                model.stoppingModules.remove(.bluetooth)
                refreshBluetooth()
                refreshPreferences()
            }
        }
        if modules.enabled.contains(.spaces) {
            if spaces == nil {
                spaces = SpacesModule()
                spaces?.onChange = { [weak self] in self?.refreshPreferences() }
            }
            spaces?.isAvailable = safety.isReady
        } else if let module = spaces, !model.stoppingModules.contains(.spaces) {
            model.stoppingModules.insert(.spaces)
            module.onChange = nil
            module.stop { [weak self, weak module] in
                guard let self, spaces === module else { return }
                spaces = nil
                model.stoppingModules.remove(.spaces)
                refreshPreferences()
            }
        }
        if !modules.enabled.contains(.arrangement) {
            screenEdges?.stop()
            screenEdges = nil
            arrangementWindow?.close()
            arrangementWindow?.contentView = nil
            arrangementWindow = nil
            model.currentLayout = []
            model.layoutPreviews = [:]
            openArrangementWhenReady = false
        }
        // Recovery metadata is cheap to read and must remain reachable even if
        // every feature was disabled before an unclean exit.
        model.pendingArrangement = UserDefaults.standard.data(forKey: "pendingArrangement") != nil
        if controller == nil, let data = UserDefaults.standard.data(forKey: "displayRecords"),
           let records = try? JSONDecoder().decode([DisplayRecord].self, from: data) {
            model.disabledMonitorCount = records.filter(\.disabledByApp).count
        }
        let recoveryNeeded = model.pendingArrangement || model.disabledMonitorCount > 0
        let observeScreens = modules.needsDisplays || spaces != nil || recoveryNeeded
        if observeScreens && screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.displayRefresh.requestRefresh()
                DispatchQueue.main.async { [weak self] in
                    self?.spaces?.suspend()
                    self?.refreshPreferences()
                }
            }
        } else if !observeScreens, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if modules.needsDisplays || recoveryNeeded { displayRefresh.requestRefresh() }
        else {
            controller = nil
            displayRefresh.cancel()
            model.displaySettling = false
            model.monitors = []
            model.activeMonitorCount = 0
            model.displaySupported = false
            item?.button?.toolTip = "Fix macOS"
        }
        refreshBluetooth()
        refreshPreferences()
    }

    private func refreshClipboard() {
        model.clipboardRecording = clipboard?.history.recording ?? false
        model.clipboardCount = clipboard?.history.entries.count ?? 0
        model.clipboardPersistence = clipboard?.persistence ?? false
        model.clipboardStoragePending = clipboard?.history.storagePending ?? false
        model.clipboardDays = clipboard?.days ?? 7
        model.clipboardExclusions = clipboard?.exclusions ?? ""
    }

    @objc private func toggleDashboard() {
        if popover.isShown { popover.performClose(nil) }
        else { model.launchWidget = nil; refreshPreferences(); showDashboard(); displayRefresh.requestRefresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshPreferences()
        showDashboard()
        displayRefresh.requestRefresh()
        return true
    }

    private func showDashboard() {
        if model.navigation.isSetup {
            let group = model.navigation.feature.map(SettingsGroup.forFeature)
            model.navigation = DashboardNavigation()
            showSettings(group); return
        }
        guard let button = item.button, !popover.isShown else { return }
        model.popupHeight = min(650, max(260, (button.window?.screen?.visibleFrame.height ?? 700) - 80))
        popover.contentSize = NSSize(width: 430, height: model.popupHeight)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showSettings(_ group: SettingsGroup? = nil) {
        guard transactions.acceptsActions else { return }
        if let group { model.settingsGroup = group }
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Fix macOS Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 680, height: 480)
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSetup() {
        guard transactions.acceptsActions else { return }
        popover.performClose(nil)
        if let setupWindow, setupWindow.isVisible { setupWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Set up Fix macOS"
        window.isReleasedWhenClosed = false
        let draft = SetupDraft(current: model, defaults: preferences)
        activeSetupDraft = draft; window.delegate = self
        configureSetup(draft)
        window.contentViewController = NSHostingController(rootView: SetupWizard(model: model, draft: draft, close: { [weak window] in window?.close() }))
        window.minSize = NSSize(width: 640, height: 480)
        window.center(); setupWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === setupWindow else { return true }
        guard activeSetupDraft?.applying != true else { return false }
        activeSetupDraft?.discardCheckpoint()
        return true
    }

    private func configureSetup(_ draft: SetupDraft) {
        draft.onRetryPermissions = { [weak self, weak draft] in
            guard self?.actionHost != nil, let draft else { return }
            draft.accessibilityGranted = AXIsProcessTrusted()
            draft.bluetoothGranted = CBManager.authorization == .allowedAlways
        }
        draft.onBluetoothPermission = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            if CBManager.authorization == .notDetermined {
                setupPermissionManager = CBCentralManager(delegate: nil, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") { NSWorkspace.shared.open(url) }
        }
        draft.controls.onKeepAwakeAddApp = { [weak self, weak draft] in
            guard self?.actionHost != nil else { return }
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
            panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
            guard panel.runModal() == .OK, self?.actionHost != nil else { return }
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier { draft?.controls.keepAwakeApps[id] = url.deletingPathExtension().lastPathComponent }
            }
        }
        draft.onDiscover = { [weak self] draft in
            guard let self, transactions.acceptsActions else { return }
            draft.discoveryStatus = "Reading available devices…"
            let readAudio = draft.selected.contains(.audio)
            let readBluetooth = draft.selected.contains(.bluetooth) && CBManager.authorization == .allowedAlways
            recoveryQueue.async { [weak self, weak draft] in
                guard let self else { return }
                var messages: [String] = []
                var audioDevices: [AudioDevice]?
                var devices: [BluetoothDevice]?
                if readAudio {
                    do { audioDevices = try CoreAudioBackend().devices() } catch { messages.append(error.localizedDescription) }
                }
                if readBluetooth, let path = CommandRunner.find("blueutil") {
                    do { devices = try BluetoothBackend(runner: commandRunner, blueutil: path, audioTool: nil).devices() }
                    catch { messages.append(error.localizedDescription) }
                } else if !readBluetooth { messages.append("Bluetooth discovery needs access; request it in the permissions step, then return here.") }
                DispatchQueue.main.async { [weak self, weak draft] in
                    guard self?.actionHost != nil, let draft else { return }
                    if let audioDevices { draft.controls.audioDevices = audioDevices }
                    if let devices { draft.controls.devices = devices }
                    draft.discoveryStatus = messages.isEmpty ? "Available devices refreshed; no routes or connections changed." : messages.joined(separator: "\n")
                }
            }
        }
        draft.onRetryPermissions()
    }

    /// Sequential, per-feature application keeps asynchronous recovery inside the
    /// existing host operations. Every continuation rechecks quit admission.
    private func applySetup(_ draft: SetupDraft, completion: @escaping ([String]) -> Void) {
        let configuration = draft.configuration
        let selected = draft.selected
        let requestedWidgets = draft.widgets
        var results: [String] = []
        func advance(_ index: Int) {
            guard transactions.acceptsActions else {
                completion(results + ["Remaining setup changes were not applied: shutdown is in progress. Successful changes above remain applied."]); return
            }
            guard index < AppModule.allCases.count else {
                model.onSaveWidgets(requestedWidgets)
                uiStore.complete(); draft.discardCheckpoint()
                completion(results + draft.unresolvedPermissions + ["Quick-action layout saved. No timed session, clipboard capture, window capture, or pointer Apply was started."])
                return
            }
            let module = AppModule.allCases[index]
            let enabled = selected.contains(module)
            func configure(_ success: Bool) {
                guard transactions.acceptsActions else { completion(results + ["Remaining setup changes were not applied during shutdown."]); return }
                guard success else {
                    results.append("\(module.title): not applied. \(model.errorMessage ?? "Busy or recovery is still pending; retry in Settings.")")
                    advance(index + 1); return
                }
                guard enabled else { results.append("\(module.title): disabled."); advance(index + 1); return }
                applySetupConfiguration(configuration, module: module) { success, detail in
                    results.append("\(module.title): \(success ? "applied" : "needs attention"). \(detail)")
                    advance(index + 1)
                }
            }
            if modules.enabled.contains(module) == enabled { configure(true) }
            else { setModule(module, enabled: enabled, completion: configure) }
        }
        advance(0)
    }

    private func applySetupConfiguration(_ value: SetupConfiguration, module: AppModule, completion: @escaping (Bool, String) -> Void) {
        guard transactions.acceptsActions else { completion(false, "Shutdown in progress."); return }
        let missing: Bool
        switch module {
        case .audio: missing = audio == nil
        case .bluetooth: missing = bluetooth == nil
        case .quitGuard: missing = quitGuard == nil
        case .keepAwake: missing = keepAwake == nil
        case .clipboard: missing = clipboard == nil
        case .windows: missing = windowPositions == nil
        default: missing = false
        }
        guard !missing else { completion(false, "Feature owner is unavailable. Retry from its Settings group."); return }
        let old = SetupConfiguration(model)
        let errorBefore = model.errorMessage
        var note = ""
        switch module {
        case .monitors:
            if value.confirmDisplays != old.confirmDisplays { model.onMonitorDisableModeChanged(value.confirmDisplays) }
        case .arrangement:
            if value.matchEdges != old.matchEdges { model.onMatchScreenEdgesChanged(value.matchEdges) }
            if value.matchEdges && !AXIsProcessTrusted() { note = "Screen edges await Accessibility access and stable displays." }
        case .audio:
            if value.outputPreferences != old.outputPreferences { model.onAudioPreferences(value.outputPreferences, .output) }
            if value.inputPreferences != old.inputPreferences { model.onAudioPreferences(value.inputPreferences, .input) }
            if value.outputFallback != old.outputFallback { model.onAudioFallback(value.outputFallback, .output) }
            if value.inputFallback != old.inputFallback { model.onAudioFallback(value.inputFallback, .input) }
            if value.audioAutomatic != old.audioAutomatic { model.onAudioAutomatic(value.audioAutomatic) }
            note = model.audioStatus
        case .bluetooth:
            // Pause automatic reconciliation while replacing its inputs.
            let changed = value.bluetoothTargets != old.bluetoothTargets || value.protectedTargets != old.protectedTargets || value.protectAudio != old.protectAudio || value.switchAudio != old.switchAudio
            if changed && old.bluetoothAutomatic { model.onAutomaticReconnectChanged(false) }
            for address in old.bluetoothTargets.union(value.bluetoothTargets) where old.bluetoothTargets.contains(address) != value.bluetoothTargets.contains(address) {
                model.onAutoDeviceChanged(address, value.bluetoothTargets.contains(address))
            }
            for address in old.protectedTargets.union(value.protectedTargets) where old.protectedTargets.contains(address) != value.protectedTargets.contains(address) {
                model.onProtectedDeviceChanged(address, value.protectedTargets.contains(address))
            }
            if value.protectAudio != old.protectAudio { model.onProtectAudioChanged(value.protectAudio) }
            if value.switchAudio != old.switchAudio { model.onSwitchAudioChanged(value.switchAudio) }
            if changed || value.bluetoothAutomatic != old.bluetoothAutomatic { model.onAutomaticReconnectChanged(value.bluetoothAutomatic) }
            if CBManager.authorization != .allowedAlways { note = "Bluetooth access unresolved. Open Sound & connections to grant access and retry." }
        case .quitGuard:
            if value.quitDuration != old.quitDuration { model.onQuitGuardDurationChanged(value.quitDuration) }
            if value.quitGuard != old.quitGuard { model.onQuitGuardChanged(value.quitGuard) }
            if value.quitGuard && !model.quitGuardActive { note = "Hold to quit is inactive; check Accessibility and Retry in Input settings." }
        case .keepAwake:
            if value.awakeMinutes != old.awakeMinutes { model.onKeepAwakeMinutesChanged(value.awakeMinutes) }
            if value.displayAwake != old.displayAwake { model.onKeepDisplayAwakeChanged(value.displayAwake) }
            if let keepAwake {
                for id in Set(old.awakeApps.keys).union(value.awakeApps.keys) where old.awakeApps[id] != value.awakeApps[id] {
                    do { try keepAwake.setApp(id, name: value.awakeApps[id] ?? id, selected: value.awakeApps[id] != nil) }
                    catch { showError(error) }
                }
                refreshKeepAwake()
            }
            note = "Saved app rules may be active. No timed session started."
        case .clipboard:
            if value.clipboardDays != old.clipboardDays { model.onClipboardDays(value.clipboardDays) }
            if value.clipboardExclusions != old.clipboardExclusions { model.onClipboardExclusions(value.clipboardExclusions) }
            if value.clipboardPersistence != old.clipboardPersistence { model.onClipboardPersistence(value.clipboardPersistence) }
            if model.clipboardStoragePending { completion(false, "Disk cleanup/save is pending; keep Clipboard enabled and retry in Settings."); return }
            note = "Recording was not started or changed by setup."
        case .mouse:
            model.mouseAcceleration = value.mouseAcceleration; model.mouseTracking = value.mouseTracking
            note = "No pointer settings applied. Use explicit Apply in Input settings."
        case .windows:
            if let windowPositions {
                if value.windowsPaused != old.windowsPaused { windowPositions.paused = value.windowsPaused }
                if value.windowsSelected != old.windowsSelected { windowPositions.selected = value.windowsSelected }
                if value.windowsExclusions != old.windowsExclusions { windowPositions.exclusions = value.windowsExclusions }
                if value.windowsAutomatic != old.windowsAutomatic { windowPositions.automatic = value.windowsAutomatic }
                note = windowPositions.permitted ? "No windows captured or moved." : "Accessibility is required before saving or restoring windows."
            }
        case .menuBar:
            if value.compactMenu != old.compactMenu { model.onCompactMenuBarChanged(value.compactMenu) }
            if value.hideMenu != old.hideMenu { model.onMenuBarHidingChanged(value.hideMenu) }
        case .spaces:
            func finishAnimation(_ success: Bool) {
                guard success, transactions.acceptsActions else { completion(false, model.errorMessage ?? "Animation change interrupted or unavailable."); return }
                if value.speed != old.speed { model.onSpeedChanged(TransitionSpeed.from(rawValue: value.speed)) }
                if value.spaces != model.spacesEnabled { model.onSpacesChanged(value.spaces) }
                completion(model.animationsEnabled == value.animations && (!value.spaces || model.spacesEnabled), model.errorMessage ?? "Desktop switching may await Accessibility or stable displays.")
            }
            if value.animations != old.animations { setAnimations(value.animations, resultCompletion: finishAnimation) }
            else { finishAnimation(true) }
            return
        }
        let newError = model.errorMessage != errorBefore ? model.errorMessage : nil
        let permissionPending = (module == .bluetooth && CBManager.authorization != .allowedAlways) ||
            (module == .quitGuard && value.quitGuard && !model.quitGuardActive) ||
            (module == .arrangement && value.matchEdges && !AXIsProcessTrusted()) ||
            (module == .windows && windowPositions?.permitted != true)
        completion(newError == nil && !permissionPending, newError ?? note)
    }

    private func refreshDisplaySnapshot() {
        guard !recovering, modules.needsDisplays || model.pendingArrangement || model.disabledMonitorCount > 0 else { return }
        if controller == nil { controller = DisplayController() }
        guard let controller else { return }
        controller.refreshDisplays()
        item.button?.toolTip = "Fix macOS\n" + controller.status()
        model.monitors = controller.monitors
        model.activeMonitorCount = (try? controller.activeIDs().count) ?? 0
        model.displaySupported = controller.supported && safety.isReady
        model.disabledMonitorCount = controller.disabledUUIDs.count
        model.pendingArrangement = controller.hasPendingArrangement
        model.currentLayout = modules.enabled.contains(.arrangement) ? (try? controller.currentLayout()) ?? [] : []
        layoutFresh = true
        reconcileWindows()
        model.layoutPreviews = modules.enabled.contains(.arrangement) && modules.enabled.contains(.monitors) ? (try? controller.layoutPreviews()) ?? [:] : [:]
        updateScreenEdges()
        if openArrangementWhenReady, safety.isReady, !model.pendingArrangement, model.disabledMonitorCount == 0,
           model.currentLayout.count > 1 {
            openArrangementWhenReady = false
            showArrangementEditor()
        }
        if !modules.needsDisplays && !model.pendingArrangement && model.disabledMonitorCount == 0 { updateModules() }
        publishModuleStatus()
    }

    private func refreshBluetooth() {
        guard modules.enabled.contains(.bluetooth), let bluetooth else {
            model.devices = []
            model.selectedAddresses = []
            model.bluetoothDeviceStates = [:]
            model.protectedAudioAddresses = []
            model.bluetoothAvailable = false
            model.bluetoothBusy = false
            model.bluetoothManualBusy = false
            model.bluetoothPermissionRequired = false
            model.bluetoothRadioOn = nil
            model.bluetoothSummary = "Bluetooth module is off"
            return
        }
        // Bluetooth's five-second poll must never enter graphics queries.
        model.devices = bluetooth.devices
        model.selectedAddresses = bluetooth.autoAddresses
        model.automaticReconnectEnabled = bluetooth.autoEnabled
        model.bluetoothAvailable = bluetooth.available
        model.bluetoothBusy = bluetooth.isBusy
        model.bluetoothManualBusy = bluetooth.isManualBusy
        model.bluetoothRadioOn = bluetooth.radioPoweredOn
        model.bluetoothPermissionRequired = bluetooth.permissionRequired
        model.bluetoothDeviceStates = bluetooth.deviceStates
        model.bluetoothSummary = bluetooth.reconnectSummary
        model.protectOtherAudio = bluetooth.protectOtherAudio
        model.switchAudioOutput = bluetooth.switchAudioOutput
        model.protectedAudioAddresses = bluetooth.protectedAudioAddresses
        model.legacyServicePresent = bluetooth.legacyServicePresent
        if let data = bluetooth.diagnostics() { UserDefaults.standard.set(data, forKey: "bluetooth.lastSnapshot") }
        checkGUIBluetoothTest()
    }

    private func refreshAudio() {
        model.audioDevices = audio?.devices ?? []
        model.audioRoutes = audio?.routes ?? [:]
        model.audioAutomatic = audio?.automatic ?? false
        model.audioStatus = audio?.status ?? "Audio module is off"
        for direction in AudioDirection.allCases {
            model.audioPreferences[direction] = audio?.preferences(direction) ?? []
            model.audioFallbacks[direction] = audio?.fallback(direction) ?? ""
            model.audioOverrides[direction] = audio?.isOverridden(direction) ?? false
        }
    }

    private func checkGUIBluetoothTest() {
        guard let bluetooth, modules.enabled.contains(.bluetooth), let name = guiTestTarget, !guiTestFinished, !bluetooth.permissionRequired,
              bluetooth.radioPoweredOn == true, let device = bluetooth.devices.first(where: { $0.name == name }) else { return }
        if !guiTestStarted {
            guiTestStarted = true
            // Runs under the GUI's actual TCC identity, not Terminal's access.
            bluetooth.requestConnection(true, address: device.address)
            return
        }
        guard !bluetooth.isBusy, !bluetooth.isManualBusy else { return }
        guiTestFinished = true
        let result: [String: Any] = ["device": name, "connected": device.connected,
                                   "error": bluetooth.lastError ?? "", "context": "running-gui",
                                   "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            UserDefaults.standard.set(data, forKey: "bluetooth.guiTestResult")
        }
        if let originalOutput = guiTestOriginalOutput, let audio = CommandRunner.find("SwitchAudioSource") {
            recoveryQueue.async {
                let runner = CommandRunner()
                if (try? runner.run(audio, ["-c", "-t", "output"]).trimmingCharacters(in: .whitespacesAndNewlines)) != originalOutput {
                    _ = try? runner.run(audio, ["-t", "output", "-s", originalOutput])
                }
            }
        }
    }

    private func refreshPreferences() {
        reconcileWindows()
        model.matchScreenEdges = UserDefaults.standard.bool(forKey: "arrangement.matchEdges")
        updateScreenEdges()
        model.displaySupported = controller?.supported == true && safety.isReady
        model.confirmMonitorDisable = UserDefaults.standard.bool(forKey: "monitors.confirmDisable")
        model.animationsEnabled = animations.enabled
        model.animationRecoveryRequired = animations.recoveryRequired
        if transactions.acceptsActions && animations.enabled && !model.animationsBusy && controlState.inputReady && spaces?.isAvailable == true {
            do { try spaces?.restoreSavedState() } catch { showError(error) }
        }
        model.spacesEnabled = spaces?.isEnabled ?? false
        model.spacesPermission = spaces?.hasPermission ?? false
        model.spacesAvailable = spaces?.isAvailable == true && spaces?.isDraining != true && controlState.inputReady
        model.spacesSpeed = spaces?.speed ?? .instant
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        publishModuleStatus()
    }

    private var controlState: SystemControlLifecycle.State {
        SystemControlLifecycle.State(watchdogReady: safety.isReady && transactions.acceptsActions, displaySettling: displayRefresh.isSettling,
            displayOperation: recovering, pendingConfirmation: model.pendingArrangement || rollbackUUID != nil,
            layoutFresh: layoutFresh, cursorRequested: UserDefaults.standard.bool(forKey: "arrangement.matchEdges"),
            arrangementEnabled: modules.enabled.contains(.arrangement), layout: model.currentLayout)
    }

    private func updateScreenEdges() {
        do { try controlLifecycle.reconcile(controlState) }
        catch { showError(error) }
        model.screenEdgesActive = screenEdges?.isRunning == true
    }

    private func reconcileWindows() {
        reconcileWindows(state: controlState)
    }

    func reconcileWindows(state: SystemControlLifecycle.State) {
        windowPositions?.reconcile(ready: state.inputReady && state.layoutFresh,
                                   settled: !state.displaySettling && state.layoutFresh && !state.displayOperation)
    }

    private func setAnimations(_ enabled: Bool, preserveChoice: Bool = false, recoverOnly: Bool = false, completion: (() -> Void)? = nil, resultCompletion: ((Bool) -> Void)? = nil) {
        guard transactions.acceptsActions, !model.animationsBusy else { resultCompletion?(false); return }
        model.animationsBusy = true
        afterGestureDrain { [weak self] in
            guard let self else { return }
            animationQueue.async { [weak self] in
                guard let self else { return }
                do {
                    if recoverOnly { try animations.recoverPendingRestore() }
                    else { try animations.setEnabled(enabled, preserveChoice: preserveChoice) }
                    // Restart only after the complete preference transaction succeeds.
                    _ = try? CommandRunner().run("/usr/bin/killall", ["Dock", "Finder"])
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        model.animationsBusy = false
                        completion?()
                        if enabled && !preserveChoice && spaces?.hasPermission == true {
                            // Starting waits for display/watchdog readiness via refreshPreferences.
                            spaces?.requestRestore(enabled: UserDefaults.standard.object(forKey: "spaces.enabled") == nil || spaces?.savedEnabled == true)
                        }
                        refreshPreferences()
                        resultCompletion?(true)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.model.animationsBusy = false
                        self?.showError(error)
                        self?.refreshPreferences()
                        resultCompletion?(false)
                    }
                }
            }
        }
    }

    private func afterGestureDrain(_ operation: @escaping () -> Void) {
        if let spaces { spaces.suspend(completion: operation) }
        else { operation() }
    }

    /// The single entry point for display helpers, also exercised with a fake
    /// runner in host-level tests. No helper starts before a gesture's terminal phase.
    func runDisplayCommand(executable: String, arguments: [String], completion: @escaping (Result<String, Error>) -> Void) {
        afterGestureDrain { [self] in
            recoveryQueue.async { [self] in
                let result = Result { try commandRunner.run(executable, arguments) }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func publishModuleStatus() {
        let status: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "enabled": modules.enabled.map(\.rawValue).sorted(),
            "stopping": model.stoppingModules.map(\.rawValue).sorted(),
            "bluetoothLoaded": bluetooth != nil, "spacesLoaded": spaces != nil,
            "menuBarLoaded": menuBar != nil, "menuBarHidden": menuBar?.hidden == true,
            "compactMenuBar": menuBarSpacing.enabled,
            "quitGuardLoaded": quitGuard != nil, "quitGuardActive": quitGuard?.isRunning == true,
            "keepAwakeLoaded": keepAwake != nil, "keepAwakeActive": keepAwake?.active == true,
            "mouseLoaded": mouseLifecycle.module != nil, "mouseActive": mouseLifecycle.module?.active == true,
            "mouseRecoveryRequired": model.mouseRecoveryRequired,
            "animationsEnabled": animations.enabled, "animationsBusy": model.animationsBusy,
            "screenEdgesActive": screenEdges?.isRunning == true,
            "displayDiscoveryLoaded": controller != nil, "screenObserverInstalled": screenObserver != nil,
            "arrangementEditorLoaded": arrangementWindow?.contentView != nil
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            UserDefaults.standard.set(data, forKey: "modules.runtimeStatus")
        }
    }

    private func showError(_ error: Error) { model.errorMessage = error.localizedDescription }

    private func refreshMouseCapability(forceDraft: Bool = false) {
        do {
            let snapshot = try mouseLifecycle.snapshot()
            model.mouseCapabilityError = nil
            model.initializeMouseDraft(snapshot, force: forceDraft)
        } catch { model.mouseCapabilityError = error.localizedDescription }
    }

    private func clearRollback() {
        rollbackTimer?.invalidate()
        rollbackTimer = nil
        rollbackDeadline = nil
        rollbackUUID = nil
        model.countdowns = [:]
        refreshPreferences()
    }

    private func setMonitor(_ uuid: String, enabled: Bool) {
        guard modules.enabled.contains(.monitors), safety.isReady, !recovering, !displayRefresh.isSettling, !model.pendingArrangement,
              rollbackUUID == nil || (enabled && rollbackUUID == uuid),
              let executable = Bundle.main.executableURL?.path else {
            showError(ToggleError(message: "Wait for the watchdog, display changes, and current confirmation to finish."))
            return
        }
        // Do not synthesize Space gestures while display topology is changing.
        recovering = true
        model.monitorBusy = true
        screenEdges?.stop()
        refreshPreferences()
        let arguments = ["--set-display", uuid, enabled ? "on" : "off"] + (modules.enabled.contains(.arrangement) ? [] : ["--basic-layout"])
        let confirmDisable = !enabled && model.confirmMonitorDisable
        runDisplayCommand(executable: executable, arguments: arguments) { [weak self] result in
                guard let self else { return }
                recovering = false
                model.monitorBusy = false
                displayRefresh.requestRefresh()
                switch result {
                case .success:
                    // The helper rejects disabling the last usable display.
                    clearRollback()
                    if confirmDisable {
                        rollbackUUID = uuid
                        rollbackDeadline = Date().addingTimeInterval(20)
                        model.countdowns[uuid] = 20
                        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                            guard let self, let deadline = rollbackDeadline else { return }
                            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                            model.countdowns[uuid] = remaining
                            if remaining == 0, !recovering {
                                restoreAll { restored in if restored { self.clearRollback() } }
                            }
                        }
                        rollbackTimer = timer
                        RunLoop.main.add(timer, forMode: .common)
                        refreshPreferences()
                    }
                case .failure(let error):
                    showError(error)
                    // A timed-out helper may have committed before reporting failure.
                    rollbackUUID = uuid
                    rollbackDeadline = Date()
                    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                        self?.restoreAll { restored in if restored { self?.clearRollback() } }
                    }
                    rollbackTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
        }
    }

    private func showArrangementEditor() {
        guard modules.enabled.contains(.arrangement), controlState.inputReady,
              model.disabledMonitorCount == 0, model.currentLayout.count > 1,
              let main = model.monitors.first(where: \.isMain)?.uuid else { return }
        arrangementWindow?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Fix macOS — Arrange displays"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DisplayArrangementEditor(
            original: model.currentLayout, monitors: model.monitors, mainUUID: main,
            onApply: { [weak self] request in self?.applyArrangement(request) },
            onCancel: { [weak self] in self?.arrangementWindow?.close() }))
        arrangementWindow = window
        popover.performClose(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func applyArrangement(_ request: DisplayArrangementRequest) {
        guard transactions.acceptsActions else { return }
        guard modules.enabled.contains(.arrangement), controlState.inputReady,
              model.disabledMonitorCount == 0,
              let executable = Bundle.main.executableURL?.path else {
            showError(ToggleError(message: "Wait for display changes or restore the pending layout first."))
            showDashboard()
            return
        }
        guard let data = try? JSONEncoder().encode(request) else { return }
        arrangementWindow?.close()
        screenEdges?.stop()
        recovering = true
        model.monitorBusy = true
        refreshPreferences()
        showDashboard()
        runDisplayCommand(executable: executable, arguments: ["--arrange-displays", data.base64EncodedString()]) { [weak self] result in
                guard let self else { return }
                recovering = false
                model.monitorBusy = false
                model.pendingArrangement = true
                rollbackUUID = "layout"
                let duration: TimeInterval
                switch result {
                case .success: duration = 20
                case .failure(let error): duration = 0; showError(error)
                }
                rollbackDeadline = Date().addingTimeInterval(duration)
                model.countdowns["layout"] = Int(duration)
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, let deadline = rollbackDeadline else { return }
                    let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                    model.countdowns["layout"] = remaining
                    if remaining == 0, !recovering { restoreAll() }
                }
                rollbackTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                displayRefresh.requestRefresh()
                showDashboard()
        }
    }

    private func restoreAll(completion: ((Bool) -> Void)? = nil) {
        guard controlState.recoveryReady else {
            showError(ToggleError(message: "Wait for display connections to settle before recovery."))
            completion?(false)
            return
        }
        guard let executable = Bundle.main.executableURL?.path else { completion?(false); return }
        screenEdges?.stop()
        recovering = true
        model.monitorBusy = true
        refreshPreferences()
        // Even explicit recovery is outside the UI process and time-limited.
        runDisplayCommand(executable: executable, arguments: ["--restore"]) { [weak self] result in
                guard let self else { return }
                self.recovering = false
                self.model.monitorBusy = false
                self.displayRefresh.requestRefresh()
                switch result {
                case .success: self.model.pendingArrangement = false; self.clearRollback(); completion?(true)
                case .failure(let error): self.showError(error); completion?(false)
                }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let actions = HostTransactions.QuitActions(
            isBusy: { self.model.animationsBusy || !self.model.stoppingModules.isEmpty || self.recovering },
            prepareMouse: { self.mouseLifecycle.prepareToQuit() },
            quiesce: { self.windowPositions?.invalidate(); self.screenEdges?.stop() },
            prepareClipboard: { self.clipboard?.prepareTermination() != false },
            needsDisplayRecovery: { self.model.disabledMonitorCount > 0 || self.rollbackUUID != nil || self.model.pendingArrangement },
            restoreDisplays: { self.restoreAll(completion: $0) },
            suspendSpaces: spaces.map { module in { module.suspend(completion: $0) } },
            resumeClipboard: { self.clipboard?.resumeMonitoring() },
            restoreSpacesChoice: { if let spaces = self.spaces { spaces.requestRestore(enabled: spaces.savedEnabled) } },
            didReopen: { self.refreshPreferences() },
            didVeto: { veto in
                switch veto {
                case .busy: self.model.errorMessage = "Wait for current settings and module operations before quitting."
                case .clipboard: self.model.errorMessage = "Clipboard disk cleanup is pending. Retry quitting after storage becomes available."
                case .mouse: self.model.errorMessage = self.mouseLifecycle.errorMessage
                case .recovery: break // Display restoration already presented its error.
                }
            })
        switch transactions.requestQuit(actions, reply: { self.terminationReply(sender, $0) }) {
        case .cancel: return .terminateCancel
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowPositions?.stop()
        try? keepAwake?.deactivate()
        audio?.stop()
        clipboard?.stop()
        quitGuard?.stop()
        menuBar?.stop()
        sourceUpdater.stop()
        spaces?.onChange = nil
        screenEdges?.stop()
        bluetooth?.stop()
        spaces?.stop()
        safety.stop()
        rollbackTimer?.invalidate()
        displayRefresh.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
