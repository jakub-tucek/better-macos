import AppKit

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

/// Bluetooth reconnection and audio-race protection, independent of menu UI.
struct BluetoothBackend {
    let runner: CommandRunning
    let blueutil: String
    let audioTool: String?
    var waitForConnection: () -> Void = { Thread.sleep(forTimeInterval: 1) }

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
        _ = try runner.run(blueutil, [connected ? "--connect" : "--disconnect", address])
        waitForConnection()
        let updated = try devices()
        guard updated.first(where: { $0.address == address })?.connected == connected else {
            throw ToggleError(message: "Bluetooth device did not \(connected ? "connect" : "disconnect"). Check its power and range.")
        }
        return updated
    }

    func reconcile(_ configuration: BluetoothConfiguration) throws -> [BluetoothDevice] {
        var current = try devices()
        guard configuration.enabled else { return current }
        for address in configuration.autoAddresses.sorted() {
            guard let target = current.first(where: { $0.address == address }), !target.connected else { continue }
            // Failed observation aborts this cycle; never steal audio blindly.
            if configuration.protectOtherAudio,
               BluetoothPolicy.shouldPause(target: target, devices: current, audioOutputs: try outputs(), knownAudioAddresses: configuration.protectedAudioAddresses) { continue }
            current = try setConnected(true, address: address)
            guard configuration.switchAudioOutput, let audioTool,
                  let refreshed = current.first(where: { $0.address == address }) else { continue }
            let audioOutputs = try outputs()
            // Recheck AFTER connecting: headphones may have arrived meanwhile.
            guard audioOutputs?.contains(refreshed.name) == true,
                  !BluetoothPolicy.shouldPause(target: refreshed, devices: current, audioOutputs: audioOutputs, knownAudioAddresses: configuration.protectedAudioAddresses) else { continue }
            _ = try runner.run(audioTool, ["-t", "output", "-s", refreshed.name])
        }
        return current
    }
}

final class BluetoothModule {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "mac-utils.bluetooth", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private let backend: BluetoothBackend?
    private(set) var devices: [BluetoothDevice] = []
    private(set) var status = "Loading paired devices…"
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(defaults: UserDefaults = .standard, backend: BluetoothBackend? = nil, importLegacyConfiguration: Bool = true) {
        self.defaults = defaults
        self.backend = backend ?? CommandRunner.find("blueutil").map {
            BluetoothBackend(runner: CommandRunner(), blueutil: $0, audioTool: CommandRunner.find("SwitchAudioSource"))
        }
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
    var isBusy: Bool { busy }
    var autoEnabled: Bool {
        get { defaults.bool(forKey: "bluetooth.autoEnabled") }
        set { defaults.set(newValue, forKey: "bluetooth.autoEnabled"); onChange?(); poll() }
    }
    var autoAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "bluetooth.autoAddresses") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "bluetooth.autoAddresses"); onChange?() }
    }
    var protectOtherAudio: Bool {
        get { defaults.bool(forKey: "bluetooth.protectAudio") }
        set { defaults.set(newValue, forKey: "bluetooth.protectAudio") }
    }
    var protectedAudioAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "bluetooth.protectedAudioAddresses") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "bluetooth.protectedAudioAddresses") }
    }
    var switchAudioOutput: Bool {
        get { defaults.bool(forKey: "bluetooth.switchAudio") }
        set { defaults.set(newValue, forKey: "bluetooth.switchAudio") }
    }

    var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.user.bluetooth-autoconnect.plist")
    }
    var legacyServicePresent: Bool {
        FileManager.default.fileExists(atPath: legacyPlist.path) && !defaults.bool(forKey: "bluetooth.legacyTakenOver")
    }

    var reconnectSummary: String {
        if legacyServicePresent { return "Existing Bluetooth service owns reconnection" }
        return BluetoothPresentation.summary(enabled: autoEnabled, selected: autoAddresses, devices: devices)
    }

    func setAutoReconnect(_ enabled: Bool, for address: String) {
        if enabled { autoAddresses.insert(address) }
        else { autoAddresses.remove(address) }
    }

    func start() {
        poll()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        guard !busy else { return }
        guard let backend else {
            status = "Install blueutil to manage Bluetooth"
            onChange?()
            return
        }
        // Prevent duplicate reconnect loops until the old agent is taken over.
        let config = BluetoothConfiguration(enabled: autoEnabled && !legacyServicePresent,
                                            autoAddresses: autoAddresses, protectOtherAudio: protectOtherAudio,
                                            switchAudioOutput: switchAudioOutput, protectedAudioAddresses: protectedAudioAddresses)
        busy = true
        queue.async { [weak self] in
            let result = Result { try backend.reconcile(config) }
            DispatchQueue.main.async { self?.complete(result, reportError: false) }
        }
    }

    func toggleConnection(_ address: String) {
        guard !busy, let backend, let device = devices.first(where: { $0.address == address }) else { return }
        // Manual actions and persistent reconnect policy are separate. The UI
        // explicitly asks before turning off a selected device's reconnect rule.
        busy = true
        onChange?()
        queue.async { [weak self] in
            let result = Result { try backend.setConnected(!device.connected, address: address) }
            DispatchQueue.main.async { self?.complete(result, reportError: true) }
        }
    }

    private func complete(_ result: Result<[BluetoothDevice], Error>, reportError: Bool) {
        busy = false
        switch result {
        case .success(let updated):
            devices = updated
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
            if reportError { onError?(error) }
        }
        onChange?()
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
