import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DisplayController()
    private let bluetooth = BluetoothModule()
    private let spaces = SpacesModule()
    private let model = DashboardModel()
    private let popover = NSPopover()
    private var item: NSStatusItem!
    private var busy = false
    private var wantsDashboardOpen = false
    private var restoreTimers: [String: Timer] = [:]
    private var countdowns: [String: Int] = [:]
    private var screenObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureActions()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Mac Utils")
        item.button?.target = self
        item.button?.action = #selector(toggleDashboard)
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeDashboard()
        }
        bluetooth.onChange = { [weak self] in self?.refresh() }
        bluetooth.onError = { [weak self] in self?.showError($0) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
        bluetooth.start()
        if !controller.disabledUUIDs.isEmpty { restoreAll() }
    }

    private func configureActions() {
        model.onMonitorChanged = { [weak self] uuid, enabled in self?.setMonitor(uuid, enabled: enabled) }
        model.onKeepDisabled = { [weak self] uuid in self?.cancelCountdown(uuid); self?.refresh() }
        model.onRestoreAll = { [weak self] in self?.restoreAll() }
        model.onAutoDeviceChanged = { [weak self] address, enabled in self?.bluetooth.setAutoReconnect(enabled, for: address) }
        model.onManualConnection = { [weak self] in self?.bluetooth.toggleConnection($0) }
        model.onAutomaticReconnectChanged = { [weak self] in self?.bluetooth.autoEnabled = $0 }
        model.onProtectAudioChanged = { [weak self] enabled in self?.bluetooth.protectOtherAudio = enabled; self?.refresh() }
        model.onSwitchAudioChanged = { [weak self] enabled in self?.bluetooth.switchAudioOutput = enabled; self?.refresh() }
        model.onProtectedDeviceChanged = { [weak self] address, enabled in
            guard let self else { return }
            if enabled { bluetooth.protectedAudioAddresses.insert(address) }
            else { bluetooth.protectedAudioAddresses.remove(address) }
            refresh()
        }
        model.onTakeOverLegacy = { [weak self] in self?.bluetooth.takeOverLegacyService() }
        model.onSpacesChanged = { [weak self] enabled in
            guard let self else { return }
            do { try spaces.setEnabled(enabled) } catch { showError(error) }
            refresh()
        }
        model.onSpeedChanged = { [weak self] speed in self?.spaces.speed = speed; self?.refresh() }
        model.onLoginChanged = { [weak self] enabled in
            guard let self else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { showError(error) }
            refresh()
        }
        model.onClose = { [weak self] in self?.closeDashboard() }
        model.onQuit = { NSApp.terminate(nil) }
    }

    @objc private func toggleDashboard() {
        if popover.isShown { closeDashboard() }
        else { wantsDashboardOpen = true; refresh(); showDashboard() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        wantsDashboardOpen = true
        refresh()
        showDashboard()
        return true
    }

    private func showDashboard() {
        guard let button = item.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closeDashboard() {
        wantsDashboardOpen = false
        popover.performClose(nil)
    }

    private func refresh() {
        controller.refreshDisplays()
        item?.button?.toolTip = "Mac Utils\n" + controller.status()
        model.monitors = controller.monitors
        model.monitorBusy = busy
        model.activeMonitorCount = (try? controller.activeIDs().count) ?? 0
        model.displaySupported = controller.supported && controller.canDisableDisplays
        model.countdowns = countdowns
        model.disabledMonitorCount = controller.disabledUUIDs.count
        model.devices = bluetooth.devices
        model.selectedAddresses = bluetooth.autoAddresses
        model.automaticReconnectEnabled = bluetooth.autoEnabled
        model.bluetoothAvailable = bluetooth.available
        model.bluetoothBusy = bluetooth.isBusy
        model.bluetoothSummary = bluetooth.reconnectSummary
        model.protectOtherAudio = bluetooth.protectOtherAudio
        model.switchAudioOutput = bluetooth.switchAudioOutput
        model.protectedAudioAddresses = bluetooth.protectedAudioAddresses
        model.legacyServicePresent = bluetooth.legacyServicePresent
        model.spacesEnabled = spaces.isEnabled
        model.spacesPermission = spaces.hasPermission
        model.spacesAvailable = spaces.isAvailable
        model.spacesSpeed = spaces.speed
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        // Disabling the main monitor can remove the popover's original anchor.
        // Re-anchor on the surviving screen, unless the user explicitly closed it.
        if wantsDashboardOpen && !busy && !popover.isShown { showDashboard() }
    }

    private func showError(_ error: Error) { model.errorMessage = error.localizedDescription }

    private func setMonitor(_ uuid: String, enabled: Bool) {
        guard !busy else { return }
        if enabled { enable(uuid); return }
        busy = true
        do {
            try controller.setEnabled(false, for: uuid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                busy = false
                if controller.isEnabled(uuid) {
                    showError(ToggleError(message: "macOS accepted the request but the monitor is still active."))
                } else {
                    countdowns[uuid] = 20
                    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        self.countdowns[uuid, default: 0] -= 1
                        if self.countdowns[uuid, default: 0] <= 0 && !self.busy { self.enable(uuid) }
                        self.refresh()
                    }
                    restoreTimers[uuid] = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
                refresh()
            }
        } catch { busy = false; showError(error) }
        refresh()
    }

    private func cancelCountdown(_ uuid: String) {
        restoreTimers.removeValue(forKey: uuid)?.invalidate()
        countdowns.removeValue(forKey: uuid)
    }

    private func enable(_ uuid: String, completion: ((Bool) -> Void)? = nil) {
        cancelCountdown(uuid)
        busy = true
        do {
            try controller.setEnabled(true, for: uuid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                do {
                    try controller.finishRestore(uuid)
                    busy = false
                    refresh()
                    completion?(true)
                } catch { busy = false; refresh(); showError(error); completion?(false) }
            }
        } catch { busy = false; refresh(); showError(error); completion?(false) }
        refresh()
    }

    private func restoreAll(completion: ((Bool) -> Void)? = nil) {
        let pending = controller.disabledUUIDs
        func next(_ index: Int, success: Bool) {
            guard index < pending.count else { completion?(success); return }
            enable(pending[index]) { restored in next(index + 1, success: success && restored) }
        }
        next(0, success: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !controller.disabledUUIDs.isEmpty else { return .terminateNow }
        restoreAll { restored in sender.reply(toApplicationShouldTerminate: restored) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bluetooth.stop()
        spaces.stop()
        restoreTimers.values.forEach { $0.invalidate() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }
}
