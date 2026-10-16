import AppKit
import SwiftUI
import CoreBluetooth
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: DisplayController?
    private var bluetooth: BluetoothModule?
    private var bluetoothActionError: (operation: BluetoothModule.ManualOperation, generation: UUID)?
    private var audio: AudioModule?
    private var spaces: SpacesModule?
    private var screenEdges: ScreenEdgeController?
    private var layoutFresh = false
    private lazy var controlLifecycle = SystemControlLifecycle(startCursor: { [weak self] layout in
        guard let self else { return }
        if screenEdges == nil { screenEdges = ScreenEdgeController() }
        try screenEdges?.start(layout: layout)
    }, stopCursor: { [weak self] in self?.screenEdges?.stop() })
    private let animations: AnimationPreferences
    private let menuBarSpacing: MenuBarSpacing
    private let makeAudio: () -> AudioModule
    private let awakeFeature: KeepAwakeFeature
    private let awakePresentation: KeepAwakePresentation
    private let makeBluetooth: () -> BluetoothModule
    private let makeMenuBar: () -> MenuBarModule
    private var menuBar: MenuBarModule?
    private var quitGuard: QuitGuard?
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
    private var activityWindow: NSWindow?
    private let activity: ActivityJournal
    private let activityPresentation: ActivityPresentation
    private var activityRecoveryFailures: [ActivityRecoveryReason: ActivityOperationID] = [:]
    private var setupWindow: NSWindow?
    private var activeSetupDraft: SetupDraft?
    private let uiStore: UISettingsStore
    private var setupPermissionManager: CBCentralManager?
    private let safety = SafetySupervisor()
    private let logger = Logger(subsystem: "io.github.jakub-tucek.mac-utils", category: "Safety")
    private var loggedLoginStatus: String?
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
    private var displayWakeObserver: NSObjectProtocol?
    private var guiTestTarget: String?
    private var guiTestStarted = false
    private var guiTestFinished = false
    private var guiTestOriginalOutput: String?
    private let commandRunner: CommandRunning
    private let transactions: HostTransactions
    private let loginService: LoginServicing
    private let diagnostics: Diagnostics
    private var moduleFailures: [AppModule: String] = [:]
    private lazy var choicePreparations = BuiltinChoicePreparations(
        keepAwake: awakeFeature,
        clipboard: ClipboardChoicePreparation(owner: { [weak self] in self?.clipboard }),
        displays: DisplayChoicePreparation(
            isRecovering: { [weak self] in self?.recovering == true },
            needsRecovery: { [weak self] in self?.needsDisplayRecovery == true },
            setStopping: { [weak self] module, stopping in
                if stopping { self?.model.stoppingModules.insert(module) }
                else { self?.model.stoppingModules.remove(module) }
            },
            restore: { [weak self] completion in
                guard let self else { completion(false); return }
                restoreAll(reason: .featureDisable, completion: completion)
            }))
    private var setupDesktopReconciliationPending = false
    private let presentWindow: (NSWindow) -> Void
    private let restartAnimationClients: () -> Void
    private let controlStateSnapshot: (() -> SystemControlLifecycle.State)?
    private let displayRecoveryPending: () -> Bool
    private let displaySnapshotRefresh: (() throws -> Void)?
    // UI counts and controller snapshots can lag a committed helper journal by
    // the gate's quiet period. They must never decide recovery ownership.
    private var needsDisplayRecovery: Bool { displayRecoveryPending() || rollbackUUID != nil }
    var setupSession: SetupDraft? { activeSetupDraft }
    private let terminationReply: (NSApplication, Bool) -> Void

     init(commandRunner: CommandRunning = CommandRunner(), spaces: SpacesModule? = nil, windowPositions: WindowPositions? = nil, clipboard: ClipboardModule? = nil, mouseLifecycle: MouseLifecycle? = nil, model: DashboardModel = DashboardModel(), preferences: UserDefaults = .standard,
          makeAudio: (() -> AudioModule)? = nil, makeKeepAwake: (() -> KeepAwakeModule)? = nil, makeBluetooth: (() -> BluetoothModule)? = nil,
          makeMenuBar: (() -> MenuBarModule)? = nil, menuBarSpacing: MenuBarSpacing? = nil, animations: AnimationPreferences? = nil,
          chooseKeepAwakeApps: @escaping KeepAwakePresentation.ChooseApps = KeepAwakePresentation.chooseApplications,
          presentWindow: @escaping (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) },
          restartAnimationClients: @escaping () -> Void = { _ = try? CommandRunner().run("/usr/bin/killall", ["Dock", "Finder"]) },
          controlStateSnapshot: (() -> SystemControlLifecycle.State)? = nil,
          displayRecoveryPending: (() -> Bool)? = nil,
          displaySnapshotRefresh: (() throws -> Void)? = nil,
          transactions: HostTransactions = HostTransactions(),
          loginService: LoginServicing = SystemLoginService(),
          diagnostics: Diagnostics = .shared,
          activity: ActivityJournal = ActivityJournal(),
          terminationReply: @escaping (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }) {
         self.transactions = transactions
         self.loginService = loginService
          self.diagnostics = diagnostics
          self.activity = activity
          self.activityPresentation = ActivityPresentation(journal: activity)
         self.commandRunner = commandRunner
         self.preferences = preferences
         self.modules = ModuleSettings(defaults: preferences)
         self.uiStore = UISettingsStore(defaults: preferences)
         self.makeAudio = makeAudio ?? { AudioModule(defaults: preferences) }
         let awakePresentation = KeepAwakePresentation(model: model, acceptsActions: { transactions.acceptsActions }, chooseApps: chooseKeepAwakeApps)
         self.awakePresentation = awakePresentation
         self.awakeFeature = KeepAwakeFeature(
             makeOwner: makeKeepAwake ?? { KeepAwakeModule(defaults: preferences) },
             acceptsActions: { transactions.acceptsActions },
             publish: { [weak awakePresentation] in awakePresentation?.publish($0) },
             reportError: { [weak model] in model?.errorMessage = $0.localizedDescription })
         self.makeBluetooth = makeBluetooth ?? { BluetoothModule(defaults: preferences) }
         self.makeMenuBar = makeMenuBar ?? { MenuBarModule(defaults: preferences) }
         self.menuBarSpacing = menuBarSpacing ?? MenuBarSpacing(defaults: preferences)
         self.animations = animations ?? AnimationPreferences(defaults: preferences)
         self.presentWindow = presentWindow
         self.restartAnimationClients = restartAnimationClients
          self.controlStateSnapshot = controlStateSnapshot
          self.displayRecoveryPending = displayRecoveryPending ?? { DisplayController.hasPendingRecovery(defaults: preferences) }
          self.displaySnapshotRefresh = displaySnapshotRefresh
        self.model = model
        self.spaces = spaces
        self.windowPositions = windowPositions
        self.clipboard = clipboard
        self.injectedMouseLifecycle = mouseLifecycle
        self.terminationReply = terminationReply
        super.init()
          awakeFeature.activity = activity
         awakePresentation.didPublish = { [weak self] in self?.refreshKeepAwakeStatus($0) }
         configureActions()
          windowPositions?.acceptsActions = { [weak self] in self?.transactions.acceptsActions == true }
          windowPositions?.activity = activity
         clipboard?.acceptsActions = { [weak self] in self?.transactions.acceptsActions == true }
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
        configureDisplayRefresh()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Fix macOS")
        item.button?.target = self
        item.button?.action = #selector(toggleDashboard)
        configurePopover()
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

    private func configureDisplayRefresh() {
        guard displayRefresh.onSettlingChanged == nil else { return }
        displayRefresh.onSettlingChanged = { [weak self] settling in
            guard let self else { return }
            logger.notice("Display refresh settling: \(settling, privacy: .public)")
            model.displaySettling = settling
            if settling { layoutFresh = false }
            refreshPreferences()
        }
    }

    private func configurePopover() {
        configureDisplayRefresh()
        guard popover.contentViewController == nil else { return }
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: PopupSizing.width, height: 160)
        popover.contentViewController = NSHostingController(rootView: QuickActionsView(model: model, onResize: { [weak self] size in
            // Defer native resizing out of the SwiftUI geometry update. The
            // document measurement is independent of this viewport's height.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let bounded = NSSize(width: PopupSizing.width, height: min(size.height, model.popupHeight, 650))
                guard popover.contentSize != bounded else { return }
                popover.contentSize = bounded
            }
        }))
    }

    // Host-side barrier, not a UI-only disable: callbacks retained by views also
    // consult it at invocation time. Cleanup paths deliberately bypass this gate.
    private var actionHost: AppDelegate? { transactions.acceptsActions ? self : nil }

    private func configureActions() {
        model.onOpenSettings = { [weak self] group in self?.actionHost?.showSettings(group) }
        model.onOpenActivity = { [weak self] in self?.actionHost?.showActivity() }
        model.onRunSetup = { [weak self] in self?.actionHost?.showSetup() }
        model.onSaveWidgets = { [weak self] layout in
            guard let self, transactions.acceptsActions else { return false }
            var value = layout; value.normalize(); uiStore.save(value); model.widgetLayout = value
            return true
        }
        model.onSkipSetup = { [weak self] in
            guard let self, transactions.acceptsActions, activeSetupDraft?.applying != true else { return }
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
        awakePresentation.bind(awakeFeature)
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
            preferences.set(confirm, forKey: "monitors.confirmDisable")
            refreshPreferences()
        }
        model.onMatchScreenEdgesChanged = { [weak self] enabled in
            guard let self, transactions.acceptsActions else { return }
            preferences.set(enabled, forKey: "arrangement.matchEdges")
            refreshPreferences()
            updateScreenEdges()
        }
        model.onKeepDisabled = { [weak self] uuid in
            guard let self, transactions.acceptsActions, rollbackUUID == uuid else { return }
            activity.record(.displayKept, trigger: .user, result: .completed)
            clearRollback()
        }
        model.onRestoreAll = { [weak self] in self?.actionHost?.restoreAll() }
        model.onArrangeDisplays = { [weak self] in self?.actionHost?.showArrangementEditor() }
        model.onKeepArrangement = { [weak self] in
            guard let self, transactions.acceptsActions, !recovering, rollbackUUID == "layout" else { return }
            preferences.removeObject(forKey: "pendingArrangement")
            activity.record(.arrangementKept, trigger: .user, result: .completed)
            preferences.synchronize()
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
            model.loginError = nil
            do {
                try LoginDiagnostics.change(enabled, service: loginService, diagnostics: diagnostics)
            } catch {
                model.loginError = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            }
            refreshLoginStatus()
        }
        model.onOpenLoginSettings = { [weak self] in
            guard let self, transactions.acceptsActions else { return }
            loginService.openSettings()
        }
        model.onClose = { [weak self] in self?.popover.performClose(nil) }
        model.onQuit = { NSApp.terminate(nil) }
    }

    private func setModule(_ module: AppModule, enabled: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        moduleFailures[module] = nil
        guard transactions.acceptsActions, !model.stoppingModules.contains(module) else {
            moduleFailures[module] = "Shutdown or feature recovery is in progress."; completion(false); return
        }
        if module == .mouse {
            guard mouseLifecycle.setEnabled(enabled) else { moduleFailures[module] = mouseLifecycle.errorMessage ?? "Mouse restoration failed."; completion(false); return }
            updateModules()
            completion(true)
            return
        }
        if module == .menuBar && !enabled {
            do { try menuBarSpacing.restore(preserveChoice: true) }
            catch { moduleFailures[module] = error.localizedDescription; refreshMenuBar(); showError(error); completion(false); return }
        }
        if module == .spaces {
            guard !model.animationsBusy else { moduleFailures[module] = "Animation operation is busy."; completion(false); return }
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
        choicePreparations.prepare(module, enabled: enabled) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Accepted asynchronous cleanup may finish with admission closed.
                // Do not re-enter the public guard and lose its pending commit.
                modules.set(module, enabled: enabled)
                updateModules()
                completion(true)
            case .failure(let failure):
                moduleFailures[module] = failure.detail
                if let message = failure.message { model.errorMessage = message }
                completion(false)
            }
        }
    }

    private func refreshKeepAwakeStatus(_ state: KeepAwakeFeature.State) {
        item?.button?.image = NSImage(systemSymbolName: state.active ? DashboardTab.keepAwake.symbol : "slider.horizontal.3", accessibilityDescription: state.active ? "Fix macOS — Keep awake active" : "Fix macOS")
        item?.button?.toolTip = state.protectionFailed ? "Fix macOS — keep awake needs retry" : (state.active ? "Fix macOS — keeping awake" : "Fix macOS")
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
                let module = WindowPositions(defaults: preferences)
                module.activity = activity
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
                let module = makeAudio()
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
                let module = ClipboardModule(defaults: preferences)
                clipboard = module
                module.acceptsActions = { [weak self] in self?.transactions.acceptsActions == true }
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
        awakeFeature.reconcile(enabled: modules.enabled.contains(.keepAwake))
        if modules.enabled.contains(.quitGuard) {
            if quitGuard == nil {
                let module = QuitGuard(defaults: preferences)
                quitGuard = module
                module.onChange = { [weak self] in self?.refreshQuitGuard() }
                module.onError = { [weak self] error in
                    self?.showError(error)
                    self?.model.tab = .keyboard
                    self?.showDashboard()
                }
                do { try module.startIfEnabled() } catch { moduleFailures[.quitGuard] = error.localizedDescription; showError(error) }
            }
        } else {
            quitGuard?.onChange = nil
            quitGuard?.stop()
            quitGuard = nil
        }
        refreshQuitGuard()
        if modules.enabled.contains(.menuBar) {
            if menuBar == nil {
                let module = makeMenuBar()
                module.onChange = { [weak self] in self?.refreshMenuBar() }
                module.onError = { [weak self] error in
                    self?.showError(error)
                    self?.model.tab = .menuBar
                    self?.showDashboard()
                }
                menuBar = module
                module.start()
                if menuBarSpacing.needsApply && !menuBarSpacing.recoveryRequired {
                    do { try menuBarSpacing.setEnabled(true) } catch { moduleFailures[.menuBar] = error.localizedDescription; showError(error) }
                }
            }
        } else {
            menuBar?.stop()
            menuBar = nil
        }
        refreshMenuBar()
        if modules.enabled.contains(.bluetooth) {
            if bluetooth == nil {
                let module = makeBluetooth()
                module.activityJournal = activity
                bluetooth = module
                module.onAudioOutputRequested = { [weak self] name in self?.audio?.bluetoothConnected(name: name) }
                module.suspendAutomaticReconnection = guiTestTarget != nil
                module.onChange = { [weak self] in self?.refreshBluetooth() }
                module.onError = { [weak self] in self?.showError($0) }
                module.onManualOperationCompleted = { [weak self] operation, result in
                    guard let self else { return }
                    let action: String
                    switch operation {
                    case .powerOn: action = "power_on"
                    case .connection(_, let connected): action = connected ? "connect" : "disconnect"
                    }
                    var token = UUID().uuidString
                    var cleared = false
                    let outcome: String
                    switch result {
                    case .failure:
                        // onError has just published this operation's failure.
                        bluetoothActionError = (operation, model.errorGeneration)
                        token = model.errorGeneration.uuidString
                        outcome = "failure"
                    case .success:
                        outcome = "success"
                        if let owned = bluetoothActionError, owned.operation == operation {
                            token = owned.generation.uuidString
                            bluetoothActionError = nil
                            if model.errorGeneration == owned.generation { model.errorMessage = nil; cleared = true }
                        }
                    }
                    diagnostics.emit("bluetooth", "manual_action_finished", outcome: outcome, operation: token,
                                     fields: ["action": action, "error_cleared": String(cleared)])
                }
                module.start()
            }
        } else if let module = bluetooth, !model.stoppingModules.contains(.bluetooth) {
            model.stoppingModules.insert(.bluetooth)
            module.onChange = nil
            module.onError = nil
            module.onManualOperationCompleted = nil
            bluetoothActionError = nil
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
                spaces = SpacesModule(defaults: preferences)
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
        model.pendingArrangement = preferences.data(forKey: "pendingArrangement") != nil
        if controller == nil, let data = preferences.data(forKey: "displayRecords"),
           let records = try? JSONDecoder().decode([DisplayRecord].self, from: data) {
            model.disabledMonitorCount = records.filter(\.disabledByApp).count
        }
        let recoveryNeeded = needsDisplayRecovery
        let observeScreens = modules.needsDisplays || spaces != nil || recoveryNeeded
        if observeScreens && screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.displayConfigurationChanged()
            }
        } else if !observeScreens, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if observeScreens && displayWakeObserver == nil {
            displayWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.displayConfigurationChanged() }
        } else if !observeScreens, let displayWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayWakeObserver)
            self.displayWakeObserver = nil
        }
        if modules.needsDisplays || recoveryNeeded { displayRefresh.requestRefresh() }
        else {
            controller = nil
            layoutFresh = false
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
        else { model.launchWidget = nil; refreshPreferences(); showDashboard() }
    }

    private func displayConfigurationChanged() {
        displayRefresh.requestRefresh()
        DispatchQueue.main.async { [weak self] in
            self?.spaces?.suspend()
            self?.refreshPreferences()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshPreferences()
        showDashboard()
        return true
    }

    private func showDashboard() {
        refreshDisplaysForPresentation()
        if model.navigation.isSetup {
            let group = model.navigation.feature.map(SettingsGroup.forFeature)
            model.navigation = DashboardNavigation()
            showSettings(group); return
        }
        guard let button = item.button, !popover.isShown else { return }
        presentDashboard(relativeTo: button)
    }

    /// The same native popup path can use a fixture-owned anchor without starting
    /// the application, watchdog, feature owners or a real status item.
    @discardableResult
    func presentDashboard(relativeTo button: NSView) -> NSView? {
        guard !popover.isShown else { return popover.contentViewController?.view }
        configurePopover()
        model.popupHeight = max(1, (button.window?.screen?.visibleFrame.height ?? 700) - 80)
        popover.contentSize.height = min(popover.contentSize.height, model.popupHeight, 650)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        let operation = UUID().uuidString
        Diagnostics.shared.emit("popover", "show", operation: operation, fields: ["height_limit": String(Double(model.popupHeight)),
                                "anchor_width": String(Double(button.bounds.width)), "anchor_height": String(Double(button.bounds.height))])
        DispatchQueue.main.async { [weak self] in
            guard let self, popover.isShown, let window = popover.contentViewController?.view.window,
                  let visible = window.screen?.visibleFrame else { return }
            let frame = window.frame
            Diagnostics.shared.emit("popover", "geometry_observed", operation: operation, fields: [
                "width": String(Double(frame.width)), "height": String(Double(frame.height)),
                "visible_width": String(Double(visible.width)), "visible_height": String(Double(visible.height)),
                "left_margin": String(Double(frame.minX - visible.minX)), "right_margin": String(Double(visible.maxX - frame.maxX)),
                "bottom_margin": String(Double(frame.minY - visible.minY)), "top_margin": String(Double(visible.maxY - frame.maxY))])
        }
        refreshDisplaysForPresentation()
        return popover.contentViewController?.view
    }

    private func refreshDisplaysForPresentation() {
        guard modules.needsDisplays || needsDisplayRecovery, !recovering else { return }
        configureDisplayRefresh()
        displayRefresh.requestRefreshForPresentation(snapshotIsFresh: layoutFresh)
    }

    private func showActivity() {
        guard transactions.acceptsActions else { return }
        if activityWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Fix macOS — Activity"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ActivityView(presentation: activityPresentation))
            window.minSize = NSSize(width: 540, height: 360)
            window.center(); activityWindow = window
        }
        if let activityWindow { presentWindow(activityWindow) }
    }

    private func showSettings(_ group: SettingsGroup? = nil) {
        guard transactions.acceptsActions else { return }
        refreshLoginStatus()
        Diagnostics.shared.emit("settings", "open_requested", fields: ["category": (group ?? model.settingsGroup).rawValue])
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
        if let settingsWindow { presentWindow(settingsWindow) }
    }

    private func showSetup() {
        guard transactions.acceptsActions else { return }
        popover.performClose(nil)
        if let setupWindow, activeSetupDraft != nil { presentWindow(setupWindow); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Set up Fix macOS"
        window.isReleasedWhenClosed = false
        let draft = SetupDraft(current: model, defaults: preferences)
        activeSetupDraft = draft; window.delegate = self
        configureSetup(draft)
        window.contentViewController = NSHostingController(rootView: SetupWizard(model: model, draft: draft, close: { [weak window] in window?.close() }))
        window.minSize = NSSize(width: 640, height: 480)
        window.center(); setupWindow = window
        presentWindow(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === setupWindow else { return true }
        return activeSetupDraft?.cancel() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === setupWindow else { return }
        activeSetupDraft = nil; setupWindow = nil
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
        moduleFailures = [:]
        let configuration = draft.configuration
        let selected = draft.selected
        let requestedWidgets = draft.widgets
        // Also hold automatic restoration while a deselected existing owner is
        // waiting for its normal disable operation. Its saved choice is retained.
        setupDesktopReconciliationPending = selected.contains(.spaces) || spaces != nil
        // Install the reviewed choices before *any* activation can synchronously
        // poll or acquire assertions. Restore only unactivated choices on refusal;
        // never overwrite recovery metadata or choices owned by an active feature.
        var staged: [AppModule: [String: Any]] = [:]
        let newlyEnabled = selected.subtracting(modules.enabled)
        for module in newlyEnabled {
            let values = configuration.inactivePreferences(for: module)
            staged[module] = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, preferences.object(forKey: $0) ?? NSNull()) })
            for (key, value) in values { preferences.set(value, forKey: key) }
        }
        if selected.contains(.spaces), let spaces {
            do { try spaces.installSetupIntent(configuration.spaces) }
            catch { moduleFailures[.spaces] = error.localizedDescription }
        }
        func restoreUnactivated(_ module: AppModule) {
            guard !modules.enabled.contains(module), let original = staged.removeValue(forKey: module) else { return }
            for (key, value) in original {
                if value is NSNull { preferences.removeObject(forKey: key) } else { preferences.set(value, forKey: key) }
            }
        }
        // An already-running shared Audio owner must not route with the old
        // policy when another selected feature (notably Bluetooth) starts.
        if selected.contains(.audio), let audio {
            audio.configureForSetup(automatic: configuration.audioAutomatic, output: configuration.outputPreferences,
                input: configuration.inputPreferences, outputFallback: configuration.outputFallback, inputFallback: configuration.inputFallback)
        }
        var results: [String] = []
        draft.outcomes = [:]
        func advance(_ index: Int) {
            guard transactions.acceptsActions else {
                for module in newlyEnabled { restoreUnactivated(module) }
                setupDesktopReconciliationPending = false
                completion(results + ["Remaining setup changes were not applied: shutdown is in progress. Successful changes above remain applied."]); return
            }
            guard index < AppModule.allCases.count else {
                setupDesktopReconciliationPending = false
                _ = model.onSaveWidgets(requestedWidgets)
                uiStore.complete(); draft.discardCheckpoint()
                completion(results + ["Quick-action layout saved. No timed session, clipboard capture, window capture, or pointer Apply was started."])
                return
            }
            let module = AppModule.allCases[index]
            let enabled = selected.contains(module)
            func configure(_ success: Bool) {
                guard transactions.acceptsActions else {
                    for pending in newlyEnabled { restoreUnactivated(pending) }
                    setupDesktopReconciliationPending = false
                    completion(results + ["Remaining setup changes were not applied during shutdown."]); return
                }
                guard success else {
                    restoreUnactivated(module)
                    let outcome = FeatureSetupOutcome.failed(moduleFailures[module] ?? "Busy or recovery is still pending; retry in Settings.")
                    draft.outcomes[module] = outcome; results.append("\(module.title): \(outcome.description)")
                    advance(index + 1); return
                }
                guard enabled else { draft.outcomes[module] = .applied("Disabled."); results.append("\(module.title): disabled."); advance(index + 1); return }
                applySetupConfiguration(configuration, module: module) { outcome in
                    draft.outcomes[module] = outcome; results.append("\(module.title): \(outcome.description)")
                    advance(index + 1)
                }
            }
            if modules.enabled.contains(module) == enabled { configure(true) }
            else { setModule(module, enabled: enabled, completion: configure) }
        }
        advance(0)
    }

    private func applySetupConfiguration(_ value: SetupConfiguration, module: AppModule, completion: @escaping (FeatureSetupOutcome) -> Void) {
        guard transactions.acceptsActions else { completion(.failed("Shutdown in progress.")); return }
        if let failure = moduleFailures[module] { completion(.failed(failure)); return }
        let missing: Bool
        switch module {
        case .audio: missing = audio == nil
        case .bluetooth: missing = bluetooth == nil
        case .quitGuard: missing = quitGuard == nil
        case .keepAwake: missing = !awakeFeature.state.loaded
        case .clipboard: missing = clipboard == nil
        case .windows: missing = windowPositions == nil
        default: missing = false
        }
        guard !missing else { completion(.failed("Feature owner is unavailable. Retry from its Settings group.")); return }
        let old = SetupConfiguration(model)
        var note = ""
        switch module {
        case .monitors:
            if value.confirmDisplays != old.confirmDisplays { model.onMonitorDisableModeChanged(value.confirmDisplays) }
            if !model.displaySupported { completion(.pendingHardware("Display controls await recovery monitoring and stable displays.")); return }
        case .arrangement:
            if value.matchEdges != old.matchEdges { model.onMatchScreenEdgesChanged(value.matchEdges) }
            if value.matchEdges && !AXIsProcessTrusted() { completion(.pendingAccess("Screen edges require Accessibility access.")); return }
            if value.matchEdges && !model.screenEdgesActive { completion(.pendingHardware("Screen edges await stable displays and recovery monitoring.")); return }
        case .audio:
            completion(audio!.configurationOutcome); return
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
            completion(bluetooth!.configurationOutcome); return
        case .quitGuard:
            if value.quitDuration != quitGuard!.duration { quitGuard!.duration = value.quitDuration }
            do {
                if value.quitGuard != quitGuard!.enabled { try quitGuard!.setEnabled(value.quitGuard) }
                refreshQuitGuard()
            } catch { completion(.failed(error.localizedDescription)); return }
            if value.quitGuard && !model.quitGuardActive { completion(.pendingAccess("Hold to quit is inactive; check Accessibility and Retry in Input settings.")); return }
        case .keepAwake:
            completion(awakeFeature.configureForSetup(minutes: value.awakeMinutes, display: value.displayAwake, apps: value.awakeApps)); return
        case .clipboard:
            if value.clipboardDays != old.clipboardDays { model.onClipboardDays(value.clipboardDays) }
            if value.clipboardExclusions != old.clipboardExclusions { model.onClipboardExclusions(value.clipboardExclusions) }
            if value.clipboardPersistence != old.clipboardPersistence { model.onClipboardPersistence(value.clipboardPersistence) }
            if clipboard!.history.storagePending { completion(.failed("Disk cleanup/save is pending; keep Clipboard enabled and retry in Settings.")); return }
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
                if !windowPositions.permitted { completion(.pendingAccess("Accessibility is required before saving or restoring windows.")); return }
                if !value.windowsSelected.isEmpty && !windowPositions.layouts.contains(where: { $0.id == value.windowsSelected }) {
                    completion(.pendingHardware("Chosen window layout is unavailable; its target is preserved.")); return
                }
                note = "No windows captured or moved."
            }
        case .menuBar:
            do {
                if value.compactMenu != menuBarSpacing.enabled || menuBarSpacing.recoveryRequired { try menuBarSpacing.setEnabled(value.compactMenu) }
                if value.hideMenu != menuBar?.enabled { menuBar?.setEnabled(value.hideMenu) }
                refreshMenuBar()
            } catch { completion(.failed(error.localizedDescription)); return }
        case .spaces:
            func finishAnimation(_ success: Bool) {
                guard success, transactions.acceptsActions else { completion(.failed(moduleFailures[.spaces] ?? "Animation change interrupted or unavailable.")); return }
                if value.speed != old.speed { model.onSpeedChanged(TransitionSpeed.from(rawValue: value.speed)) }
                if value.spaces && spaces?.hasPermission != true { completion(.pendingAccess("Desktop switching requires Accessibility access.")); return }
                if value.spaces && (!controlState.inputReady || !value.animations || spaces?.isAvailable != true || spaces?.isDraining == true) { completion(.pendingHardware("Desktop switching awaits the animation preset, recovery monitoring, stable displays and gesture drain.")); return }
                do {
                    // Intent was installed before animation work. Only reconcile
                    // that saved policy now; runtime inactivity is not an Off choice.
                    if value.spaces { try spaces?.restoreSavedState() }
                    refreshPreferences(); completion(.applied("Reviewed animation and desktop-switching policy installed."))
                } catch { completion(.failed(error.localizedDescription)) }
            }
            if value.animations != old.animations { setAnimations(value.animations, resultCompletion: finishAnimation) }
            else { finishAnimation(true) }
            return
        }
        completion(.applied(note))
    }

    private func refreshDisplaySnapshot() {
        if let displaySnapshotRefresh {
            layoutFresh = false
            do { try displaySnapshotRefresh(); layoutFresh = !displayRefresh.isSettling }
            catch { showError(error) }
            return
        }
        guard !recovering, modules.needsDisplays || needsDisplayRecovery else { return }
        if controller == nil {
            do { controller = try DisplayController() }
            catch { showError(error); return }
        }
        guard let controller else { return }
        do { try controller.refreshDisplays() }
        catch { showError(error); return }
        item?.button?.toolTip = "Fix macOS\n" + controller.status()
        model.monitors = controller.monitors
        model.activeMonitorCount = (try? controller.activeIDs().count) ?? 0
        model.displaySupported = controller.supported && safety.isReady
        model.disabledMonitorCount = controller.disabledUUIDs.count
        model.pendingArrangement = controller.hasPendingArrangement
        model.currentLayout = modules.enabled.contains(.arrangement) ? (try? controller.currentLayout()) ?? [] : []
        layoutFresh = !displayRefresh.isSettling
        reconcileWindows()
        model.layoutPreviews = modules.enabled.contains(.arrangement) && modules.enabled.contains(.monitors) ? (try? controller.layoutPreviews()) ?? [:] : [:]
        updateScreenEdges()
        if openArrangementWhenReady, safety.isReady, !model.pendingArrangement, model.disabledMonitorCount == 0,
           model.currentLayout.count > 1 {
            openArrangementWhenReady = false
            showArrangementEditor()
        }
        if !modules.needsDisplays && !needsDisplayRecovery { updateModules() }
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
            model.bluetoothObservationStale = false
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
        model.bluetoothObservationStale = bluetooth.observationStale
        model.bluetoothDeviceStates = bluetooth.deviceStates
        model.bluetoothSummary = bluetooth.reconnectSummary
        model.protectOtherAudio = bluetooth.protectOtherAudio
        model.switchAudioOutput = bluetooth.switchAudioOutput
        model.protectedAudioAddresses = bluetooth.protectedAudioAddresses
        model.legacyServicePresent = bluetooth.legacyServicePresent
        if let data = bluetooth.diagnostics() { preferences.set(data, forKey: "bluetooth.lastSnapshot") }
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
            preferences.set(data, forKey: "bluetooth.guiTestResult")
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
        model.matchScreenEdges = preferences.bool(forKey: "arrangement.matchEdges")
        updateScreenEdges()
        model.displaySupported = controller?.supported == true && safety.isReady
        model.confirmMonitorDisable = preferences.bool(forKey: "monitors.confirmDisable")
        model.animationsEnabled = animations.enabled
        model.animationRecoveryRequired = animations.recoveryRequired
        if transactions.acceptsActions && !setupDesktopReconciliationPending && animations.enabled && !model.animationsBusy && controlState.inputReady && spaces?.isAvailable == true {
            do { try spaces?.restoreSavedState() } catch { showError(error) }
        }
        model.spacesEnabled = spaces?.isEnabled ?? false
        model.spacesPermission = spaces?.hasPermission ?? false
        model.spacesAvailable = spaces?.isAvailable == true && spaces?.isDraining != true && controlState.inputReady
        model.spacesSpeed = spaces?.speed ?? .instant
        refreshLoginStatus()
        publishModuleStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        let status = loginService.status
        model.loginStatus = status
        let value = LoginDiagnostics.status(status)
        if loggedLoginStatus != value {
            loggedLoginStatus = value
            diagnostics.emit("login", "status_observed", fields: ["status": value])
        }
    }

    private var controlState: SystemControlLifecycle.State {
        if var state = controlStateSnapshot?() {
            state.watchdogReady = state.watchdogReady && transactions.acceptsActions
            return state
        }
        return SystemControlLifecycle.State(watchdogReady: safety.isReady && transactions.acceptsActions, displaySettling: displayRefresh.isSettling,
            displayOperation: recovering, pendingConfirmation: model.pendingArrangement || rollbackUUID != nil,
            layoutFresh: layoutFresh, cursorRequested: preferences.bool(forKey: "arrangement.matchEdges"),
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
                    restartAnimationClients()
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        model.animationsBusy = false
                        completion?()
                        if enabled && !preserveChoice, let spaces,
                           spaces.hasPermission || preferences.object(forKey: "spaces.enabled") != nil {
                            // Re-arm an existing choice even without access; passive
                            // restoration waits for permission/readiness without prompting.
                            // Keep the legacy unset-choice default conditional on access.
                            spaces.requestRestore(enabled: preferences.object(forKey: "spaces.enabled") == nil || spaces.savedEnabled)
                        }
                        refreshPreferences()
                        resultCompletion?(true)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.model.animationsBusy = false
                        self?.moduleFailures[.spaces] = error.localizedDescription
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
    enum DisplayCommandPermission { case recovery, supervisedMutation }
    private struct DisplayAuthorizationError: LocalizedError {
        var errorDescription: String? { "The recovery watchdog is unavailable. Retry the display change after supervision is ready." }
    }

    func runDisplayCommand(executable: String, arguments: [String], permission: DisplayCommandPermission = .recovery,
                           completion: @escaping (Result<String, Error>) -> Void) {
        afterGestureDrain { [self] in
            recoveryQueue.async { [self] in
                // Check at the executor boundary, not before asynchronous gesture
                // drain/queueing. Read main-owned supervision on the main queue;
                // the host never synchronously waits on this executor.
                let authorized = permission == .recovery || DispatchQueue.main.sync { self.controlState.watchdogReady }
                let result = Result {
                    guard authorized else { throw DisplayAuthorizationError() }
                    return try commandRunner.run(executable, arguments)
                }
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
            "keepAwakeLoaded": awakeFeature.state.loaded, "keepAwakeActive": awakeFeature.state.active,
            "mouseLoaded": mouseLifecycle.module != nil, "mouseActive": mouseLifecycle.module?.active == true,
            "mouseRecoveryRequired": model.mouseRecoveryRequired,
            "animationsEnabled": animations.enabled, "animationsBusy": model.animationsBusy,
            "screenEdgesActive": screenEdges?.isRunning == true,
            "displayDiscoveryLoaded": controller != nil, "screenObserverInstalled": screenObserver != nil,
            "arrangementEditorLoaded": arrangementWindow?.contentView != nil
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            preferences.set(data, forKey: "modules.runtimeStatus")
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
        guard modules.enabled.contains(.monitors), controlState.recoveryReady, (enabled || controlState.watchdogReady), !recovering, !displayRefresh.isSettling, !model.pendingArrangement,
              rollbackUUID == nil || (enabled && rollbackUUID == uuid),
              let executable = Bundle.main.executableURL?.path else {
            activity.record(.displayPower(enabled), trigger: .user, result: .blocked)
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
        let operation = activity.begin(.displayPower(enabled), trigger: .user)
        activityRecoveryFailures.removeAll()
        runDisplayCommand(executable: executable, arguments: arguments, permission: enabled ? .recovery : .supervisedMutation) { [weak self] result in
                guard let self else { return }
                recovering = false
                model.monitorBusy = false
                if case .failure(let error) = result, error is DisplayAuthorizationError {
                    activity.finish(operation, result: .blocked)
                    showError(error)
                    refreshPreferences()
                    return // No helper ran: no snapshot delay or synthetic rollback ownership.
                }
                displayRefresh.requestRefresh()
                switch result {
                case .success:
                    activity.finish(operation, result: confirmDisable ? .awaitingConfirmation : .completed)
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
                                restoreAll(reason: .timeout) { restored in if restored { self.clearRollback() } }
                            }
                        }
                        rollbackTimer = timer
                        RunLoop.main.add(timer, forMode: .common)
                        refreshPreferences()
                    }
                case .failure(let error):
                    activity.finish(operation, result: .uncertainDisplay)
                    showError(error)
                    // A timed-out helper may have committed before reporting failure.
                    rollbackUUID = uuid
                    rollbackDeadline = Date()
                    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                        self?.restoreAll(reason: .failedChange) { restored in if restored { self?.clearRollback() } }
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
            activity.record(.displayArrangement, trigger: .user, result: .blocked)
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
        let operation = activity.begin(.displayArrangement, trigger: .user)
        activityRecoveryFailures.removeAll()
        runDisplayCommand(executable: executable, arguments: ["--arrange-displays", data.base64EncodedString()], permission: .supervisedMutation) { [weak self] result in
                guard let self else { return }
                recovering = false
                model.monitorBusy = false
                if case .failure(let error) = result, error is DisplayAuthorizationError {
                    activity.finish(operation, result: .blocked)
                    showError(error)
                    refreshPreferences()
                    return
                }
                model.pendingArrangement = true
                rollbackUUID = "layout"
                let duration: TimeInterval
                switch result {
                case .success: duration = 20; activity.finish(operation, result: .awaitingConfirmation)
                case .failure(let error): duration = 0; activity.finish(operation, result: .uncertainDisplay); showError(error)
                }
                rollbackDeadline = Date().addingTimeInterval(duration)
                model.countdowns["layout"] = Int(duration)
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, let deadline = rollbackDeadline else { return }
                    let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                    model.countdowns["layout"] = remaining
                    if remaining == 0, !recovering { restoreAll(reason: duration == 0 ? .failedChange : .timeout) }
                }
                rollbackTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                displayRefresh.requestRefresh()
                showDashboard()
        }
    }

    private func restoreAll(reason: ActivityRecoveryReason = .user, completion: ((Bool) -> Void)? = nil) {
        guard controlState.recoveryReady else {
            if reason == .user || activityRecoveryFailures[reason].map({ activity.contains($0) }) != true {
                let operation = activity.begin(.displayRecovery(reason), trigger: reason.trigger)
                activity.finish(operation, result: .blocked)
                activityRecoveryFailures[reason] = operation
            }
            showError(ToggleError(message: "Wait for display connections to settle before recovery."))
            completion?(false)
            return
        }
        guard let executable = Bundle.main.executableURL?.path else { completion?(false); return }
        let previousFailure = activityRecoveryFailures[reason]
        let suppress = reason != .user && previousFailure.map({ activity.contains($0) }) == true
        let operation = suppress ? nil : activity.begin(.displayRecovery(reason), trigger: reason.trigger)
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
                case .success:
                    if let operation { self.activity.finish(operation, result: .completed) }
                    else if let previousFailure, self.activity.contains(previousFailure) {
                        self.activity.record(.displayRecovery(reason), trigger: reason.trigger, result: .completed)
                    }
                    self.activityRecoveryFailures.removeValue(forKey: reason)
                    self.model.pendingArrangement = false; self.clearRollback(); completion?(true)
                case .failure(let error):
                    if let operation {
                        self.activity.finish(operation, result: .failed)
                        self.activityRecoveryFailures[reason] = operation
                    }
                    self.showError(error); completion?(false)
                }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let actions = HostTransactions.QuitActions(
            isBusy: { self.model.animationsBusy || !self.model.stoppingModules.isEmpty || self.recovering },
            prepareMouse: { self.mouseLifecycle.prepareToQuit() },
            quiesce: { self.windowPositions?.invalidate(); self.screenEdges?.stop() },
            prepareClipboard: { self.clipboard?.prepareTermination() != false },
            needsDisplayRecovery: { self.needsDisplayRecovery },
            restoreDisplays: { self.restoreAll(reason: .quit, completion: $0) },
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
        awakeFeature.shutdown()
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
        if let displayWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayWakeObserver) }
    }
}
