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
    static func widgetEmptyMessage(savedCount: Int, matchedCount: Int) -> String? {
        guard matchedCount == 0 else { return nil }
        return savedCount == 0 ? "Choose targets in Sound & connections." :
            "Saved targets unavailable. Check Bluetooth status and access in Sound & connections."
    }

    static func summary(enabled: Bool, selected: Set<String>, devices: [BluetoothDevice]) -> String {
        guard !selected.isEmpty else { return "Choose devices to reconnect below" }
        let names = devices.filter { device in selected.contains { BluetoothIdentity.matches($0, device.address) } }.map(\.name)
        guard !names.isEmpty else { return "Selected devices are unavailable" }
        let selection = names.joined(separator: ", ")
        return enabled ? "Monitoring: \(selection)" : "Paused: \(selection)"
    }
}

enum BluetoothPolicy {
    static func shouldPause(target: BluetoothDevice, devices: [BluetoothDevice], audioOutputs: Set<String>?, knownAudioAddresses: Set<String> = []) -> Bool {
        devices.contains { device in
            device.connected && !BluetoothIdentity.matches(device.address, target.address) && (knownAudioAddresses.contains { BluetoothIdentity.matches($0, device.address) } || (audioOutputs?.contains(device.name) ?? true))
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

/// Distinguish discovery failure from connection/routing failure without
/// interpreting a subprocess exit code as an authorization decision.
private struct BluetoothObservationFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

// Read evidence only. A successful empty parse says nothing about the helper's
// authorization or which inventory implementation its environment selected.
enum BluetoothDiscoveryRead: Equatable {
    case notObserved, parentAccessRequired, backendUnavailable
    case parsed(Int), commandFailed(power: Bool), decodeFailed, invalidPowerState

    var fields: [String: String] {
        var fields = ["parsed_device_count": "unknown", "command_outcome": "not_attempted", "decode_outcome": "not_attempted", "read_stage": "none"]
        switch self {
        case .notObserved: fields["discovery_outcome"] = "not_observed"
        case .parentAccessRequired: fields["discovery_outcome"] = "parent_access_required"
        case .backendUnavailable: fields["discovery_outcome"] = "backend_unavailable"
        case .parsed(let count):
            fields.merge(["discovery_outcome": "success", "parsed_device_count": String(count), "command_outcome": "success", "decode_outcome": "success", "read_stage": "paired"]) { _, new in new }
        case .commandFailed(let power):
            fields.merge(["discovery_outcome": "command_failure", "command_outcome": "failure", "read_stage": power ? "power" : "paired"]) { _, new in new }
        case .decodeFailed:
            fields.merge(["discovery_outcome": "decode_failure", "command_outcome": "success", "decode_outcome": "failure", "read_stage": "paired"]) { _, new in new }
        case .invalidPowerState:
            fields.merge(["discovery_outcome": "invalid_power_state", "command_outcome": "success", "read_stage": "power"]) { _, new in new }
        }
        return fields
    }
}

private struct BluetoothControlObservationFailure: LocalizedError {
    let underlying: Error
    let observedDevices: [BluetoothDevice]?
    var errorDescription: String? { underlying.localizedDescription }
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
    var onDiscoveryRead: ((BluetoothDiscoveryRead) -> Void)?
    var observationService: BluetoothObservationService?
    var onObservation: ((BluetoothReadback) -> Void)?

    func isPoweredOn() throws -> Bool {
        let value: String
        do { value = try runner.run(blueutil, ["--power"]).trimmingCharacters(in: .whitespacesAndNewlines) }
        catch { onDiscoveryRead?(.commandFailed(power: true)); throw error }
        guard value == "0" || value == "1" else {
            onDiscoveryRead?(.invalidPowerState)
            throw ToggleError(message: "Cannot read Bluetooth radio state.")
        }
        return value == "1"
    }

    func turnPowerOn() throws {
        _ = try runner.run(blueutil, ["--power", "1"])
        guard try isPoweredOn() else { throw ToggleError(message: "Bluetooth did not turn on. Check System Settings → Bluetooth.") }
    }

    func devices() throws -> [BluetoothDevice] {
        let json: String
        do { json = try runner.run(blueutil, ["--paired", "--format", "json"]) }
        catch { onDiscoveryRead?(.commandFailed(power: false)); throw error }
        let devices: [BluetoothDevice]
        do { devices = try JSONDecoder().decode([BluetoothDevice].self, from: Data(json.utf8)) }
        catch { onDiscoveryRead?(.decodeFailed); throw error }
        onDiscoveryRead?(.parsed(devices.count))
        try BluetoothIdentity.validate(devices, allowOpaque: observationService == nil)
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolve(_ address: String, in devices: [BluetoothDevice]) throws -> BluetoothDevice? {
        try BluetoothIdentity.resolve(address, in: devices, allowOpaque: observationService == nil)
    }

    private func outputs() throws -> Set<String>? {
        if let audioOutputs { return try audioOutputs() }
        guard let audioTool else { return nil }
        return Set(try runner.run(audioTool, ["-a", "-t", "output"]).split(separator: "\n").map(String.init))
    }

    func setConnected(_ connected: Bool, address: String) throws -> [BluetoothDevice] {
        let poweredOn: Bool
        do { poweredOn = try isPoweredOn() }
        catch {
            publishPrimary(power: nil, devices: nil)
            throw BluetoothControlObservationFailure(underlying: error, observedDevices: nil)
        }
        guard poweredOn else {
            publishPrimary(power: false, devices: nil)
            throw BluetoothControlObservationFailure(underlying: ToggleError(message: "Bluetooth is off. Turn it on before connecting a device."), observedDevices: nil)
        }
        let target: BluetoothDevice
        do {
            let current = try devices()
            guard let resolved = try resolve(address, in: current) else { throw ToggleError(message: "Bluetooth target is unavailable in the current helper inventory.") }
            target = resolved
        } catch {
            publishPrimary(power: true, devices: nil)
            throw BluetoothControlObservationFailure(underlying: error, observedDevices: nil)
        }
        do { _ = try runner.run(blueutil, [connected ? "--connect" : "--disconnect", target.address]) }
        catch {
            // A failed command may still have changed state. Only a fresh helper
            // read can authorize continuing this cycle, never native inventory.
            let observed = try? devices()
            publishPrimary(power: true, devices: observed)
            throw BluetoothControlObservationFailure(underlying: error, observedDevices: observed)
        }
        waitForConnection()
        let updated: [BluetoothDevice]
        do { updated = try devices() }
        catch {
            publishPrimary(power: true, devices: nil)
            throw BluetoothControlObservationFailure(underlying: error, observedDevices: nil)
        }
        publishPrimary(power: true, devices: updated)
        guard try resolve(target.address, in: updated)?.connected == connected else {
            throw BluetoothControlObservationFailure(underlying: ToggleError(message: "Bluetooth device did not \(connected ? "connect" : "disconnect"). Check its power and range."), observedDevices: updated)
        }
        return updated
    }

    private func publishPrimary(power: Bool?, devices: [BluetoothDevice]?) {
        guard observationService != nil else { return }
        onObservation?(BluetoothReadback(helperPower: power, helperDevices: devices, native: nil, nativeIssue: nil, nativeStale: false))
    }

    func reconcile(_ configuration: BluetoothConfiguration, progress: ((BluetoothProgress) -> Void)? = nil,
                    shouldContinue: @escaping () -> Bool = { true }) throws -> [BluetoothDevice] {
        let poweredOn: Bool
        var observedPower: Bool?
        var current: [BluetoothDevice]
        do {
            poweredOn = try isPoweredOn()
            observedPower = poweredOn
            if observationService == nil { progress?(.radio(poweredOn)) }
            current = try devices()
        } catch {
            if let observationService {
                onObservation?(observationService.observe(power: observedPower, devices: nil, shouldContinue: shouldContinue))
            }
            throw BluetoothObservationFailure(underlying: error)
        }
        if let observationService {
            let observation = observationService.observe(power: poweredOn, devices: current, shouldContinue: shouldContinue)
            onObservation?(observation)
            guard !observation.controlsBlocked else {
                throw BluetoothObservationFailure(underlying: ToggleError(message: observation.summary ?? "Bluetooth controls unavailable."))
            }
            progress?(.radio(poweredOn))
        }
        guard configuration.enabled, poweredOn else { return current }
        // A connection may succeed before post-connect discovery fails. Retry
        // that routing intent on fresh observations without reconnecting it.
        for address in pendingAudioAddresses.sorted() where shouldContinue() {
            guard configuration.autoAddresses.contains(address),
                  let target = try resolve(address, in: current), target.connected else { continue }
            try requestOutput(target, devices: current, configuration: configuration)
        }
        var firstFailure: Error?
        var successes = 0
        for address in configuration.autoAddresses.sorted() {
            guard shouldContinue() else { break }
            guard let target = try resolve(address, in: current), !target.connected else { continue }
            // Failed observation aborts this cycle; never steal audio blindly.
            if configuration.protectOtherAudio {
                let availableOutputs = try outputs()
                if BluetoothPolicy.shouldPause(target: target, devices: current, audioOutputs: availableOutputs, knownAudioAddresses: configuration.protectedAudioAddresses) {
                    let names = current.filter { device in
                        device.connected && !BluetoothIdentity.matches(device.address, target.address) && (configuration.protectedAudioAddresses.contains(where: { BluetoothIdentity.matches($0, device.address) }) || (availableOutputs?.contains(device.name) ?? true))
                    }.map(\.name)
                    progress?(.waiting(target, "Waiting for \(names.joined(separator: ", ")) to disconnect"))
                    continue
                }
            }
            progress?(.connecting(target))
            do { current = try setConnected(true, address: target.address) }
            catch {
                if let failure = error as? BluetoothControlObservationFailure {
                    guard let observed = failure.observedDevices else { throw error }
                    current = observed
                }
                firstFailure = firstFailure ?? ToggleError(message: "\(target.name): \(error.localizedDescription)")
                progress?(.failed(target, error.localizedDescription))
                continue // An unavailable device must not starve later targets.
            }
            successes += 1
            progress?(.connected(target))
            guard shouldContinue() else { break }
            guard let refreshed = try resolve(address, in: current) else { continue }
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
    private let diagnosticsLogger: Diagnostics
    private var discoveryRead = BluetoothDiscoveryRead.notObserved
    private var pendingDiscoveryRead: BluetoothDiscoveryRead?
    // One bounded previous key, never a history of identities or observations.
    private var lastDiscoveryFields: [String: String]?
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
    private(set) var readback: BluetoothReadback?
    var controlsAvailable: Bool {
        if let readback { return !readback.controlsBlocked }
        // Production comparison must complete before non-UI callers can mutate.
        return backend?.observationService == nil
    }
    var displayedRadioPoweredOn: Bool? {
        if let readback { return readback.displayedPower }
        return radioPoweredOn
    }
    var displayedDevices: [BluetoothDevice] {
        guard let observed = readback?.displayedDevices else { return devices }
        // Retain saved spelling at the presentation boundary; never persist native IDs.
        return observed.map { device in
            let saved = autoAddresses.sorted().first { BluetoothIdentity.matches($0, device.address) }
            return BluetoothDevice(address: saved ?? device.address, name: device.name, connected: device.connected)
        }
    }
    var observationSource: String? { readback.map { $0.source == "system_profiler" ? "Sources: macOS System Information (read-only), Bluetooth helper" : "Source: Bluetooth helper" } }
    private(set) var deviceStates: [String: String] = [:]
    private(set) var lastError: String?
    private(set) var observationStale = false
    private var lastErrorIsObservation = false
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
    private var activityRetryNoted: [String: ActivityOperationID] = [:]
    private var activityWaitingNoted: [String: ActivityOperationID] = [:]

    private func cancelActivityConnections() {
        for operation in activityAutomatic.values { activityJournal?.finish(operation, result: .canceled) }
        activityAutomatic.removeAll()
    }
    var onAudioOutputRequested: ((String) -> Void)?

    init(defaults: UserDefaults = .standard, backend: BluetoothBackend? = nil, importLegacyConfiguration: Bool = true,
         authorizationProvider: @escaping () -> CBManagerAuthorization = { CBCentralManager.authorization },
          legacyServiceTakeover: @escaping () throws -> Void = BluetoothModule.disableLegacyService,
          diagnostics: Diagnostics = .shared) {
        self.defaults = defaults
        self.diagnosticsLogger = diagnostics
        self.authorizationProvider = authorizationProvider
        self.legacyServiceTakeover = legacyServiceTakeover
        self.backend = backend ?? CommandRunner.find("blueutil").map {
            BluetoothBackend(runner: CommandRunner(diagnostics: diagnostics), blueutil: $0, audioTool: nil,
                             audioOutputs: { Set(try CoreAudioBackend().devices().filter { $0.directions.contains(.output) }.map(\.name)) },
                              observationService: .live(diagnostics: diagnostics))
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
        if !controlsAvailable { return .pendingHardware(reconnectSummary) }
        if let lastError { return .failed(lastError) }
        if radioPoweredOn == false { return .pendingHardware("Bluetooth radio is off; turn it on in Settings.") }
        if busy || lastObservation == nil { return .pendingHardware("Device discovery/connection is in progress; see Sound & connections for its result.") }
        if autoEnabled && legacyServicePresent { return .pendingHardware("The existing Bluetooth service owns reconnection; choose explicit takeover in Settings.") }
        if autoEnabled && autoAddresses.contains(where: { address in !devices.contains { BluetoothIdentity.matches($0.address, address) && $0.connected } }) {
            return .pendingHardware(reconnectSummary)
        }
        return .applied(reconnectSummary)
    }
    func audioRequestIsCurrent(name: String) -> Bool {
        !stopped && controlsAvailable && autoEnabled && switchAudioOutput && !suspendAutomaticReconnection && !legacyServicePresent &&
            cycleCancellation?.isCanceled == false && devices.contains { device in
                device.connected && device.name == name && autoAddresses.contains(where: { BluetoothIdentity.matches($0, device.address) })
            }
    }
    var audioProtection: AudioProtectionSnapshot {
        guard !stopped, controlsAvailable, !permissionRequired, !busy, lastError == nil, !legacyServicePresent,
              let lastObservation, Date().timeIntervalSince(lastObservation) < 10 else { return .unavailable }
        return AudioProtectionSnapshot(ready: true, protectedDeviceNames: Set(devices.filter { device in
            device.connected && protectedAudioAddresses.contains(where: { BluetoothIdentity.matches($0, device.address) })
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
            publishDiscoveryDiagnostic()
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
        if pendingManual != nil { return "Manual request queued; waiting for the current attempt" }
        if busy, let activity { return activity }
        if let summary = readback?.summary { return summary }
        if let lastError {
            return lastErrorIsObservation ? observationFailureSummary(lastError) : lastError
        }
        if radioPoweredOn == false { return "Bluetooth is off — turn the radio on first" }
        if suspendAutomaticReconnection { return "Hardware-test session: automatic reconnection temporarily paused" }
        if legacyServicePresent { return "Existing Bluetooth service owns reconnection" }
        if autoEnabled, let waiting = autoAddresses.sorted().compactMap({ deviceStates[$0] }).first(where: { $0.hasPrefix("Waiting for") }) { return waiting }
        if autoEnabled, autoAddresses.contains(where: { retryAfter[$0, default: .distantPast] > Date() }) {
            return "A selected device is unavailable; retrying automatically after 30s"
        }
        return BluetoothPresentation.summary(enabled: autoEnabled, selected: autoAddresses, devices: devices)
    }

    private func observationFailureSummary(_ detail: String) -> String {
        "Could not read Bluetooth status. Device information may be out of date. \(detail)"
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
        activityRetryNoted = activityRetryNoted.filter { autoAddresses.contains($0.key) }
        activityWaitingNoted = activityWaitingNoted.filter { autoAddresses.contains($0.key) }
        if !autoEnabled { activityRetryNoted.removeAll(); activityWaitingNoted.removeAll() }
        guard !permissionRequired else {
            radioPoweredOn = nil
            status = reconnectSummary
            devices = []
            onChange?()
            discoveryRead = .parentAccessRequired
            publishDiscoveryDiagnostic()
            return
        }
        guard var backend else {
            status = "Install blueutil to manage Bluetooth"
            onChange?()
            discoveryRead = .backendUnavailable
            publishDiscoveryDiagnostic()
            return
        }
        // Prevent duplicate reconnect loops until the old agent is taken over.
        let config = BluetoothConfiguration(enabled: autoEnabled && !legacyServicePresent && !suspendAutomaticReconnection,
                                            autoAddresses: Set(autoAddresses.filter { retryAfter[$0, default: .distantPast] <= Date() }), protectOtherAudio: protectOtherAudio,
                                            switchAudioOutput: switchAudioOutput, protectedAudioAddresses: protectedAudioAddresses)
        busy = true
        pendingDiscoveryRead = nil
        backend = observingDiscovery(backend)
        activity = "Checking Bluetooth devices…"
        let cancellation = BluetoothCycleCancellation()
        cycleCancellation = cancellation
        if !config.enabled || !config.switchAudioOutput { pendingAudioAddresses.removeAll() }
        pendingAudioAddresses.formIntersection(config.autoAddresses)
        backend.pendingAudioAddresses = pendingAudioAddresses
        backend.onObservation = { [weak self] observation in
            DispatchQueue.main.async {
                guard !cancellation.isCanceled, let self, !self.stopped else { return }
                self.applyReadback(observation)
                self.onChange?()
            }
        }
        backend.routeOutput = { [weak self] name in
            DispatchQueue.main.async {
                guard !cancellation.isCanceled else { return }
                self?.pendingAudioName = name
            }
        }
        onChange?()
        let activityGeneration = activityJournal?.clearGeneration
        queue.async { [weak self] in
            let result = Result {
                try backend.reconcile(config, progress: { progress in
                    DispatchQueue.main.async {
                        guard !cancellation.isCanceled else { return }
                        self?.applyProgress(progress, activityGeneration: activityGeneration)
                    }
                }, shouldContinue: { !cancellation.isCanceled })
            }
            DispatchQueue.main.async { self?.complete(result, reportError: false) }
        }
    }

    func toggleConnection(_ address: String) {
        guard let device = try? BluetoothIdentity.resolve(address, in: devices, allowOpaque: backend?.observationService == nil) else { return }
        requestConnection(!device.connected, address: device.address)
    }

    func requestConnection(_ connected: Bool, address: String) {
        guard !stopped else { return }
        guard controlsAvailable else { onError?(ToggleError(message: reconnectSummary)); onChange?(); return }
        guard !permissionRequired else {
            activityJournal?.record(.bluetoothConnect(connected), trigger: .user, result: .blocked)
            onError?(ToggleError(message: reconnectSummary)); onChange?(); return
        }
        let device = try? BluetoothIdentity.resolve(address, in: devices, allowOpaque: backend?.observationService == nil)
        guard device != nil || backend?.observationService == nil else {
            onError?(ToggleError(message: "Bluetooth target is unavailable in the current helper inventory.")); onChange?(); return
        }
        if let activityPendingManual { activityJournal?.finish(activityPendingManual, result: .canceled) }
        activityPendingManual = activityJournal?.begin(.bluetoothConnect(connected), trigger: .user, queued: true)
        pendingManual = .connection(device?.address ?? address, connected)
        clearAudioIntent()
        cycleCancellation?.cancel() // Manual intent takes precedence over later auto targets.
        onChange?()
        startPendingManual()
    }

    func turnBluetoothOn() {
        guard !stopped else { return }
        guard controlsAvailable else { onError?(ToggleError(message: reconnectSummary)); onChange?(); return }
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
        guard !stopped, !busy, var backend, let request = pendingManual else { return }
        guard controlsAvailable else {
            pendingManual = nil
            if let activityPendingManual { activityJournal?.finish(activityPendingManual, result: .blocked) }
            activityPendingManual = nil
            onChange?()
            return
        }
        let observed = observingDiscovery(backend)
        pendingDiscoveryRead = nil
        pendingManual = nil
        backend.observationService?.invalidate()
        readback = nil
        let cancellation = BluetoothCycleCancellation()
        cycleCancellation = cancellation
        backend.onObservation = { [weak self] observation in
            DispatchQueue.main.async {
                guard !cancellation.isCanceled, let self, !self.stopped else { return }
                self.applyReadback(observation)
                self.onChange?()
            }
        }
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
            manualAddress = selectionAddress(address)
            let name = devices.first(where: { BluetoothIdentity.matches($0.address, address) })?.name ?? "device"
            activity = "\(connected ? "Connecting to" : "Disconnecting") \(name)…"
            deviceStates[selectionAddress(address)] = connected ? "Connecting…" : "Disconnecting…"
        case .powerOn:
            manualAddress = nil; activity = "Turning Bluetooth on…"
        }
        onChange?()
        queue.async { [weak self] in
            let result = Result {
                switch request {
                case .connection(let address, let connected): return try observed.setConnected(connected, address: address)
                case .powerOn:
                    try observed.turnPowerOn()
                    DispatchQueue.main.async { self?.applyProgress(.radio(true)) }
                    return try observed.devices()
                }
            }
            DispatchQueue.main.async { self?.complete(result, reportError: true, manualOperation: request) }
        }
    }

    private func applyProgress(_ progress: BluetoothProgress, activityGeneration: UUID? = nil) {
        let recordsActivity = activityGeneration == nil || activityJournal?.clearGeneration == activityGeneration
        switch progress {
        case .radio(let poweredOn): radioPoweredOn = poweredOn
        case .connecting(let device):
            let address = selectionAddress(device.address)
            activityWaitingNoted.removeValue(forKey: address)
            if let previous = activityRetryNoted[address], activityJournal?.contains(previous) != true {
                activityRetryNoted.removeValue(forKey: address)
            }
            if recordsActivity, activityRetryNoted[address] == nil, activityAutomatic.count < 300 {
                activityAutomatic[address] = activityJournal?.begin(.bluetoothConnect(true), trigger: .automatic)
            }
            activity = "Connecting to \(device.name)…"
            deviceStates[address] = "Connecting…"
        case .connected(let device):
            let address = selectionAddress(device.address)
            if let operation = activityAutomatic.removeValue(forKey: address) {
                activityJournal?.finish(operation, result: .completed)
            } else if let previous = activityRetryNoted[address], activityJournal?.contains(previous) == true {
                activityJournal?.record(.bluetoothConnect(true), trigger: .automatic, result: .completed)
            }
            activityRetryNoted.removeValue(forKey: address); activityWaitingNoted.removeValue(forKey: address)
            deviceStates.removeValue(forKey: address); retryAfter.removeValue(forKey: address)
            if autoEnabled && switchAudioOutput { pendingAudioAddresses.insert(address) }
        case .waiting(let device, let reason):
            let address = selectionAddress(device.address)
            if let previous = activityWaitingNoted[address], activityJournal?.contains(previous) != true {
                activityWaitingNoted.removeValue(forKey: address)
            }
            if recordsActivity, activityWaitingNoted[address] == nil, activityWaitingNoted.count < 300,
               let operation = activityJournal?.begin(.bluetoothWaiting, trigger: .automatic) {
                activityWaitingNoted[address] = operation
                activityJournal?.finish(operation, result: .completed)
            }
            deviceStates[address] = reason
        case .failed(let device, let reason):
            let address = selectionAddress(device.address)
            if let operation = activityAutomatic.removeValue(forKey: address) {
                activityJournal?.finish(operation, result: .retryScheduled)
                if activityRetryNoted.count < 300 { activityRetryNoted[address] = operation }
            }
            deviceStates[address] = "\(reason) · will retry after 30s"
            retryAfter[address] = Date().addingTimeInterval(30)
        }
        onChange?()
    }

    private func selectionAddress(_ helperAddress: String) -> String {
        autoAddresses.sorted().first { BluetoothIdentity.matches($0, helperAddress) } ?? helperAddress
    }

    private func complete(_ result: Result<[BluetoothDevice], Error>, reportError: Bool, manualOperation: ManualOperation? = nil) {
        if finishStoppedOperation() { return }
        if let pendingDiscoveryRead { discoveryRead = pendingDiscoveryRead }
        pendingDiscoveryRead = nil
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
            if backend?.observationService != nil, readback?.controlsBlocked != true,
               manualOperation != nil || readback?.native == nil {
                // Only the original control path verifies manual operations.
                readback = BluetoothReadback(helperPower: radioPoweredOn, helperDevices: updated,
                                             native: nil, nativeIssue: nil, nativeStale: false)
            }
            lastObservation = Date()
            observationStale = false
            if devices.contains(where: { old in old.connected && !updated.contains { BluetoothIdentity.matches($0.address, old.address) && $0.connected } }) {
                audioPolicyGeneration = UUID()
            }
            devices = updated
            pendingAudioAddresses = pendingAudioAddresses.filter { address in
                updated.contains { BluetoothIdentity.matches($0.address, address) && $0.connected } && autoAddresses.contains(address)
            }
            lastError = nil
            lastErrorIsObservation = false
            if let manualAddress { deviceStates.removeValue(forKey: manualAddress); retryAfter.removeValue(forKey: manualAddress) }
            for device in updated where device.connected {
                let address = selectionAddress(device.address)
                deviceStates.removeValue(forKey: address); retryAfter.removeValue(forKey: address)
                activityRetryNoted.removeValue(forKey: address); activityWaitingNoted.removeValue(forKey: address)
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
            lastError = error.localizedDescription
            lastErrorIsObservation = !reportError && error is BluetoothObservationFailure
            if lastErrorIsObservation { observationStale = true }
            status = lastErrorIsObservation ? observationFailureSummary(error.localizedDescription) : error.localizedDescription
            if let manualAddress { deviceStates[manualAddress] = error.localizedDescription }
            if reportError { onError?(error) }
        }
        manualAddress = nil
        if let manualOperation { onManualOperationCompleted?(manualOperation, result.map { _ in () }) }
        onChange?()
        publishDiscoveryDiagnostic()
        if let name = pendingAudioName, cycleCancellation?.isCanceled == false, lastError == nil {
            pendingAudioName = nil
            pendingAudioAddresses = pendingAudioAddresses.filter { address in
                devices.first(where: { BluetoothIdentity.matches($0.address, address) })?.name != name
            }
            onAudioOutputRequested?(name)
        } else { pendingAudioName = nil }
        startPendingManual()
    }

    private func applyReadback(_ observation: BluetoothReadback) {
        readback = observation
        if let power = observation.helperPower { radioPoweredOn = power }
        if observation.native == nil, !observation.controlsBlocked, let updated = observation.helperDevices {
            if devices.contains(where: { old in old.connected && !updated.contains { BluetoothIdentity.matches($0.address, old.address) && $0.connected } }) {
                audioPolicyGeneration = UUID()
            }
            devices = updated
        }
        if observation.controlsBlocked, observation.helperDevices == nil { observationStale = true }
    }

    private func finishStoppedOperation() -> Bool {
        guard stopped else { return false }
        busy = false
        manualBusy = false
        pendingDiscoveryRead = nil
        let completion = onStopped
        onStopped = nil
        completion?()
        return true
    }

    private func observingDiscovery(_ backend: BluetoothBackend) -> BluetoothBackend {
        var observed = backend
        let previous = backend.onDiscoveryRead
        observed.onDiscoveryRead = { [weak self] read in
            previous?(read)
            // Same serial-worker/main-queue ordering as progress and completion.
            // Do not publish intermediate reads against the old inventory.
            DispatchQueue.main.async { [weak self] in
                guard let self, !stopped else { return }
                pendingDiscoveryRead = read
            }
        }
        return observed
    }

    private func publishDiscoveryDiagnostic() {
        guard !stopped else { return }
        let parentAuthorization: String
        switch authorization {
        case .allowedAlways: parentAuthorization = "allowed"
        case .denied: parentAuthorization = "denied"
        case .restricted: parentAuthorization = "restricted"
        case .notDetermined: parentAuthorization = "not_determined"
        @unknown default: parentAuthorization = "unknown"
        }
        let selected = autoAddresses
        var fields = discoveryRead.fields
        fields.merge([
            "inventory_device_count": String(devices.count),
            "saved_target_count": String(selected.count),
            "matched_target_count": String(selected.filter { saved in devices.contains { BluetoothIdentity.matches(saved, $0.address) } }.count),
            "radio_state": radioPoweredOn.map { $0 ? "on" : "off" } ?? "unknown",
            "inventory_stale": String(observationStale),
            "parent_authorization": parentAuthorization,
            "helper_authorization": "unknown", "helper_discovery_source": "unknown"
        ]) { _, new in new }
        guard fields != lastDiscoveryFields else { return }
        lastDiscoveryFields = fields
        diagnosticsLogger.emit("bluetooth", "discovery_state_changed", fields: fields)
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
            "observationSource": readback?.source ?? "blueutil", "observationConflict": readback?.conflicting ?? false,
            "controlsAvailable": controlsAvailable,
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
