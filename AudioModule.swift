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
    private(set) var devices: [AudioDevice] = []
    private(set) var routes: [AudioDirection: String] = [:]
    private(set) var status = "Automatic routing is off"
    var onChange: (() -> Void)?
    var automaticAllowed = false {
        didSet { if automaticAllowed != oldValue { pending.removeAll(); observed = false } }
    }
    var suspendRouting = false
    // Fail closed while Bluetooth is connecting or its protection state is unknown.
    var bluetoothProtection: () -> AudioProtectionSnapshot = { .clear }

    init(backend: AudioRoutingBackend = CoreAudioBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
    }
    var automatic: Bool {
        get { defaults.bool(forKey: "audio.automatic") }
        set { defaults.set(newValue, forKey: "audio.automatic"); resume() }
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
    func start() {
        guard !running else { return }
        running = true; poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { running = false; timer?.invalidate(); timer = nil; onChange = nil }
    func resume() { overrides.removeAll(); observed = false; poll() }
    func select(_ uid: String, direction: AudioDirection) {
        guard running, !suspendRouting else { return }
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
                else if current[direction] != routes[direction] { overrides.insert(direction); pending.remove(direction) }
            }
            devices = updated; routes = current; observed = true
            pending.formUnion(changed)
            status = automatic && automaticAllowed ? "Watching audio devices" : "Automatic routing is off"
            if automatic && automaticAllowed && !suspendRouting {
                var failures: [String] = []
                for direction in AudioDirection.allCases where pending.contains(direction) && !overrides.contains(direction) {
                    do {
                        if try reconcile(direction) { pending.remove(direction) }
                    } catch { failures.append("\(direction.rawValue): \(error.localizedDescription)") }
                }
                if !failures.isEmpty { status = failures.joined(separator: "; ") }
            }
        } catch { status = error.localizedDescription; onChange?(); return false }
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
        guard poll() else { return }
        guard !overrides.contains(.output), !outputProtected else { return }
        let matches = devices.filter { $0.name == name && $0.directions.contains(.output) }
        guard matches.count == 1 else { return }
        do { try backend.select(matches[0].uid, direction: .output); routes[.output] = matches[0].uid }
        catch { status = error.localizedDescription }
        onChange?()
    }
}
