import AppKit
import ServiceManagement

func restoreFromCLI(_ controller: DisplayController) throws {
    try controller.restorePendingArrangement()
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

if let index = CommandLine.arguments.firstIndex(of: "--watchdog") {
    guard index + 1 < CommandLine.arguments.count else { exit(2) }
    exit(SafetyWatchdog.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)))
} else if CommandLine.arguments.contains("--bluetooth-status") {
    guard let path = CommandRunner.find("blueutil") else {
        fputs("Install blueutil with Homebrew.\n", stderr); exit(1)
    }
    do {
        let backend = BluetoothBackend(runner: CommandRunner(), blueutil: path, audioTool: CommandRunner.find("SwitchAudioSource"))
        for device in try backend.devices() { print("\(device.connected ? "●" : "○") \(device.name)") }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--module-status") {
    guard let data = UserDefaults.standard.data(forKey: "modules.runtimeStatus") else {
        fputs("The GUI has not published module status yet.\n", stderr); exit(1)
    }
    print(String(decoding: data, as: UTF8.self))
} else if CommandLine.arguments.contains("--bluetooth-app-status") {
    guard let data = UserDefaults.standard.data(forKey: "bluetooth.lastSnapshot") else {
        fputs("The GUI has not published a Bluetooth snapshot yet.\n", stderr); exit(1)
    }
    print(String(decoding: data, as: UTF8.self))
} else if let index = CommandLine.arguments.firstIndex(of: "--test-bluetooth-connect"), index + 1 < CommandLine.arguments.count {
    let domain = "mac-utils.bluetooth-test.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    preferences.set(false, forKey: "bluetooth.autoEnabled")
    preferences.set([], forKey: "bluetooth.autoAddresses")
    var originalOutput: String?
    let runner = CommandRunner()
    let audio = CommandRunner.find("SwitchAudioSource")
    do {
        defer {
            preferences.removePersistentDomain(forName: domain)
            if let audio, let originalOutput,
               (try? runner.run(audio, ["-c", "-t", "output"]).trimmingCharacters(in: .whitespacesAndNewlines)) != originalOutput {
                _ = try? runner.run(audio, ["-t", "output", "-s", originalOutput])
            }
        }
        guard let blue = CommandRunner.find("blueutil") else { throw ToggleError(message: "blueutil missing") }
        let backend = BluetoothBackend(runner: runner, blueutil: blue, audioTool: audio)
        let name = CommandLine.arguments[index + 1]
        guard !["keyboard", "mouse", "trackpad"].contains(where: { name.localizedCaseInsensitiveContains($0) }) else {
            throw ToggleError(message: "Hardware tests refuse to disconnect input devices.")
        }
        let matches = try backend.devices().filter { $0.name == name }
        guard matches.count == 1 else { throw ToggleError(message: "Choose exactly one paired device name") }
        let target = matches[0]
        if let audio { originalOutput = try runner.run(audio, ["-c", "-t", "output"]).trimmingCharacters(in: .whitespacesAndNewlines) }
        if target.connected && CommandLine.arguments.contains("--cycle") {
            guard let audio, try runner.run(audio, ["-a", "-t", "output"]).split(separator: "\n").map(String.init).contains(target.name) else {
                throw ToggleError(message: "Disconnect/reconnect tests are restricted to currently recognized AUDIO devices.")
            }
            _ = try backend.setConnected(false, address: target.address)
            print("Hardware disconnect verified: \(name)")
        }
        let module = BluetoothModule(defaults: preferences, backend: backend, importLegacyConfiguration: false)
        func awaitIdle() throws {
            let deadline = Date().addingTimeInterval(50)
            while module.isBusy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard !module.isBusy else { throw ToggleError(message: "Module did not become idle") }
        }
        module.poll()
        try awaitIdle()
        // Exercise the exact dashboard action while real discovery is in flight.
        module.poll()
        if module.devices.first(where: { $0.address == target.address })?.connected == true {
            module.requestConnection(true, address: target.address)
        } else {
            module.toggleConnection(target.address)
        }
        try awaitIdle()
        guard module.devices.first(where: { $0.address == target.address })?.connected == true else {
            throw ToggleError(message: module.lastError ?? "Real module connection verification failed")
        }
        print("Actual BluetoothModule queued-connect verified: \(name)")
        print(String(decoding: module.diagnostics() ?? Data(), as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--spaces-status") {
    print("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "not granted")")
} else if CommandLine.arguments.contains("--enable-login") {
    do {
        try SMAppService.mainApp.register()
        print("Launch at login: \(SMAppService.mainApp.status == .enabled ? "enabled" : "requires system approval")")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--disable-login") {
    do {
        try SMAppService.mainApp.unregister()
        print("Launch at login disabled.")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--status") {
    print(DisplayController().status())
} else if CommandLine.arguments.contains("--snapshot") {
    do { print(String(decoding: try DisplayController().snapshot(), as: UTF8.self)) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--preview-layout-without"), index + 1 < CommandLine.arguments.count {
    do { print(String(decoding: try DisplayController().previewDisabling(name: CommandLine.arguments[index + 1]), as: UTF8.self)) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--set-display"), index + 2 < CommandLine.arguments.count {
    do {
        let controller = DisplayController()
        let state = CommandLine.arguments[index + 2]
        guard state == "on" || state == "off" else { throw ToggleError(message: "Expected on or off") }
        let uuid = CommandLine.arguments[index + 1]
        controller.canDisableDisplays = true
        controller.smartArrangementEnabled = !CommandLine.arguments.contains("--basic-layout")
        try controller.setEnabled(state == "on", for: uuid)
        if state == "on" { Thread.sleep(forTimeInterval: 1); try controller.finishRestore(uuid) }
        else if controller.isEnabled(uuid) { throw ToggleError(message: "Display remained active after disabling") }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--arrange-displays"), index + 1 < CommandLine.arguments.count {
    do {
        guard let data = Data(base64Encoded: CommandLine.arguments[index + 1]) else { throw ToggleError(message: "Invalid layout request") }
        try DisplayController().applyArrangement(JSONDecoder().decode(DisplayArrangementRequest.self, from: data))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
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
