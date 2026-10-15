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
    var audioOutputs: (() throws -> Set<String>)?
    var routeOutput: ((String) -> Void)?
    var pendingAudioAddresses = Set<String>()

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
        if let audioOutputs { return try audioOutputs() }
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
        // A connection may succeed before post-connect discovery fails. Retry
        // that routing intent on fresh observations without reconnecting it.
        for address in pendingAudioAddresses.sorted() where shouldContinue() {
            guard configuration.autoAddresses.contains(address),
                  let target = current.first(where: { $0.address == address }), target.connected else { continue }
            try requestOutput(target, devices: current, configuration: configuration)
        }
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
            guard let refreshed = current.first(where: { $0.address == address }) else { continue }
            try requestOutput(refreshed, devices: current, configuration: configuration)
        }
        if successes == 0, let firstFailure, shouldContinue() { throw firstFailure }
        return current
    }

    private func requestOutput(_ target: BluetoothDevice, devices: [BluetoothDevice], configuration: BluetoothConfiguration) throws {
        guard configuration.switchAudioOutput else { return }
        let available = try outputs()
        // Recheck AFTER connecting or before retrying: never bypass headphone protection.
        guard available?.contains(target.name) == true,
              !BluetoothPolicy.shouldPause(target: target, devices: devices, audioOutputs: available,
                                           knownAudioAddresses: configuration.protectedAudioAddresses) else { return }
        routeOutput?(target.name)
    }
}

final class BluetoothModule: NSObject, CBCentralManagerDelegate {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "mac-utils.bluetooth", qos: .utility)
    private var timer: Timer?
    private var stopped = false
    private var onStopped: (() -> Void)?
    private var busy = false
    private var manualBusy = false
    enum ManualOperation: Equatable { case connection(String, Bool); case powerOn }
    private var pendingManual: ManualOperation?
    private var manualAddress: String?
    private var cycleCancellation: BluetoothCycleCancellation?
    private var pendingAudioName: String?
    private var pendingAudioAddresses = Set<String>()
    private var lastObservation: Date?
    private var retryAfter: [String: Date] = [:]
    private var activity: String?
    private(set) var radioPoweredOn: Bool?
    private(set) var deviceStates: [String: String] = [:]
    private(set) var lastError: String?
    var suspendAutomaticReconnection = false {
        didSet { if suspendAutomaticReconnection { cycleCancellation?.cancel(); clearAudioIntent() } }
    }
    private(set) var audioPolicyGeneration = UUID()
    private let backend: BluetoothBackend?
    private let authorizationProvider: () -> CBManagerAuthorization
    private let legacyServiceTakeover: () throws -> Void
    private var permissionManager: CBCentralManager?
    private(set) var devices: [BluetoothDevice] = []
    private(set) var status = "Loading paired devices…"
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    // Delivered after onError for failures; only successful manual operations
    // resolve action errors. A healthy observation alone does not resolve intent.
    var onManualOperationCompleted: ((ManualOperation, Result<Void, Error>) -> Void)?
    var activityJournal: ActivityJournal?
    private var activityManual: ActivityOperationID?
    private var activityPendingManual: ActivityOperationID?
    private var activityAutomatic: [String: ActivityOperationID] = [:]
    // Only suppress repeated waiting/failure observations, never feature retries.
    // These identity caches stay inside the owner and are bounded independently.
    private var activityRetryNoted: Set<String> = []
    private var activityWaitingNoted: Set<String> = []

    private func cancelActivityConnections() {
        for operation in activityAutomatic.values { activityJournal?.finish(operation, result: .canceled) }
        activityAutomatic.removeAll()
    }
    var onAudioOutputRequested: ((String) -> Void)?

    init(defaults: UserDefaults = .standard, backend: BluetoothBackend? = nil, importLegacyConfiguration: Bool = true,
         authorizationProvider: @escaping () -> CBManagerAuthorization = { CBCentralManager.authorization },
         legacyServiceTakeover: @escaping () throws -> Void = BluetoothModule.disableLegacyService) {
        self.defaults = defaults
        self.authorizationProvider = authorizationProvider
        self.legacyServiceTakeover = legacyServiceTakeover
        self.backend = backend ?? CommandRunner.find("blueutil").map {
            BluetoothBackend(runner: CommandRunner(), blueutil: $0, audioTool: nil,
                             audioOutputs: { Set(try CoreAudioBackend().devices().filter { $0.directions.contains(.output) }.map(\.name)) })
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
    var configurationOutcome: FeatureSetupOutcome {
        if permissionRequired { return .pendingAccess("Bluetooth access required; grant access and retry in Sound & connections.") }
        if !available { return .pendingHardware("Bluetooth backend is unavailable.") }
        if let lastError { return .failed(lastError) }
        if radioPoweredOn == false { return .pendingHardware("Bluetooth radio is off; turn it on in Settings.") }
        if busy || lastObservation == nil { return .pendingHardware("Device discovery/connection is in progress; see Sound & connections for its result.") }
        if autoEnabled && legacyServicePresent { return .pendingHardware("The existing Bluetooth service owns reconnection; choose explicit takeover in Settings.") }
        if autoEnabled && autoAddresses.contains(where: { address in !devices.contains { $0.address == address && $0.connected } }) {
            return .pendingHardware(reconnectSummary)
        }
        return .applied(reconnectSummary)
    }
    func audioRequestIsCurrent(name: String) -> Bool {
        !stopped && autoEnabled && switchAudioOutput && !suspendAutomaticReconnection && !legacyServicePresent &&
            cycleCancellation?.isCanceled == false && devices.contains {
                $0.connected && $0.name == name && autoAddresses.contains($0.address)
            }
    }
    var audioProtection: AudioProtectionSnapshot {
        guard !stopped, !permissionRequired, !busy, lastError == nil, !legacyServicePresent,
              let lastObservation, Date().timeIntervalSince(lastObservation) < 10 else { return .unavailable }
        return AudioProtectionSnapshot(ready: true, protectedDeviceNames: Set(devices.filter {
            $0.connected && protectedAudioAddresses.contains($0.address)
        }.map(\.name)))
    }
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
        set {
            cycleCancellation?.cancel()
            if !newValue { clearAudioIntent() }
            defaults.set(newValue, forKey: "bluetooth.autoEnabled"); onChange?(); poll()
        }
    }
    var autoAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "bluetooth.autoAddresses") ?? []) }
        set {
            cycleCancellation?.cancel()
            if newValue != autoAddresses { audioPolicyGeneration = UUID() }
            pendingAudioAddresses.formIntersection(newValue)
            pendingAudioName = nil
            defaults.set(newValue.sorted(), forKey: "bluetooth.autoAddresses"); onChange?()
        }
    }
    var protectOtherAudio: Bool {
        get { defaults.bool(forKey: "bluetooth.protectAudio") }
        set { cycleCancellation?.cancel(); audioPolicyGeneration = UUID(); defaults.set(newValue, forKey: "bluetooth.protectAudio") }
    }
    var protectedAudioAddresses: Set<String> {
        get { Set(defaults.stringArray(forKey: "bluetooth.protectedAudioAddresses") ?? []) }
        set { cycleCancellation?.cancel(); audioPolicyGeneration = UUID(); defaults.set(newValue.sorted(), forKey: "bluetooth.protectedAudioAddresses") }
    }
    var switchAudioOutput: Bool {
        get { defaults.bool(forKey: "bluetooth.switchAudio") }
        set {
            cycleCancellation?.cancel()
            if !newValue { clearAudioIntent() }
            defaults.set(newValue, forKey: "bluetooth.switchAudio")
        }
    }

    private func clearAudioIntent() {
        // Survives replacement of the observation cycle: downstream retry intent
        // belongs to this policy lifetime, not whichever cycle is current later.
        audioPolicyGeneration = UUID()
        pendingAudioName = nil
        pendingAudioAddresses.removeAll()
    }

    var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.user.bluetooth-autoconnect.plist")
    }
    var legacyServicePresent: Bool {
        FileManager.default.fileExists(atPath: legacyPlist.path) && !defaults.bool(forKey: "bluetooth.legacyTakenOver")
    }

    var reconnectSummary: String {
        if permissionRequired { return "Bluetooth access required — allow Fix macOS in Privacy & Security → Bluetooth" }
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
        stopped = false
        timer?.invalidate()
        poll()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop(completion: (() -> Void)? = nil) {
        cancelActivityConnections()
        if let activityManual { activityJournal?.finish(activityManual, result: .canceled) }
        activityManual = nil
        if let activityPendingManual { activityJournal?.finish(activityPendingManual, result: .canceled) }
        activityPendingManual = nil
        activityRetryNoted.removeAll(); activityWaitingNoted.removeAll()
        stopped = true
        timer?.invalidate()
        timer = nil
        cycleCancellation?.cancel()
        clearAudioIntent()
        pendingManual = nil
        permissionManager = nil
        onStopped = completion
        if !busy { onStopped = nil; completion?() }
    }

    func poll() {
        guard !stopped, !busy else { return }
        activityRetryNoted.formIntersection(autoAddresses)
        activityWaitingNoted.formIntersection(autoAddresses)
        if !autoEnabled { activityRetryNoted.removeAll(); activityWaitingNoted.removeAll() }
        guard !permissionRequired else {
            radioPoweredOn = nil
            status = reconnectSummary
            devices = []
            onChange?()
            return
        }
        guard var backend else {
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
        if !config.enabled || !config.switchAudioOutput { pendingAudioAddresses.removeAll() }
        pendingAudioAddresses.formIntersection(config.autoAddresses)
        backend.pendingAudioAddresses = pendingAudioAddresses
        backend.routeOutput = { [weak self] name in
            DispatchQueue.main.async {
                guard !cancellation.isCanceled else { return }
                self?.pendingAudioName = name
            }
        }
        onChange?()
        queue.async { [weak self] in
            let result = Result {
                try backend.reconcile(config, progress: { progress in
                    DispatchQueue.main.async {
                        guard !cancellation.isCanceled else { return }
                        self?.applyProgress(progress)
                    }
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
        guard !stopped else { return }
        guard !permissionRequired else {
            activityJournal?.record(.bluetoothConnect(connected), trigger: .user, result: .blocked)
            onError?(ToggleError(message: reconnectSummary)); onChange?(); return
        }
        if let activityPendingManual { activityJournal?.finish(activityPendingManual, result: .canceled) }
        activityPendingManual = activityJournal?.begin(.bluetoothConnect(connected), trigger: .user, queued: true)
        pendingManual = .connection(address, connected)
        clearAudioIntent()
        cycleCancellation?.cancel() // Manual intent takes precedence over later auto targets.
        onChange?()
        startPendingManual()
    }

    func turnBluetoothOn() {
        guard !stopped else { return }
        guard !permissionRequired else {
            activityJournal?.record(.bluetoothPower, trigger: .user, result: .blocked)
            onError?(ToggleError(message: reconnectSummary)); onChange?(); return
        }
        if let activityPendingManual { activityJournal?.finish(activityPendingManual, result: .canceled) }
        activityPendingManual = activityJournal?.begin(.bluetoothPower, trigger: .user, queued: true)
        pendingManual = .powerOn
        clearAudioIntent()
        cycleCancellation?.cancel()
        onChange?()
        startPendingManual()
    }

    private func startPendingManual() {
        guard !stopped, !busy, let backend, let request = pendingManual else { return }
        pendingManual = nil
        cancelActivityConnections()
        activityManual = activityPendingManual
        activityPendingManual = nil
        if let activityManual { activityJournal?.start(activityManual) }
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
        case .powerOn:
            manualAddress = nil; activity = "Turning Bluetooth on…"
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
            DispatchQueue.main.async { self?.complete(result, reportError: true, manualOperation: request) }
        }
    }

    private func applyProgress(_ progress: BluetoothProgress) {
        switch progress {
        case .radio(let poweredOn): radioPoweredOn = poweredOn
        case .connecting(let device):
            activityWaitingNoted.remove(device.address)
            if !activityRetryNoted.contains(device.address), activityAutomatic.count < 300 {
                activityAutomatic[device.address] = activityJournal?.begin(.bluetoothConnect(true), trigger: .automatic)
            }
            activity = "Connecting to \(device.name)…"
            deviceStates[device.address] = "Connecting…"
        case .connected(let device):
            if let operation = activityAutomatic.removeValue(forKey: device.address) {
                activityJournal?.finish(operation, result: .completed)
            } else if activityRetryNoted.contains(device.address) {
                activityJournal?.record(.bluetoothConnect(true), trigger: .automatic, result: .completed)
            }
            activityRetryNoted.remove(device.address); activityWaitingNoted.remove(device.address)
            deviceStates.removeValue(forKey: device.address); retryAfter.removeValue(forKey: device.address)
            if autoEnabled && switchAudioOutput { pendingAudioAddresses.insert(device.address) }
        case .waiting(let device, let reason):
            if !activityWaitingNoted.contains(device.address), activityWaitingNoted.count < 300 {
                activityWaitingNoted.insert(device.address)
                activityJournal?.record(.bluetoothWaiting, trigger: .automatic, result: .completed)
            }
            deviceStates[device.address] = reason
        case .failed(let device, let reason):
            if let operation = activityAutomatic.removeValue(forKey: device.address) {
                activityJournal?.finish(operation, result: .retryScheduled)
            }
            if activityRetryNoted.count < 300 { activityRetryNoted.insert(device.address) }
            deviceStates[device.address] = "\(reason) · will retry after 30s"
            retryAfter[device.address] = Date().addingTimeInterval(30)
        }
        onChange?()
    }

    private func complete(_ result: Result<[BluetoothDevice], Error>, reportError: Bool, manualOperation: ManualOperation? = nil) {
        if finishStoppedOperation() { return }
        // An interrupted cycle cannot leave Started rows behind. Per-target
        // successes/failures above have already finished their own rows.
        cancelActivityConnections()
        if manualOperation != nil, let activityManual {
            switch result {
            case .success: activityJournal?.finish(activityManual, result: .completed)
            case .failure: activityJournal?.finish(activityManual, result: .failed)
            }
            self.activityManual = nil
        }
        busy = false
        manualBusy = false
        activity = nil
        switch result {
        case .success(let updated):
            lastObservation = Date()
            if devices.contains(where: { old in old.connected && !updated.contains { $0.address == old.address && $0.connected } }) {
                audioPolicyGeneration = UUID()
            }
            devices = updated
            pendingAudioAddresses = pendingAudioAddresses.filter { address in
                updated.contains { $0.address == address && $0.connected } && autoAddresses.contains(address)
            }
            lastError = nil
            if let manualAddress { deviceStates.removeValue(forKey: manualAddress); retryAfter.removeValue(forKey: manualAddress) }
            for device in updated where device.connected {
                deviceStates.removeValue(forKey: device.address); retryAfter.removeValue(forKey: device.address)
                activityRetryNoted.remove(device.address); activityWaitingNoted.remove(device.address)
            }
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
        if let manualOperation { onManualOperationCompleted?(manualOperation, result.map { _ in () }) }
        onChange?()
        if let name = pendingAudioName, cycleCancellation?.isCanceled == false, lastError == nil {
            pendingAudioName = nil
            pendingAudioAddresses = pendingAudioAddresses.filter { address in
                devices.first(where: { $0.address == address })?.name != name
            }
            onAudioOutputRequested?(name)
        } else { pendingAudioName = nil }
        startPendingManual()
    }

    private func finishStoppedOperation() -> Bool {
        guard stopped else { return false }
        busy = false
        manualBusy = false
        let completion = onStopped
        onStopped = nil
        completion?()
        return true
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
        guard !stopped, !busy else { return }
        busy = true
        let takeover = legacyServiceTakeover
        queue.async { [weak self] in
            let result = Result { try takeover() }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.finishStoppedOperation() { return }
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

    static func disableLegacyService() throws {
        let runner = CommandRunner()
        let target = "gui/\(getuid())/com.user.bluetooth-autoconnect"
        if (try? runner.run("/bin/launchctl", ["print", target])) != nil {
            _ = try runner.run("/bin/launchctl", ["bootout", target])
        }
        _ = try runner.run("/bin/launchctl", ["disable", target])
    }
}
