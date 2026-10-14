import AppKit
import SwiftUI
import ServiceManagement
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var controller = DisplayController()
    private let bluetooth = BluetoothModule()
    private let spaces = SpacesModule()
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
    private var screenObserver: NSObjectProtocol?
    private var guiTestTarget: String?
    private var guiTestStarted = false
    private var guiTestFinished = false
    private var guiTestOriginalOutput: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--test-connect-in-gui"), index + 1 < CommandLine.arguments.count {
            guiTestTarget = CommandLine.arguments[index + 1]
            bluetooth.suspendAutomaticReconnection = true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preserve-audio-output"), index + 1 < CommandLine.arguments.count {
            guiTestOriginalOutput = CommandLine.arguments[index + 1]
        }
        configureActions()
        safety.onStatusChanged = { [weak self] status in
            guard let self else { return }
            if model.watchdogStatus != status { logger.notice("Watchdog status: \(status, privacy: .public)") }
            model.watchdogStatus = status
            spaces.isAvailable = safety.isReady
            if !safety.isReady { try? spaces.setEnabled(false) }
            refreshPreferences()
            displayRefresh.requestRefresh()
        }
        do { try safety.start() }
        catch { showError(ToggleError(message: "Could not start the recovery watchdog: \(error.localizedDescription)")) }
        displayRefresh.onSettlingChanged = { [weak self] settling in
            guard let self else { return }
            logger.notice("Display refresh settling: \(settling, privacy: .public)")
            model.displaySettling = settling
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
        bluetooth.onChange = { [weak self] in self?.refreshBluetooth() }
        bluetooth.onError = { [weak self] in self?.showError($0) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Return without CG/ColorSync calls while AppKit acknowledges the
            // synchronous screen-change notification. Read only after it settles.
            self?.displayRefresh.requestRefresh()
            DispatchQueue.main.async { [weak self] in
                try? self?.spaces.setEnabled(false)
                self?.refreshPreferences()
            }
        }
        refreshPreferences()
        refreshBluetooth()
        displayRefresh.requestRefresh()
        bluetooth.start()
        if CommandLine.arguments.contains("--request-bluetooth-access") {
            DispatchQueue.main.async { [weak self] in self?.bluetooth.requestBluetoothAccess() }
        }
        // No graphics transactions, gesture taps, or automatic restore at launch.
        if CommandLine.arguments.contains("--show-dashboard") {
            model.tab = CommandLine.arguments.contains("--show-monitors") ? .monitors : .bluetooth
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        }
    }

    private func configureActions() {
        model.onMonitorChanged = { [weak self] uuid, enabled in self?.setMonitor(uuid, enabled: enabled) }
        model.onKeepDisabled = { [weak self] uuid in
            guard let self, rollbackUUID == uuid else { return }
            clearRollback()
        }
        model.onRestoreAll = { [weak self] in self?.restoreAll() }
        model.onAutoDeviceChanged = { [weak self] address, enabled in self?.bluetooth.setAutoReconnect(enabled, for: address) }
        model.onManualConnection = { [weak self] in self?.bluetooth.toggleConnection($0) }
        model.onAutomaticReconnectChanged = { [weak self] in self?.bluetooth.autoEnabled = $0 }
        model.onBluetoothPowerOn = { [weak self] in self?.bluetooth.turnBluetoothOn() }
        model.onBluetoothAccessRequested = { [weak self] in self?.bluetooth.requestBluetoothAccess() }
        model.onProtectAudioChanged = { [weak self] enabled in self?.bluetooth.protectOtherAudio = enabled; self?.refreshBluetooth() }
        model.onSwitchAudioChanged = { [weak self] enabled in self?.bluetooth.switchAudioOutput = enabled; self?.refreshBluetooth() }
        model.onProtectedDeviceChanged = { [weak self] address, enabled in
            guard let self else { return }
            if enabled { bluetooth.protectedAudioAddresses.insert(address) }
            else { bluetooth.protectedAudioAddresses.remove(address) }
            refreshBluetooth()
        }
        model.onTakeOverLegacy = { [weak self] in self?.bluetooth.takeOverLegacyService() }
        model.onSpacesChanged = { [weak self] enabled in
            guard let self else { return }
            guard !enabled || (safety.isReady && !recovering && !displayRefresh.isSettling && rollbackUUID == nil) else {
                showError(ToggleError(message: "Wait for the watchdog and pending display changes before enabling Space interception.")); return
            }
            do { try spaces.setEnabled(enabled) } catch { showError(error) }
            refreshPreferences()
        }
        model.onSpeedChanged = { [weak self] speed in self?.spaces.speed = speed; self?.refreshPreferences() }
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
        guard !recovering else { return }
        controller.refreshDisplays()
        item.button?.toolTip = "Fix macOS\n" + controller.status()
        model.monitors = controller.monitors
        model.activeMonitorCount = (try? controller.activeIDs().count) ?? 0
        model.displaySupported = controller.supported && safety.isReady
        model.disabledMonitorCount = controller.disabledUUIDs.count
        model.currentLayout = (try? controller.currentLayout()) ?? []
        model.layoutPreviews = (try? controller.layoutPreviews()) ?? [:]
    }

    private func refreshBluetooth() {
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
        guard let name = guiTestTarget, !guiTestFinished, !bluetooth.permissionRequired,
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
        model.spacesEnabled = spaces.isEnabled
        model.spacesPermission = spaces.hasPermission
        model.spacesAvailable = spaces.isAvailable && !recovering && !displayRefresh.isSettling && rollbackUUID == nil
        model.spacesSpeed = spaces.speed
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
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
        guard safety.isReady, !recovering, !displayRefresh.isSettling,
              rollbackUUID == nil || (enabled && rollbackUUID == uuid),
              let executable = Bundle.main.executableURL?.path else {
            showError(ToggleError(message: "Wait for the watchdog, display changes, and current confirmation to finish."))
            return
        }
        // Do not synthesize Space gestures while display topology is changing.
        try? spaces.setEnabled(false)
        refreshPreferences()
        recovering = true
        model.monitorBusy = true
        recoveryQueue.async { [weak self] in
            let result = Result { try CommandRunner().run(executable, ["--set-display", uuid, enabled ? "on" : "off"]) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                recovering = false
                model.monitorBusy = false
                displayRefresh.requestRefresh()
                switch result {
                case .success:
                    if enabled { clearRollback() }
                    else {
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
    }

    private func restoreAll(completion: ((Bool) -> Void)? = nil) {
        guard !recovering, !displayRefresh.isSettling else {
            showError(ToggleError(message: "Wait for display connections to settle before recovery."))
            completion?(false)
            return
        }
        guard let executable = Bundle.main.executableURL?.path else { completion?(false); return }
        try? spaces.setEnabled(false)
        refreshPreferences()
        recovering = true
        model.monitorBusy = true
        // Even explicit recovery is outside the UI process and time-limited.
        recoveryQueue.async { [weak self] in
            let result = Result { try CommandRunner().run(executable, ["--restore"]) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.recovering = false
                self.model.monitorBusy = false
                self.displayRefresh.requestRefresh()
                switch result {
                case .success: self.clearRollback(); completion?(true)
                case .failure(let error): self.showError(error); completion?(false)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !recovering else { showError(ToggleError(message: "Wait for the current display operation before quitting.")); return .terminateCancel }
        guard model.disabledMonitorCount > 0 || rollbackUUID != nil else { return .terminateNow }
        restoreAll { restored in sender.reply(toApplicationShouldTerminate: restored) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bluetooth.stop()
        spaces.stop()
        safety.stop()
        rollbackTimer?.invalidate()
        displayRefresh.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
