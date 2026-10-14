import AppKit
import SwiftUI
import ServiceManagement
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DisplayController?
    private var bluetooth: BluetoothModule?
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
    private let sourceUpdater = SourceUpdater()
    private let animationQueue = DispatchQueue(label: "fix-mac-os.animation-preferences")
    private let modules = ModuleSettings()
    private let model = DashboardModel()
    private let popover = NSPopover()
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

    init(commandRunner: CommandRunning = CommandRunner(), spaces: SpacesModule? = nil) {
        self.commandRunner = commandRunner
        self.spaces = spaces
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--test-connect-in-gui"), index + 1 < CommandLine.arguments.count {
            guiTestTarget = CommandLine.arguments[index + 1]
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preserve-audio-output"), index + 1 < CommandLine.arguments.count {
            guiTestOriginalOutput = CommandLine.arguments[index + 1]
        }
        configureActions()
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
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
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
        if CommandLine.arguments.contains("--show-dashboard") {
            model.tab = CommandLine.arguments.contains("--show-monitors") ? .monitors : .bluetooth
            if CommandLine.arguments.contains("--show-modules") { model.tab = .modules }
            if CommandLine.arguments.contains("--show-spaces") { model.tab = .spaces }
            if CommandLine.arguments.contains("--show-menu-bar") { model.tab = .menuBar }
            if CommandLine.arguments.contains("--show-keyboard") { model.tab = .keyboard }
            if CommandLine.arguments.contains("--show-keep-awake") { model.tab = .keepAwake }
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        }
    }

    private func configureActions() {
        model.onKeepAwakeStart = { [weak self] in self?.performKeepAwake { try $0.start() } }
        model.onKeepAwakeStop = { [weak self] in self?.performKeepAwake { try $0.stop() } }
        model.onKeepAwakeExtend = { [weak self] in self?.performKeepAwake { try $0.extend() } }
        model.onKeepAwakeResume = { [weak self] in self?.performKeepAwake { try $0.resumeApps() } }
        model.onKeepAwakeRemoveApp = { [weak self] id in self?.performKeepAwake { try $0.setApp(id, name: id, selected: false) } }
        model.onKeepAwakeAddApp = { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Choose apps that keep the Mac awake"
            panel.allowedContentTypes = [.applicationBundle]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                self?.performKeepAwake { try $0.setApp(id, name: url.deletingPathExtension().lastPathComponent, selected: true) }
            }
        }
        model.onKeepAwakeMinutesChanged = { [weak self] in self?.keepAwake?.selectedMinutes = $0 }
        model.onKeepDisplayAwakeChanged = { [weak self] enabled in self?.performKeepAwake { try $0.setKeepDisplayAwake(enabled) } }
        model.onQuitGuardChanged = { [weak self] enabled in
            guard let self else { return }
            do { try quitGuard?.setEnabled(enabled) } catch { showError(error) }
            refreshQuitGuard()
        }
        model.onQuitGuardDurationChanged = { [weak self] in self?.quitGuard?.duration = $0 }
        model.onRetryQuitGuard = { [weak self] in
            guard let self else { return }
            do { try quitGuard?.startIfEnabled() } catch { showError(error) }
            refreshQuitGuard()
        }
        model.onCompactMenuBarChanged = { [weak self] enabled in
            guard let self else { return }
            do { try menuBarSpacing.setEnabled(enabled) } catch { showError(error) }
            refreshMenuBar()
        }
        model.onRestoreMenuBarSpacing = { [weak self] in
            guard let self else { return }
            do { try menuBarSpacing.restore() } catch { showError(error) }
            refreshMenuBar()
        }
        model.onMenuBarHidingChanged = { [weak self] in self?.menuBar?.setEnabled($0) }
        model.onToggleMenuBar = { [weak self] in self?.menuBar?.toggle() }
        model.onModuleChanged = { [weak self] module, enabled in self?.setModule(module, enabled: enabled) }
        model.onMonitorChanged = { [weak self] uuid, enabled in self?.setMonitor(uuid, enabled: enabled) }
        model.onMonitorDisableModeChanged = { [weak self] confirm in
            UserDefaults.standard.set(confirm, forKey: "monitors.confirmDisable")
            self?.refreshPreferences()
        }
        model.onMatchScreenEdgesChanged = { [weak self] enabled in
            guard let self else { return }
            UserDefaults.standard.set(enabled, forKey: "arrangement.matchEdges")
            refreshPreferences()
            updateScreenEdges()
        }
        model.onKeepDisabled = { [weak self] uuid in
            guard let self, rollbackUUID == uuid else { return }
            clearRollback()
        }
        model.onRestoreAll = { [weak self] in self?.restoreAll() }
        model.onArrangeDisplays = { [weak self] in self?.showArrangementEditor() }
        model.onKeepArrangement = { [weak self] in
            guard let self, !recovering, rollbackUUID == "layout" else { return }
            UserDefaults.standard.removeObject(forKey: "pendingArrangement")
            UserDefaults.standard.synchronize()
            model.pendingArrangement = false
            clearRollback()
        }
        model.onAutoDeviceChanged = { [weak self] address, enabled in self?.bluetooth?.setAutoReconnect(enabled, for: address) }
        model.onManualConnection = { [weak self] in self?.bluetooth?.toggleConnection($0) }
        model.onAutomaticReconnectChanged = { [weak self] in self?.bluetooth?.autoEnabled = $0 }
        model.onBluetoothPowerOn = { [weak self] in self?.bluetooth?.turnBluetoothOn() }
        model.onBluetoothAccessRequested = { [weak self] in self?.bluetooth?.requestBluetoothAccess() }
        model.onProtectAudioChanged = { [weak self] enabled in self?.bluetooth?.protectOtherAudio = enabled; self?.refreshBluetooth() }
        model.onSwitchAudioChanged = { [weak self] enabled in self?.bluetooth?.switchAudioOutput = enabled; self?.refreshBluetooth() }
        model.onProtectedDeviceChanged = { [weak self] address, enabled in
            guard let self else { return }
            if enabled { bluetooth?.protectedAudioAddresses.insert(address) }
            else { bluetooth?.protectedAudioAddresses.remove(address) }
            refreshBluetooth()
        }
        model.onTakeOverLegacy = { [weak self] in self?.bluetooth?.takeOverLegacyService() }
        model.onSpacesChanged = { [weak self] enabled in
            guard let self else { return }
            guard !enabled || controlState.inputReady else {
                showError(ToggleError(message: "Wait for the watchdog and pending display changes before enabling Space interception.")); return
            }
            do { try spaces?.setEnabled(enabled) } catch { showError(error) }
            refreshPreferences()
        }
        model.onAnimationsChanged = { [weak self] enabled in self?.setAnimations(enabled) }
        model.onRestoreAnimations = { [weak self] in self?.setAnimations(false, recoverOnly: true) }
        model.onCheckUpdates = { [weak self] in self?.sourceUpdater.check(force: true) }
        model.onInstallUpdate = { [weak self] in
            do { try self?.sourceUpdater.install() } catch { self?.showError(error) }
        }
        model.onSpeedChanged = { [weak self] speed in self?.spaces?.speed = speed; self?.refreshPreferences() }
        model.onLoginChanged = { [weak self] enabled in
            guard let self else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { showError(error) }
            refreshPreferences()
        }
        model.onClose = { [weak self] in self?.popover.performClose(nil) }
        model.onQuit = { NSApp.terminate(nil) }
    }

    private func setModule(_ module: AppModule, enabled: Bool) {
        guard !model.stoppingModules.contains(module) else { return }
        if module == .keepAwake && !enabled {
            do { try keepAwake?.stop() } catch { showError(error); return }
        }
        if module == .menuBar && !enabled {
            do { try menuBarSpacing.restore(preserveChoice: true) }
            catch { refreshMenuBar(); showError(error); return }
        }
        if module == .spaces {
            guard !model.animationsBusy else { return }
            setAnimations(enabled && animations.enabled, preserveChoice: true) { [weak self] in
                guard let self else { return }
                modules.set(module, enabled: enabled)
                updateModules()
            }
            return
        }
        if module == .monitors || module == .arrangement {
            guard !recovering else { showError(ToggleError(message: "Wait for the current display operation to finish.")); return }
            if !enabled && (model.disabledMonitorCount > 0 || model.pendingArrangement || rollbackUUID != nil) {
                model.stoppingModules.insert(module)
                restoreAll { [weak self] restored in
                    guard let self else { return }
                    model.stoppingModules.remove(module)
                    if restored { modules.set(module, enabled: false); updateModules() }
                }
                return
            }
        }
        modules.set(module, enabled: enabled)
        updateModules()
    }

    private func performKeepAwake(_ action: (KeepAwakeModule) throws -> Void) {
        guard let keepAwake else { return }
        do { try action(keepAwake) } catch { showError(error) }
        refreshKeepAwake()
    }

    private func refreshKeepAwake() {
        model.keepAwakeActive = keepAwake?.active ?? false
        model.keepAwakeRemaining = keepAwake?.remaining ?? 0
        model.keepAwakeMinutes = keepAwake?.selectedMinutes ?? 30
        model.keepAwakeApps = keepAwake?.selectedApps ?? [:]
        model.keepAwakeAppNames = keepAwake?.activeAppNames ?? []
        model.keepAwakeAppsPaused = keepAwake?.appsPaused ?? false
        model.keepDisplayAwake = keepAwake?.keepDisplayAwake ?? false
        item?.button?.image = NSImage(systemSymbolName: model.keepAwakeActive ? "cup.and.saucer.fill" : "slider.horizontal.3", accessibilityDescription: "Fix macOS")
        item?.button?.toolTip = model.keepAwakeActive ? "Fix macOS — keeping awake" : "Fix macOS"
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

    @objc private func toggleDashboard() {
        if popover.isShown { popover.performClose(nil) }
        else { refreshPreferences(); showDashboard(); displayRefresh.requestRefresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshPreferences()
        showDashboard()
        displayRefresh.requestRefresh()
        return true
    }

    private func showDashboard() {
        guard let button = item.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
        model.matchScreenEdges = UserDefaults.standard.bool(forKey: "arrangement.matchEdges")
        updateScreenEdges()
        model.displaySupported = controller?.supported == true && safety.isReady
        model.confirmMonitorDisable = UserDefaults.standard.bool(forKey: "monitors.confirmDisable")
        model.animationsEnabled = animations.enabled
        model.animationRecoveryRequired = animations.recoveryRequired
        if animations.enabled && !model.animationsBusy && controlState.inputReady && spaces?.isAvailable == true {
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
        SystemControlLifecycle.State(watchdogReady: safety.isReady, displaySettling: displayRefresh.isSettling,
            displayOperation: recovering, pendingConfirmation: model.pendingArrangement || rollbackUUID != nil,
            layoutFresh: layoutFresh, cursorRequested: UserDefaults.standard.bool(forKey: "arrangement.matchEdges"),
            arrangementEnabled: modules.enabled.contains(.arrangement), layout: model.currentLayout)
    }

    private func updateScreenEdges() {
        do { try controlLifecycle.reconcile(controlState) }
        catch { showError(error) }
        model.screenEdgesActive = screenEdges?.isRunning == true
    }

    private func setAnimations(_ enabled: Bool, preserveChoice: Bool = false, recoverOnly: Bool = false, completion: (() -> Void)? = nil) {
        guard !model.animationsBusy else { return }
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
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.model.animationsBusy = false
                        self?.showError(error)
                        self?.refreshPreferences()
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
        guard !model.animationsBusy else { showError(ToggleError(message: "Wait for animation settings to finish saving.")); return .terminateCancel }
        guard !recovering else { showError(ToggleError(message: "Wait for the current display operation before quitting.")); return .terminateCancel }
        guard model.disabledMonitorCount > 0 || rollbackUUID != nil || model.pendingArrangement else {
            guard let spaces else { return .terminateNow }
            spaces.onChange = nil
            // Always reply asynchronously: an idle engine can drain immediately.
            spaces.stop { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
            return .terminateLater
        }
        restoreAll { restored in sender.reply(toApplicationShouldTerminate: restored) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? keepAwake?.stop()
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
