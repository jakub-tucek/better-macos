import AppKit
import CoreBluetooth

struct BluetoothDevice: Decodable, Equatable {
    let address: String
    let name: String
    let connected: Bool
}

struct BluetoothConfiguration {
    var enabled: Bool
    var autoAddresses: Set<String>
    var protectOtherAudio: Bool
    var switchAudioOutput: Bool
    var protectedAudioAddresses: Set<String> = []
}

enum BluetoothPresentation {
    static func summary(enabled: Bool, selected: Set<String>, devices: [BluetoothDevice]) -> String {
        guard !selected.isEmpty else { return "Choose devices to reconnect below" }
        let names = devices.filter { selected.contains($0.address) }.map(\.name)
        guard !names.isEmpty else { return "Selected devices are unavailable" }
        let selection = names.joined(separator: ", ")
        return enabled ? "Monitoring: \(selection)" : "Paused: \(selection)"
    }
}

enum BluetoothPolicy {
    static func shouldPause(target: BluetoothDevice, devices: [BluetoothDevice], audioOutputs: Set<String>?, knownAudioAddresses: Set<String> = []) -> Bool {
        devices.contains { device in
            device.connected && device.address != target.address && (knownAudioAddresses.contains(device.address) || (audioOutputs?.contains(device.name) ?? true))
        }
    }
}

enum BluetoothProgress {
    case radio(Bool)
    case connecting(BluetoothDevice)
    case connected(BluetoothDevice)
    case waiting(BluetoothDevice, String)
    case failed(BluetoothDevice, String)
}

private final class BluetoothCycleCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
}

/// Bluetooth reconnection and audio-race protection, independent of menu UI.
struct BluetoothBackend {
    let runner: CommandRunning
    let blueutil: String
    let audioTool: String?
    var waitForConnection: () -> Void = { Thread.sleep(forTimeInterval: 1) }

    func isPoweredOn() throws -> Bool {
        let value = try runner.run(blueutil, ["--power"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == "0" || value == "1" else { throw ToggleError(message: "Cannot read Bluetooth radio state.") }
        return value == "1"
    }

    func turnPowerOn() throws {
        _ = try runner.run(blueutil, ["--power", "1"])
        guard try isPoweredOn() else { throw ToggleError(message: "Bluetooth did not turn on. Check System Settings → Bluetooth.") }
    }

    func devices() throws -> [BluetoothDevice] {
        let json = try runner.run(blueutil, ["--paired", "--format", "json"])
        return try JSONDecoder().decode([BluetoothDevice].self, from: Data(json.utf8))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func outputs() throws -> Set<String>? {
        guard let audioTool else { return nil }
        return Set(try runner.run(audioTool, ["-a", "-t", "output"]).split(separator: "\n").map(String.init))
    }

    func setConnected(_ connected: Bool, address: String) throws -> [BluetoothDevice] {
        guard try isPoweredOn() else { throw ToggleError(message: "Bluetooth is off. Turn it on before connecting a device.") }
        _ = try runner.run(blueutil, [connected ? "--connect" : "--disconnect", address])
        waitForConnection()
        let updated = try devices()
        guard updated.first(where: { $0.address == address })?.connected == connected else {
            throw ToggleError(message: "Bluetooth device did not \(connected ? "connect" : "disconnect"). Check its power and range.")
        }
        return updated
    }

    func reconcile(_ configuration: BluetoothConfiguration, progress: ((BluetoothProgress) -> Void)? = nil,
                   shouldContinue: () -> Bool = { true }) throws -> [BluetoothDevice] {
        let poweredOn = try isPoweredOn()
        progress?(.radio(poweredOn))
        var current = try devices()
        guard configuration.enabled, poweredOn else { return current }
        var firstFailure: Error?
        var successes = 0
        for address in configuration.autoAddresses.sorted() {
            guard shouldContinue() else { break }
            guard let target = current.first(where: { $0.address == address }), !target.connected else { continue }
            // Failed observation aborts this cycle; never steal audio blindly.
            if configuration.protectOtherAudio {
                let availableOutputs = try outputs()
                if BluetoothPolicy.shouldPause(target: target, devices: current, audioOutputs: availableOutputs, knownAudioAddresses: configuration.protectedAudioAddresses) {
                    let names = current.filter {
                        $0.connected && $0.address != target.address && (configuration.protectedAudioAddresses.contains($0.address) || (availableOutputs?.contains($0.name) ?? true))
                    }.map(\.name)
                    progress?(.waiting(target, "Waiting for \(names.joined(separator: ", ")) to disconnect"))
                    continue
                }
            }
            progress?(.connecting(target))
            do { current = try setConnected(true, address: address) }
            catch {
                firstFailure = firstFailure ?? ToggleError(message: "\(target.name): \(error.localizedDescription)")
                progress?(.failed(target, error.localizedDescription))
                continue // An unavailable device must not starve later targets.
            }
            successes += 1
            progress?(.connected(target))
            guard shouldContinue() else { break }
            guard configuration.switchAudioOutput, let audioTool,
                  let refreshed = current.first(where: { $0.address == address }) else { continue }
            let audioOutputs = try outputs()
            // Recheck AFTER connecting: headphones may have arrived meanwhile.
            guard audioOutputs?.contains(refreshed.name) == true,
                  !BluetoothPolicy.shouldPause(target: refreshed, devices: current, audioOutputs: audioOutputs, knownAudioAddresses: configuration.protectedAudioAddresses) else { continue }
            _ = try runner.run(audioTool, ["-t", "output", "-s", refreshed.name])
        }
        if successes == 0, let firstFailure, shouldContinue() { throw firstFailure }
        return current
    }
}

final class BluetoothModule: NSObject, CBCentralManagerDelegate {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "mac-utils.bluetooth", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var manualBusy = false
    private enum ManualRequest { case connection(String, Bool); case powerOn }
    private var pendingManual: ManualRequest?
    private var manualAddress: String?
    private var cycleCancellation: BluetoothCycleCancellation?
    private var retryAfter: [String: Date] = [:]
    private var activity: String?
    private(set) var radioPoweredOn: Bool?
    private(set) var deviceStates: [String: String] = [:]
    private(set) var lastError: String?
    var suspendAutomaticReconnection = false
    private let backend: BluetoothBackend?
    private let authorizationProvider: () -> CBManagerAuthorization
    private var permissionManager: CBCentralManager?
    private(set) var devices: [BluetoothDevice] = []
    private(set) var status = "Loading paired devices…"
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(defaults: UserDefaults = .standard, backend: BluetoothBackend? = nil, importLegacyConfiguration: Bool = true,
         authorizationProvider: @escaping () -> CBManagerAuthorization = { CBCentralManager.authorization }) {
        self.defaults = defaults
        self.authorizationProvider = authorizationProvider
        self.backend = backend ?? CommandRunner.find("blueutil").map {
            BluetoothBackend(runner: CommandRunner(), blueutil: $0, audioTool: CommandRunner.find("SwitchAudioSource"))
        }
        super.init()
        defaults.register(defaults: ["bluetooth.protectAudio": true, "bluetooth.switchAudio": true])
        if importLegacyConfiguration && defaults.object(forKey: "bluetooth.autoAddresses") == nil {
            // Import only the old speaker NAME into local settings, never into
            // source control. Resolve its address after the first device query.
            let script = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/others/bluetooth-connect/bluetooth-connect/smart-connect.sh")
            if let text = try? String(contentsOf: script, encoding: .utf8) {
                for (variable, key) in [("SPEAKERS_NAME", "bluetooth.legacySpeakerName"), ("HEADPHONES_NAME", "bluetooth.legacyHeadphoneName")] {
                    let prefix = variable + "=\""
                    if let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) {
                        defaults.set(String(line).dropFirst(prefix.count).dropLast().description, forKey: key)
                    }
                }
            }
        }
    }

    var available: Bool { backend != nil }
    var authorization: CBManagerAuthorization { authorizationProvider() }
    var permissionRequired: Bool { authorization != .allowedAlways }

    func requestBluetoothAccess() {
        if authorization == .notDetermined {
            permissionManager = CBCentralManager(delegate: self, queue: .main,
                                                  options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if permissionRequired {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") { NSWorkspace.shared.open(url) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onChange?()
        if !permissionRequired { poll() }
    }
    var isBusy: Bool { busy }
    var isManualBusy: Bool { manualBusy || pendingManual != nil }
    var autoEnabled: Bool {
        get { defaults.bool(forKey: "bluetooth.autoEnabled") }
        set { cycleCancellation?.cancel(); defaults.set(newValue, forKey: "bluetooth.autoEnabled"); onChange?(); poll() }
    }
    var autoAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "bluetooth.autoAddresses") ?? []) }
        set { cycleCancellation?.cancel(); defaults.set(newValue.sorted(), forKey: "bluetooth.autoAddresses"); onChange?() }
    }
    var protectOtherAudio: Bool {
        get { defaults.bool(forKey: "bluetooth.protectAudio") }
        set { cycleCancellation?.cancel(); defaults.set(newValue, forKey: "bluetooth.protectAudio") }
    }
    var protectedAudioAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "bluetooth.protectedAudioAddresses") ?? []) }
        set { cycleCancellation?.cancel(); defaults.set(newValue.sorted(), forKey: "bluetooth.protectedAudioAddresses") }
    }
    var switchAudioOutput: Bool {
        get { defaults.bool(forKey: "bluetooth.switchAudio") }
        set { cycleCancellation?.cancel(); defaults.set(newValue, forKey: "bluetooth.switchAudio") }
    }

    var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.user.bluetooth-autoconnect.plist")
    }
    var legacyServicePresent: Bool {
        FileManager.default.fileExists(atPath: legacyPlist.path) && !defaults.bool(forKey: "bluetooth.legacyTakenOver")
    }

    var reconnectSummary: String {
        if permissionRequired { return "Bluetooth access required — allow Mac Utils in Privacy & Security → Bluetooth" }
        if radioPoweredOn == false { return "Bluetooth is off — turn the radio on first" }
        if pendingManual != nil { return "Manual request queued; waiting for the current attempt" }
        if busy, let activity { return activity }
        if let lastError { return lastError }
        if suspendAutomaticReconnection { return "Hardware-test session: automatic reconnection temporarily paused" }
        if legacyServicePresent { return "Existing Bluetooth service owns reconnection" }
        if autoEnabled, let waiting = autoAddresses.sorted().compactMap({ deviceStates[$0] }).first(where: { $0.hasPrefix("Waiting for") }) { return waiting }
        if autoEnabled, autoAddresses.contains(where: { retryAfter[$0, default: .distantPast] > Date() }) {
            return "A selected device is unavailable; retrying automatically after 30s"
        }
        return BluetoothPresentation.summary(enabled: autoEnabled, selected: autoAddresses, devices: devices)
    }

    func setAutoReconnect(_ enabled: Bool, for address: String) {
        retryAfter.removeValue(forKey: address)
        deviceStates.removeValue(forKey: address)
        if enabled { autoAddresses.insert(address) }
        else { autoAddresses.remove(address) }
    }

    func start() {
        poll()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil; cycleCancellation?.cancel(); pendingManual = nil }

    func poll() {
        guard !busy else { return }
        guard !permissionRequired else {
            radioPoweredOn = nil
            status = reconnectSummary
            devices = []
            onChange?()
            return
        }
        guard let backend else {
            status = "Install blueutil to manage Bluetooth"
            onChange?()
            return
        }
        // Prevent duplicate reconnect loops until the old agent is taken over.
        let config = BluetoothConfiguration(enabled: autoEnabled && !legacyServicePresent && !suspendAutomaticReconnection,
                                            autoAddresses: Set(autoAddresses.filter { retryAfter[$0, default: .distantPast] <= Date() }), protectOtherAudio: protectOtherAudio,
                                            switchAudioOutput: switchAudioOutput, protectedAudioAddresses: protectedAudioAddresses)
        busy = true
        activity = "Checking Bluetooth devices…"
        let cancellation = BluetoothCycleCancellation()
        cycleCancellation = cancellation
        onChange?()
        queue.async { [weak self] in
            let result = Result {
                try backend.reconcile(config, progress: { progress in
                    DispatchQueue.main.async { self?.applyProgress(progress) }
                }, shouldContinue: { !cancellation.isCanceled })
            }
            DispatchQueue.main.async { self?.complete(result, reportError: false) }
        }
    }

    func toggleConnection(_ address: String) {
        guard let device = devices.first(where: { $0.address == address }) else { return }
        requestConnection(!device.connected, address: address)
    }

    func requestConnection(_ connected: Bool, address: String) {
        guard !permissionRequired else { onError?(ToggleError(message: reconnectSummary)); onChange?(); return }
        pendingManual = .connection(address, connected)
        cycleCancellation?.cancel() // Manual intent takes precedence over later auto targets.
        onChange?()
        startPendingManual()
    }

    func turnBluetoothOn() {
        guard !permissionRequired else { onError?(ToggleError(message: reconnectSummary)); onChange?(); return }
        pendingManual = .powerOn
        cycleCancellation?.cancel()
        onChange?()
        startPendingManual()
    }

    private func startPendingManual() {
        guard !busy, let backend, let request = pendingManual else { return }
        pendingManual = nil
        // Manual actions and persistent reconnect policy are separate. The UI
        // explicitly asks before turning off a selected device's reconnect rule.
        busy = true
        manualBusy = true
        lastError = nil
        switch request {
        case .connection(let address, let connected):
            manualAddress = address
            let name = devices.first(where: { $0.address == address })?.name ?? "device"
            activity = "\(connected ? "Connecting to" : "Disconnecting") \(name)…"
            deviceStates[address] = connected ? "Connecting…" : "Disconnecting…"
        case .powerOn: manualAddress = nil; activity = "Turning Bluetooth on…"
        }
        onChange?()
        queue.async { [weak self] in
            let result = Result {
                switch request {
                case .connection(let address, let connected): return try backend.setConnected(connected, address: address)
                case .powerOn:
                    try backend.turnPowerOn()
                    DispatchQueue.main.async { self?.applyProgress(.radio(true)) }
                    return try backend.devices()
                }
            }
            DispatchQueue.main.async { self?.complete(result, reportError: true) }
        }
    }

    private func applyProgress(_ progress: BluetoothProgress) {
        switch progress {
        case .radio(let poweredOn): radioPoweredOn = poweredOn
        case .connecting(let device):
            activity = "Connecting to \(device.name)…"
            deviceStates[device.address] = "Connecting…"
        case .connected(let device): deviceStates.removeValue(forKey: device.address); retryAfter.removeValue(forKey: device.address)
        case .waiting(let device, let reason): deviceStates[device.address] = reason
        case .failed(let device, let reason):
            deviceStates[device.address] = "\(reason) · will retry after 30s"
            retryAfter[device.address] = Date().addingTimeInterval(30)
        }
        onChange?()
    }

    private func complete(_ result: Result<[BluetoothDevice], Error>, reportError: Bool) {
        busy = false
        manualBusy = false
        activity = nil
        switch result {
        case .success(let updated):
            devices = updated
            lastError = nil
            if let manualAddress { deviceStates.removeValue(forKey: manualAddress); retryAfter.removeValue(forKey: manualAddress) }
            for device in updated where device.connected { deviceStates.removeValue(forKey: device.address); retryAfter.removeValue(forKey: device.address) }
            if defaults.object(forKey: "bluetooth.autoAddresses") == nil,
               let name = defaults.string(forKey: "bluetooth.legacySpeakerName"),
               let device = updated.first(where: { $0.name == name }) {
                autoAddresses = [device.address]
            }
            if defaults.object(forKey: "bluetooth.protectedAudioAddresses") == nil,
               let name = defaults.string(forKey: "bluetooth.legacyHeadphoneName"),
               let device = updated.first(where: { $0.name == name }) {
                protectedAudioAddresses = [device.address]
            }
            status = reconnectSummary
        case .failure(let error):
            status = error.localizedDescription
            lastError = error.localizedDescription
            if let manualAddress { deviceStates[manualAddress] = error.localizedDescription }
            if reportError { onError?(error) }
        }
        manualAddress = nil
        onChange?()
        startPendingManual()
    }

    func diagnostics() -> Data? {
        let rows: [[String: Any]] = devices.map {
            ["name": $0.name, "connected": $0.connected, "autoReconnect": autoAddresses.contains($0.address),
             "state": deviceStates[$0.address] ?? ""]
        }
        return try? JSONSerialization.data(withJSONObject: [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "permissionRequired": permissionRequired, "authorization": authorization.rawValue,
            "radioOn": radioPoweredOn.map { $0 as Any } ?? NSNull(), "busy": busy, "manualBusy": isManualBusy,
            "summary": reconnectSummary, "lastError": lastError.map { $0 as Any } ?? NSNull(), "devices": rows
        ], options: [.sortedKeys, .prettyPrinted])
    }

    func takeOverLegacyService() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            let runner = CommandRunner()
            let target = "gui/\(getuid())/com.user.bluetooth-autoconnect"
            let result = Result {
                // Verify the agent exists before booting it out. Leave its plist
                // and scripts intact; disable autostart so two loops cannot race.
                if (try? runner.run("/bin/launchctl", ["print", target])) != nil {
                    _ = try runner.run("/bin/launchctl", ["bootout", target])
                }
                _ = try runner.run("/bin/launchctl", ["disable", target])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success:
                    self.defaults.set(true, forKey: "bluetooth.legacyTakenOver")
                    self.autoEnabled = true
                case .failure(let error): self.onError?(error)
                }
                self.onChange?()
            }
        }
    }
}
