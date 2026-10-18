import Foundation

/// Comparison only. Never rewrite stored target IDs or use names as identity.
enum BluetoothIdentity {
    static func canonical(_ address: String) -> String? {
        if address.contains(":") || address.contains("-") {
            let separator: Character = address.contains(":") ? ":" : "-"
            let groups = address.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.count == 6, groups.allSatisfy({ $0.utf8.count == 2 }) else { return nil }
        }
        let value = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").lowercased()
        guard value.utf8.count == 12, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let left = canonical(lhs), let right = canonical(rhs) else { return false }
        return left == right
    }

    static func validate(_ devices: [BluetoothDevice], allowOpaque: Bool = false) throws {
        var seen = Set<String>()
        for device in devices {
            guard let identity = canonical(device.address) ?? (allowOpaque && !device.address.isEmpty ? "opaque:\(device.address)" : nil) else {
                throw BluetoothReadIssue.incompleteInventory
            }
            guard seen.insert(identity).inserted else { throw BluetoothReadIssue.duplicateIdentity }
        }
    }

    /// Resolve against helper inventory, never native display rows. The raw ID
    /// returned here is the only ID a control command may use.
    static func resolve(_ address: String, in devices: [BluetoothDevice], allowOpaque: Bool = false) throws -> BluetoothDevice? {
        try validate(devices, allowOpaque: allowOpaque)
        guard let identity = canonical(address) else {
            return allowOpaque ? devices.first { $0.address == address } : nil
        }
        return devices.first { canonical($0.address) == identity }
    }
}

enum BluetoothReadIssue: String, Error {
    case malformed, missingController, ambiguousController, unknownPower, incompleteInventory, duplicateIdentity
    case launch, timeout, canceled, outputLimit, exitFailure, unavailable, pipeOpen
}

enum BluetoothControllerObservation: Equatable {
    case on, off, unknown(BluetoothReadIssue)
    var poweredOn: Bool? {
        switch self { case .on: return true; case .off: return false; case .unknown: return nil }
    }
}

struct BluetoothNativeSnapshot {
    let controller: BluetoothControllerObservation
    let inventory: Result<[BluetoothDevice], BluetoothReadIssue>
    let observedAt: TimeInterval

    var complete: Bool {
        guard controller.poweredOn != nil, case .success = inventory else { return false }
        return true
    }
}

/// system_profiler's command interface is documented; its Bluetooth schema is not.
/// Missing/partial fields must not silently become off or an empty inventory.
enum BluetoothProfilerParser {
    static func parse(_ data: Data, at time: TimeInterval) throws -> BluetoothNativeSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["SPBluetoothDataType"] as? [[String: Any]] else { throw BluetoothReadIssue.malformed }
        guard !rows.isEmpty else { throw BluetoothReadIssue.missingController }
        guard rows.count == 1 else { throw BluetoothReadIssue.ambiguousController }
        let row = rows[0]
        guard !hasError(root), !hasError(row) else { throw BluetoothReadIssue.unavailable }
        guard let controller = row["controller_properties"] as? [String: Any], !controller.isEmpty else {
            throw BluetoothReadIssue.missingController
        }
        guard !hasError(controller), controller["controller_error"] == nil else { throw BluetoothReadIssue.unavailable }
        let power: BluetoothControllerObservation
        switch controller["controller_state"] as? String {
        case "attrib_on": power = .on
        case "attrib_off": power = .off
        default: power = .unknown(.unknownPower)
        }
        let inventory = Result<[BluetoothDevice], BluetoothReadIssue> { () throws(BluetoothReadIssue) -> [BluetoothDevice] in
            guard let connected = row["device_connected"] as? [[String: Any]],
                  let disconnected = row["device_not_connected"] as? [[String: Any]] else {
                throw BluetoothReadIssue.incompleteInventory
            }
            var devices = [BluetoothDevice](), seen = Set<String>()
            for (group, state) in [(connected, true), (disconnected, false)] {
                for entry in group {
                    guard entry.count == 1, let (name, raw) = entry.first, !name.isEmpty,
                          let info = raw as? [String: Any], let address = info["device_address"] as? String,
                          let identity = BluetoothIdentity.canonical(address) else { throw BluetoothReadIssue.incompleteInventory }
                    guard seen.insert(identity).inserted else { throw BluetoothReadIssue.duplicateIdentity }
                    devices.append(BluetoothDevice(address: address, name: name, connected: state))
                }
            }
            return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return BluetoothNativeSnapshot(controller: power, inventory: inventory, observedAt: time)
    }

    private static func hasError(_ object: [String: Any]) -> Bool {
        ["_error", "_errors", "error"].contains { object[$0] != nil }
    }
}

struct BluetoothReadback {
    let helperPower: Bool?
    let helperDevices: [BluetoothDevice]?
    let native: BluetoothNativeSnapshot?
    let nativeIssue: BluetoothReadIssue?
    let nativeStale: Bool

    var conflicting: Bool {
        guard let native, !nativeStale else { return false }
        if let helperPower, let power = native.controller.poweredOn, helperPower != power { return true }
        if let helperDevices, case .success(let devices) = native.inventory {
            func identities(_ list: [BluetoothDevice]) -> [String: Bool]? {
                var result = [String: Bool]()
                for device in list {
                    guard let id = BluetoothIdentity.canonical(device.address), result[id] == nil else { return nil }
                    result[id] = device.connected
                }
                return result
            }
            guard let primary = identities(helperDevices), let alternate = identities(devices) else { return true }
            return primary != alternate
        }
        return false
    }

    var controlsBlocked: Bool {
        if let helperDevices, (try? BluetoothIdentity.validate(helperDevices)) == nil { return true }
        return helperPower == nil || helperDevices == nil || conflicting || nativeStale || nativeIssue != nil || native?.complete == false
    }

    var displayedPower: Bool? { native.map { $0.controller.poweredOn } ?? helperPower }
    var displayedDevices: [BluetoothDevice]? {
        if let native, case .success(let devices) = native.inventory { return devices }
        return helperDevices
    }
    var source: String { native == nil ? "blueutil" : "system_profiler" }
    var summary: String? {
        if conflicting, native?.controller == .on, helperPower == false {
            return "macOS reports Bluetooth on; helper reports off. Device controls unavailable."
        }
        if conflicting { return "macOS and the Bluetooth helper disagree. Device controls unavailable." }
        if controlsBlocked {
            return nativeStale ? "Bluetooth information is out of date. Device controls unavailable." :
                "Bluetooth status could not be verified. Device controls unavailable."
        }
        return nil
    }
}

/// Worker-only read service. Cache/in-flight state is shared across backend value copies.
/// Concurrent callers coalesce without waiting for another caller or the main queue.
final class BluetoothObservationService: @unchecked Sendable {
    typealias Fetch = (@escaping () -> Bool) throws -> Data
    private let lock = NSLock()
    private var inFlight = false
    private var cached: BluetoothNativeSnapshot?
    private var lastAttempt: TimeInterval?
    private var lastIssue: BluetoothReadIssue?
    private let fetch: Fetch
    private let clock: () -> TimeInterval
    private let ttl: TimeInterval
    private let diagnostics: Diagnostics

    init(ttl: TimeInterval = 30, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         diagnostics: Diagnostics = .shared, fetch: @escaping Fetch) {
        self.ttl = ttl; self.clock = clock; self.fetch = fetch; self.diagnostics = diagnostics
    }

    /// Called only once the feature's observation cycle has drained, before an
    /// already-admitted explicit control operation. Old native evidence cannot
    /// describe the result of that operation.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight else { return }
        cached = nil; lastAttempt = nil; lastIssue = nil
    }

    /// Re-evaluate admission using the same monotonic clock and TTL as reads.
    /// The stored snapshot remains available for stale, display-only presentation.
    func refreshingFreshness(_ observation: BluetoothReadback) -> BluetoothReadback {
        guard observation.native != nil else { return observation }
        return readback(observation.helperPower, observation.helperDevices, observation.native, observation.nativeIssue, at: clock())
    }

    func observe(power: Bool?, devices: [BluetoothDevice]?, shouldContinue: @escaping () -> Bool) -> BluetoothReadback {
        guard power != true || devices?.isEmpty != false else {
            return BluetoothReadback(helperPower: power, helperDevices: devices, native: nil, nativeIssue: nil, nativeStale: false)
        }
        let now = clock()
        lock.lock()
        if inFlight || lastAttempt.map({ now - $0 < ttl }) == true {
            let snapshot = cached, issue = lastIssue, coalesced = inFlight
            lock.unlock()
            diagnostics.emit("bluetooth", "observation_cache", level: .trace,
                             fields: ["reason": coalesced ? "in_flight" : "backoff_or_ttl",
                                      "snapshot_age_seconds": snapshot.map { String(max(0, now - $0.observedAt)) } ?? "absent",
                                      "status": issue?.rawValue ?? (snapshot == nil ? "unavailable" : "complete")])
            return readback(power, devices, snapshot, issue, at: now)
        }
        inFlight = true
        lock.unlock()
        let started = diagnostics.start()
        let operation = UUID().uuidString
        diagnostics.emit("bluetooth", "observation_start", operation: operation, level: .debug)
        let result: Result<BluetoothNativeSnapshot, BluetoothReadIssue>
        do {
            guard shouldContinue() else { throw BluetoothReadIssue.canceled }
            let data = try fetch(shouldContinue)
            guard shouldContinue() else { throw BluetoothReadIssue.canceled }
            let snapshot = try BluetoothProfilerParser.parse(data, at: clock())
            guard shouldContinue() else { throw BluetoothReadIssue.canceled }
            result = .success(snapshot)
        } catch { result = .failure(error as? BluetoothReadIssue ?? .malformed) }
        lock.lock()
        inFlight = false
        switch result {
        case .success(let snapshot):
            // Partial reports can provide power evidence, but cannot replace a complete cached snapshot.
            if snapshot.complete || cached == nil { cached = snapshot }
            lastIssue = snapshot.complete ? nil : (snapshot.controller.poweredOn == nil ? .unknownPower : .incompleteInventory)
            lastAttempt = clock()
        case .failure(let issue):
            if issue != .canceled { lastAttempt = clock(); lastIssue = issue }
        }
        let snapshot = cached, issue = lastIssue
        lock.unlock()
        let observation = readback(power, devices, snapshot, issue, at: clock())
        let fetchResult: String
        switch result {
        case .success(let snapshot): fetchResult = snapshot.complete ? "complete" : "partial"
        case .failure(let failure): fetchResult = failure.rawValue
        }
        let canceled = fetchResult == BluetoothReadIssue.canceled.rawValue
        diagnostics.emit("bluetooth", "observation", outcome: canceled ? "canceled" : "observed", operation: operation, since: started,
                         level: canceled ? .debug : (issue != nil || observation.conflicting ? .warning : .info), fields: ["source": observation.source,
                         "conflict": String(observation.conflicting), "stale": String(observation.nativeStale),
                         "controller": observation.displayedPower.map { $0 ? "on" : "off" } ?? "unknown",
                          "fetch_result": fetchResult, "timed_out": String(fetchResult == BluetoothReadIssue.timeout.rawValue),
                         "status": issue?.rawValue ?? "complete", "device_count": String(observation.displayedDevices?.count ?? 0)])
        return observation
    }

    private func readback(_ power: Bool?, _ devices: [BluetoothDevice]?, _ snapshot: BluetoothNativeSnapshot?,
                          _ issue: BluetoothReadIssue?, at now: TimeInterval) -> BluetoothReadback {
        BluetoothReadback(helperPower: power, helperDevices: devices, native: snapshot,
                          nativeIssue: issue ?? (snapshot == nil ? .unavailable : nil),
                          nativeStale: snapshot.map { now - $0.observedAt >= ttl } ?? false)
    }
}
