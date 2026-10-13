import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DisplayController()
    private let bluetooth = BluetoothModule()
    private let spaces = SpacesModule()
    private var settingsWindow: SettingsWindow?
    private var item: NSStatusItem!
    private var busy = false
    private var restoreTimers: [String: Timer] = [:]
    private var countdowns: [String: Int] = [:]
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.minimumWidth = 340
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Mac Utils")
        bluetooth.onChange = { [weak self] in
            self?.refresh()
            self?.settingsWindow?.refreshIfNeeded()
        }
        bluetooth.onError = { [weak self] error in self?.showError(error) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.busy else { return }
            self.refresh()
        }
        refresh()
        bluetooth.start()
        if !controller.disabledUUIDs.isEmpty { restoreAll() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        item.menu?.addItem(entry)
        return entry
    }

    private func refresh() {
        controller.refreshDisplays()
        item.button?.toolTip = "Mac Utils\n" + controller.status()
        item.menu?.removeAllItems()
        add(busy ? "Switching…" : "Monitors", enabled: false)
        let monitors = controller.monitors
        let activeCount = (try? controller.activeIDs().count) ?? 0
        if monitors.isEmpty { add("No monitors found", enabled: false) }
        for monitor in monitors {
            let canToggle = !busy && controller.supported && monitor.id != nil && (!monitor.enabled || activeCount > 1)
            let row = add(monitor.name)
            row.view = MonitorRow(monitor: monitor, canToggle: canToggle, target: self, action: #selector(toggleSwitch(_:)))
            if let remaining = countdowns[monitor.uuid] {
                let confirm = add("Keep \(monitor.name) disabled (\(remaining)s)", action: #selector(keepDisabled(_:)), enabled: !busy)
                confirm.representedObject = monitor.uuid
            }
        }
        item.menu?.addItem(.separator())
        add("Enable all disabled monitors", action: #selector(enableAll), enabled: !busy && !controller.disabledUUIDs.isEmpty)
        item.menu?.addItem(.separator())
        add("Bluetooth", enabled: false)
        for device in bluetooth.devices {
            let row = add(device.name)
            row.view = MonitorRow(title: device.name,
                                  subtitle: (device.connected ? "Connected" : "Disconnected") + (bluetooth.autoAddresses.contains(device.address) ? " · Auto-connect" : ""),
                                  symbol: "antenna.radiowaves.left.and.right", isOn: device.connected,
                                  canToggle: bluetooth.available && !bluetooth.isBusy,
                                  identifier: device.address, target: self, action: #selector(toggleBluetooth(_:)))
        }
        if bluetooth.devices.isEmpty { add(String(bluetooth.status.prefix(90)), enabled: false) }
        let auto = add("Auto-connect")
        auto.view = MonitorRow(title: "Auto-connect", subtitle: bluetooth.legacyServicePresent ? "Owned by existing Bluetooth service" : String(bluetooth.status.prefix(60)),
                               symbol: "arrow.triangle.2.circlepath", isOn: bluetooth.autoEnabled,
                               canToggle: bluetooth.available && !bluetooth.legacyServicePresent,
                               identifier: "auto", target: self, action: #selector(toggleAutoConnect(_:)))
        item.menu?.addItem(.separator())
        add("Desktop Spaces", enabled: false)
        let spaceRow = add("Fast Space switching")
        spaceRow.view = MonitorRow(title: "Fast Space switching", subtitle: spaces.hasPermission ? spaces.speed.title : "Requires Accessibility permission",
                                   symbol: "rectangle.3.group", isOn: spaces.isEnabled, canToggle: true,
                                   identifier: "spaces", target: self, action: #selector(toggleSpaces(_:)))
        item.menu?.addItem(.separator())
        add("Settings…", action: #selector(openSettings))
        let login = add("Launch at login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("Quit (restore monitors)", action: #selector(quit), enabled: !busy)
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Mac Utils"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func toggleBluetooth(_ sender: NSSwitch) {
        guard let address = sender.identifier?.rawValue else { return }
        item.menu?.cancelTracking()
        DispatchQueue.main.async { [self] in bluetooth.toggleConnection(address) }
    }

    @objc private func toggleAutoConnect(_ sender: NSSwitch) {
        bluetooth.autoEnabled = sender.state == .on
        refresh()
    }

    @objc private func toggleSpaces(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        item.menu?.cancelTracking()
        DispatchQueue.main.async { [self] in
            do { try spaces.setEnabled(enabled) } catch { showError(error) }
            refresh()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(bluetooth: bluetooth, spaces: spaces)
            settingsWindow?.onChange = { [weak self] in self?.refresh() }
        }
        settingsWindow?.present()
    }

    @objc private func toggleSwitch(_ sender: NSSwitch) {
        guard !busy, let uuid = sender.identifier?.rawValue else { return }
        // Close tracking before replacing menu views or changing the main screen.
        item.menu?.cancelTracking()
        DispatchQueue.main.async { [self] in toggleMonitor(uuid) }
    }

    private func toggleMonitor(_ uuid: String) {
        guard !busy else { return }
        if !controller.isEnabled(uuid) { enable(uuid); return }
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
                        if self.countdowns[uuid, default: 0] <= 0, !self.busy { self.enable(uuid) }
                        self.refresh()
                    }
                    restoreTimers[uuid] = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
                refresh()
            }
        } catch {
            busy = false
            showError(error)
        }
        refresh()
    }

    private func cancelCountdown(_ uuid: String) {
        restoreTimers.removeValue(forKey: uuid)?.invalidate()
        countdowns.removeValue(forKey: uuid)
    }

    @objc private func keepDisabled(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        cancelCountdown(uuid)
        refresh()
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
                } catch {
                    busy = false
                    refresh()
                    showError(error)
                    completion?(false)
                }
            }
        } catch {
            busy = false
            refresh()
            showError(error)
            completion?(false)
        }
        refresh()
    }

    @objc private func enableAll() { restoreAll() }

    private func restoreAll(completion: ((Bool) -> Void)? = nil) {
        let pending = controller.disabledUUIDs
        func next(_ index: Int, success: Bool) {
            guard index < pending.count else { completion?(success); return }
            enable(pending[index]) { restored in next(index + 1, success: success && restored) }
        }
        next(0, success: true)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(error) }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

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
    }
}

func restoreFromCLI(_ controller: DisplayController) throws {
    for uuid in controller.disabledUUIDs {
        try controller.setEnabled(true, for: uuid)
        Thread.sleep(forTimeInterval: 1)
        try controller.finishRestore(uuid)
    }
}

func runChild(_ arguments: [String], capture: Bool = false) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = arguments
    if capture { process.standardOutput = output }
    try process.run()
    let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToggleError(message: "Child command failed: \(arguments.joined(separator: " "))") }
    return data
}

if CommandLine.arguments.contains("--bluetooth-status") {
    guard let path = CommandRunner.find("blueutil") else {
        fputs("Install blueutil with Homebrew.\n", stderr); exit(1)
    }
    do {
        let backend = BluetoothBackend(runner: CommandRunner(), blueutil: path, audioTool: CommandRunner.find("SwitchAudioSource"))
        for device in try backend.devices() { print("\(device.connected ? "●" : "○") \(device.name)") }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--spaces-status") {
    print("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "not granted")")
} else if CommandLine.arguments.contains("--enable-login") {
    do {
        try SMAppService.mainApp.register()
        print("Launch at login: \(SMAppService.mainApp.status == .enabled ? "enabled" : "requires system approval")")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--status") {
    print(DisplayController().status())
} else if CommandLine.arguments.contains("--snapshot") {
    do { print(String(decoding: try DisplayController().snapshot(), as: UTF8.self)) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--restore") {
    do {
        try restoreFromCLI(DisplayController())
        print("App-disabled monitors restored; original layout restored if the setup is unchanged.")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--test-cycle") || CommandLine.arguments.contains("--test-multi") {
    let controller = DisplayController()
    do {
        let selected: [Monitor]
        if CommandLine.arguments.contains("--test-multi") {
            selected = Array(controller.monitors.filter { $0.enabled && $0.id.map { CGDisplayIsBuiltin($0) == 0 } == true }.prefix(2))
            guard selected.count == 2 else { throw ToggleError(message: "Multi-monitor test needs two external monitors and a third usable screen") }
        } else {
            let arguments = CommandLine.arguments
            let name = arguments.firstIndex(of: "--name").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "Dell S2716DG"
            selected = controller.monitors.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.enabled }
            guard selected.count == 1 else { throw ToggleError(message: "Test needs exactly one enabled monitor matching \(name)") }
        }
        guard controller.disabledUUIDs.isEmpty else { throw ToggleError(message: "Restore app-disabled monitors before running tests") }
        let originalSnapshot = try controller.snapshot()
        for monitor in selected {
            try controller.setEnabled(false, for: monitor.uuid)
            Thread.sleep(forTimeInterval: 1)
            guard !controller.isEnabled(monitor.uuid) else { throw ToggleError(message: "Disable verification failed for \(monitor.name)") }
            print("Disable verified: \(monitor.name)")
        }
        Thread.sleep(forTimeInterval: 2)
        _ = try runChild(["--restore"])
        // Verify on an independent WindowServer connection, not cached CLI topology.
        let data = try runChild(["--snapshot"], capture: true)
        let verified = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard verified == String(decoding: originalSnapshot, as: UTF8.self) else {
            throw ToggleError(message: "Original layout/main-display verification failed")
        }
        print("Enable, fresh-process recovery, original layout and main display verified.")
    } catch {
        _ = try? runChild(["--restore"])
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
}
