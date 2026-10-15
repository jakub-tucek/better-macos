import Foundation
import CoreAudio

enum AudioDirection: String, CaseIterable { case input, output }

struct AudioDevice: Equatable, Identifiable {
    let uid: String
    let name: String
    let directions: Set<AudioDirection>
    let bluetooth: Bool
    var id: String { uid }
}

protocol AudioRoutingBackend {
    func devices() throws -> [AudioDevice]
    func current(_ direction: AudioDirection) throws -> String?
    func select(_ uid: String, direction: AudioDirection) throws
}

/// Connection discovery supplies evidence; only AudioModule authorizes route writes.
struct AudioProtectionSnapshot {
    let ready: Bool
    let protectedDeviceNames: Set<String>
    static let clear = AudioProtectionSnapshot(ready: true, protectedDeviceNames: [])
    static let unavailable = AudioProtectionSnapshot(ready: false, protectedDeviceNames: [])
}

/// Device IDs are resolved afresh for every write; only stable UIDs are persisted.
struct CoreAudioBackend: AudioRoutingBackend {
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw ToggleError(message: "CoreAudio error \(status). The device may be unavailable.") }
    }
    private func ids() throws -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size))
        var result = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &result))
        return result
    }
    private func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value))
        guard let value else { throw ToggleError(message: "Missing CoreAudio device identity.") }
        return value.takeRetainedValue() as String
    }
    private func supports(_ id: AudioDeviceID, _ direction: AudioDirection) throws -> Bool {
        var property = address(kAudioDevicePropertyStreams, scope: direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size))
        return size > 0
    }
    func devices() throws -> [AudioDevice] {
        try ids().map { id in
            var property = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &transport))
            let directions = try AudioDirection.allCases.filter { try supports(id, $0) }
            return AudioDevice(uid: try string(id, kAudioDevicePropertyDeviceUID), name: try string(id, kAudioObjectPropertyName),
                               directions: Set(directions), bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }.filter { !$0.directions.isEmpty }.sorted { ($0.name, $0.uid) < ($1.name, $1.uid) }
    }
    private func defaultProperty(_ direction: AudioDirection) -> AudioObjectPropertyAddress {
        address(direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }
    func current(_ direction: AudioDirection) throws -> String? {
        var property = defaultProperty(direction)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id))
        return id == 0 ? nil : try string(id, kAudioDevicePropertyDeviceUID)
    }
    func select(_ uid: String, direction: AudioDirection) throws {
        guard let resolved = try ids().first(where: { try string($0, kAudioDevicePropertyDeviceUID) == uid && supports($0, direction) }) else {
            throw ToggleError(message: "Audio device is no longer available.")
        }
        var id = resolved
        var property = defaultProperty(direction)
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id))
        guard try current(direction) == uid else { throw ToggleError(message: "macOS did not select the requested audio device.") }
    }
}

/// Main-thread routing owner. Polling catches topology and external route changes,
/// including drivers that omit notifications, without retaining transient device IDs.
final class AudioModule {
    private let backend: AudioRoutingBackend
    private let defaults: UserDefaults
    private var timer: Timer?
    private var running = false
    private var observed = false
    private var overrides = Set<AudioDirection>()
    private var pending = Set<AudioDirection>()
    private var bluetoothRequest: (name: String, uid: String?, generation: UUID?)?
    private(set) var devices: [AudioDevice] = []
    private(set) var routes: [AudioDirection: String] = [:]
    private(set) var status = "Automatic routing is off"
    private var observationFailure: String?
    private var routingFailures: [String] = []
    var configurationOutcome: FeatureSetupOutcome {
        if let observationFailure { return .failed(observationFailure) }
        if !routingFailures.isEmpty { return .failed(routingFailures.joined(separator: "; ")) }
        guard observed else { return .pendingHardware("Audio discovery has not completed.") }
        if automatic && automaticAllowed {
            if suspendRouting { return .pendingHardware("Routing is suspended.") }
            for direction in AudioDirection.allCases where !overrides.contains(direction) {
                let requested = preferences(direction) + [fallback(direction)].filter { !$0.isEmpty }
                let available = Set(devices.filter { $0.directions.contains(direction) }.map(\.uid))
                if !requested.isEmpty && !requested.contains(where: available.contains) { return .pendingHardware("Preferred \(direction.rawValue) devices are unavailable; choices are saved.") }
            }
            if !pending.isEmpty { return .pendingHardware("Preferred routing is deferred by device/protection policy.") }
        }
        return .applied(status)
    }
    var onChange: (() -> Void)?
    var automaticAllowed = false {
        didSet {
            guard automaticAllowed != oldValue else { return }
            // Module visibility is not a device change or explicit Resume.
            // Re-enable schedules rules only for directions without manual intent.
            if automaticAllowed { pending.formUnion(AudioDirection.allCases) }
            else { pending.removeAll() }
        }
    }
    var suspendRouting = false
    // Fail closed while Bluetooth is connecting or its protection state is unknown.
    var bluetoothProtection: () -> AudioProtectionSnapshot = { .clear }
    var bluetoothRequestIsCurrent: (String) -> Bool = { _ in true }
    var bluetoothPolicyGeneration: () -> UUID? = { nil }

    init(backend: AudioRoutingBackend = CoreAudioBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
    }
    var automatic: Bool {
        get { defaults.bool(forKey: "audio.automatic") }
        set {
            defaults.set(newValue, forKey: "audio.automatic")
            bluetoothRequest = nil
            if newValue { resume() }
            else { pending.removeAll(); poll() }
        }
    }
    func preferences(_ direction: AudioDirection) -> [String] { defaults.stringArray(forKey: "audio.\(direction.rawValue).preferences") ?? [] }
    func fallback(_ direction: AudioDirection) -> String { defaults.string(forKey: "audio.\(direction.rawValue).fallback") ?? "" }
    func setPreferences(_ values: [String], direction: AudioDirection) {
        var seen = Set<String>()
        defaults.set(values.filter { seen.insert($0).inserted }, forKey: "audio.\(direction.rawValue).preferences")
        onChange?()
    }
    func setFallback(_ uid: String, direction: AudioDirection) {
        defaults.set(uid, forKey: "audio.\(direction.rawValue).fallback"); onChange?()
    }
    func isOverridden(_ direction: AudioDirection) -> Bool { overrides.contains(direction) }
    func configureForSetup(automatic desired: Bool, output: [String], input: [String], outputFallback: String, inputFallback: String) {
        guard automatic != desired || preferences(.output) != output || preferences(.input) != input ||
            fallback(.output) != outputFallback || fallback(.input) != inputFallback else { return }
        // The off transition cannot write a route. Replace all inputs before the
        // single explicit resume, rather than exposing intermediate preferences.
        automatic = false
        setPreferences(output, direction: .output); setPreferences(input, direction: .input)
        setFallback(outputFallback, direction: .output); setFallback(inputFallback, direction: .input)
        automatic = desired
    }
    func start() {
        guard !running else { return }
        running = true; poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { running = false; timer?.invalidate(); timer = nil; bluetoothRequest = nil; onChange = nil }
    func resume() { overrides.removeAll(); bluetoothRequest = nil; observed = false; poll() }
    func select(_ uid: String, direction: AudioDirection) {
        guard running, !suspendRouting else { return }
        if direction == .output { bluetoothRequest = nil }
        do {
            try backend.select(uid, direction: direction)
            routes[direction] = uid; overrides.insert(direction); pending.remove(direction)
            status = "Manual \(direction.rawValue) override"
        } catch { status = error.localizedDescription }
        onChange?()
    }
    @discardableResult func poll() -> Bool {
        guard running else { return false }
        do {
            let updated = try backend.devices()
            var current: [AudioDirection: String] = [:]
            for direction in AudioDirection.allCases { current[direction] = try backend.current(direction) }
            var changed = Set<AudioDirection>()
            for direction in AudioDirection.allCases {
                let old = Set(devices.filter { $0.directions.contains(direction) }.map(\.uid))
                let new = Set(updated.filter { $0.directions.contains(direction) }.map(\.uid))
                if !observed || old != new { changed.insert(direction); overrides.remove(direction) }
                else if current[direction] != routes[direction] {
                    overrides.insert(direction); pending.remove(direction)
                    if direction == .output { bluetoothRequest = nil }
                }
            }
            devices = updated; routes = current; observed = true
            observationFailure = nil; routingFailures = []
            pending.formUnion(changed)
            status = automatic && automaticAllowed ? "Watching audio devices" : "Automatic routing is off"
            if automatic && automaticAllowed && !suspendRouting {
                var failures: [String] = []
                for direction in AudioDirection.allCases where pending.contains(direction) && !overrides.contains(direction) {
                    do {
                        if try reconcile(direction) { pending.remove(direction) }
                    } catch { failures.append("\(direction.rawValue): \(error.localizedDescription)") }
                }
                routingFailures = failures
                if !failures.isEmpty { status = failures.joined(separator: "; ") }
            }
            try reconcileBluetoothRequest()
        } catch { observationFailure = error.localizedDescription; status = error.localizedDescription; onChange?(); return false }
        onChange?()
        return true
    }
    private func reconcile(_ direction: AudioDirection) throws -> Bool {
        let available = Set(devices.filter { $0.directions.contains(direction) }.map(\.uid))
        guard let target = (preferences(direction) + [fallback(direction)]).first(where: { available.contains($0) }), target != routes[direction] else { return true }
        if direction == .output && outputProtected { status = "Keeping protected Bluetooth audio"; return false }
        try backend.select(target, direction: direction); routes[direction] = target
        return true
    }
    private var outputProtected: Bool {
        let protection = bluetoothProtection()
        return !protection.ready || !protection.protectedDeviceNames.isEmpty ||
            devices.contains { $0.uid == routes[.output] && $0.bluetooth }
    }
    /// Bluetooth's name-only legacy setting is accepted only when unambiguous.
    /// Audio rules, manual intent and connected headphones always win.
    func bluetoothConnected(name: String) {
        guard running, !suspendRouting, !(automatic && automaticAllowed) else { return }
        bluetoothRequest = (name, nil, bluetoothPolicyGeneration())
        poll()
    }
    private func reconcileBluetoothRequest() throws {
        guard let request = bluetoothRequest else { return }
        guard request.generation == bluetoothPolicyGeneration(), !(automatic && automaticAllowed),
              !overrides.contains(.output), bluetoothRequestIsCurrent(request.name) else {
            bluetoothRequest = nil; return
        }
        guard !suspendRouting, !outputProtected else { return }
        let matches = devices.filter { $0.name == request.name && $0.directions.contains(.output) }
        guard matches.count == 1, request.uid == nil || request.uid == matches[0].uid else {
            bluetoothRequest = nil; return
        }
        let uid = matches[0].uid
        bluetoothRequest = (request.name, uid, request.generation)
        if routes[.output] != uid {
            try backend.select(uid, direction: .output)
            routes[.output] = uid
        }
        bluetoothRequest = nil
    }
}
