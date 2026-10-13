import AppKit
import Darwin

struct ToggleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DisplayPosition: Codable {
    let uuid: String
    let x: Int32
    let y: Int32
}

struct DisplayRecord: Codable {
    let uuid: String
    var name: String
    var lastID: UInt32
    var bootSession: String?
    var disabledByApp: Bool
}

struct Monitor {
    let uuid: String
    let name: String
    let id: UInt32?
    let enabled: Bool
    let isMain: Bool
    let disabledByApp: Bool
    var isBuiltIn: Bool = false
}

enum DisplaySafety {
    static func validateDisable(_ id: UInt32, activeIDs: [UInt32], mirroredIDs: Set<UInt32>) throws {
        guard activeIDs.contains(id) else { throw ToggleError(message: "This display is not an independent active screen.") }
        guard activeIDs.count > 1 else { throw ToggleError(message: "Refusing to disable the last usable screen.") }
        guard mirroredIDs.isEmpty else { throw ToggleError(message: "Turn off display mirroring in System Settings first.") }
    }
}

final class DisplayController {
    private let defaults = UserDefaults.standard
    private let framework: UnsafeMutableRawPointer?
    private let configureEnabled: (@convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32)?
    private var records: [DisplayRecord] = []

    private var bootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    init() {
        if defaults.object(forKey: "displayRecords") == nil,
           let legacy = UserDefaults(suiteName: "local.jakub.monitor-toggle") {
            for key in ["displayRecords", "savedLayout", "disabledByApp", "targetUUID", "lastDisplayID", "disabledBootSession"] {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        // CLI recovery needs a WindowServer connection too.
        _ = NSApplication.shared
        _ = NSScreen.screens
        framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if let framework, let symbol = dlsym(framework, "CGSConfigureDisplayEnabled") {
            configureEnabled = unsafeBitCast(symbol, to: (@convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32).self)
        } else {
            configureEnabled = nil
        }
        if let data = defaults.data(forKey: "displayRecords"),
           let saved = try? JSONDecoder().decode([DisplayRecord].self, from: data) {
            records = saved
        }
        // Preserve recovery information from the original single-Dell app.
        if defaults.bool(forKey: "disabledByApp"),
           let uuid = defaults.string(forKey: "targetUUID"),
           let id = UInt32(exactly: defaults.integer(forKey: "lastDisplayID")),
           !records.contains(where: { $0.uuid == uuid }) {
            records.append(DisplayRecord(uuid: uuid, name: "Dell S2716DG", lastID: id,
                                         bootSession: defaults.string(forKey: "disabledBootSession"), disabledByApp: true))
        }
        saveRecords()
        defaults.removeObject(forKey: "disabledByApp")
        refreshDisplays()
    }

    var supported: Bool { configureEnabled != nil }
    // Recovery remains allowed, but no new display may be disabled until the
    // reported cursor-only/input freeze has been diagnosed safely.
    var canDisableDisplays: Bool { false }
    var disabledUUIDs: [String] { records.filter(\.disabledByApp).map(\.uuid) }

    func uuid(for id: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    private func resolve(_ uuid: String) -> CGDirectDisplayID? {
        guard let value = CFUUIDCreateFromString(nil, uuid as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(value)
        return id == kCGNullDirectDisplay ? nil : id
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "displayRecords") }
    }

    func refreshDisplays() {
        if let data = defaults.data(forKey: "displayRecords"),
           let saved = try? JSONDecoder().decode([DisplayRecord].self, from: data) { records = saved }
        var visibleUUIDs = Set<String>()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = uuid(for: id) else { continue }
            visibleUUIDs.insert(uuid)
            if let index = records.firstIndex(where: { $0.uuid == uuid }) {
                records[index].name = screen.localizedName
                records[index].lastID = id
                records[index].bootSession = bootSession
            } else {
                records.append(DisplayRecord(uuid: uuid, name: screen.localizedName, lastID: id,
                                             bootSession: bootSession, disabledByApp: false))
            }
        }
        // Mirror slaves may not have a separate NSScreen, but still need a row.
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [UInt32](repeating: 0, count: Int(count))
            if CGGetOnlineDisplayList(count, &ids, &count) == .success {
                for id in ids.prefix(Int(count)) {
                    guard let uuid = uuid(for: id) else { continue }
                    visibleUUIDs.insert(uuid)
                    if let index = records.firstIndex(where: { $0.uuid == uuid }) {
                        records[index].lastID = id
                        records[index].bootSession = bootSession
                    } else {
                        records.append(DisplayRecord(uuid: uuid, name: "Display \(id)", lastID: id,
                                                     bootSession: bootSession, disabledByApp: false))
                    }
                }
            }
        }
        // Keep disabled ghost rows so they can be re-enabled. Forget unplugged
        // displays we did not disable; discard stale IDs after reboot.
        records.removeAll { !visibleUUIDs.contains($0.uuid) && (!$0.disabledByApp || $0.bootSession != bootSession) }
        saveRecords()
    }

    func displayID(for value: String) -> UInt32? {
        if let id = resolve(value) { return id }
        guard let record = records.first(where: { $0.uuid == value }), record.disabledByApp,
              let bootSession, record.bootSession == bootSession else { return nil }
        // Tahoe excludes disabled displays from both UUID APIs. A cached ID is
        // usable for recovery only in this boot and if not visibly reassigned.
        if let current = uuid(for: record.lastID), current != value { return nil }
        return record.lastID
    }

    func isEnabled(_ uuid: String) -> Bool {
        guard let id = displayID(for: uuid) else { return false }
        return CGDisplayIsActive(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    }

    var monitors: [Monitor] {
        records.map { record in
            let id = displayID(for: record.uuid)
            return Monitor(uuid: record.uuid, name: record.name, id: id, enabled: isEnabled(record.uuid),
                           isMain: id.map { CGDisplayIsMain($0) != 0 } ?? false, disabledByApp: record.disabledByApp,
                           isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
        }.sorted { $0.name == $1.name ? $0.uuid < $1.uuid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func activeIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        try check(CGGetActiveDisplayList(0, nil, &count), "Read displays")
        var ids = [UInt32](repeating: 0, count: Int(count))
        try check(CGGetActiveDisplayList(count, &ids, &count), "Read displays")
        return Array(ids.prefix(Int(count)))
    }

    private func check(_ result: CGError, _ operation: String) throws {
        guard result == .success else { throw ToggleError(message: "\(operation) failed (\(result.rawValue)).") }
    }

    private func transaction(_ changes: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "Begin display configuration")
        guard let config else { throw ToggleError(message: "macOS returned no display configuration.") }
        do {
            try changes(config)
            // Never persist the disabled state to macOS display preferences.
            try check(CGCompleteDisplayConfiguration(config, .forSession), "Apply display configuration")
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
    }

    func setEnabled(_ enabled: Bool, for value: String) throws {
        guard enabled || canDisableDisplays else {
            throw ToggleError(message: "Display disabling is paused for safety while investigating a system freeze.")
        }
        guard let configureEnabled else { throw ToggleError(message: "This macOS version lacks the display disconnect API.") }
        refreshDisplays()
        guard let index = records.firstIndex(where: { $0.uuid == value }), let id = displayID(for: value) else {
            throw ToggleError(message: "Monitor not found. Check its cable and power.")
        }
        if enabled && isEnabled(value) { return }
        if !enabled {
            let active = try activeIDs()
            try DisplaySafety.validateDisable(id, activeIDs: active,
                                              mirroredIDs: Set(active.filter { CGDisplayIsInMirrorSet($0) != 0 }))
            guard let bootSession else { throw ToggleError(message: "Cannot identify this boot session safely.") }
            // Keep the original complete layout until ALL app-disabled screens
            // are restored, rather than overwriting it on every toggle.
            if disabledUUIDs.isEmpty {
                let positions = try active.map { display -> DisplayPosition in
                    guard let uuid = uuid(for: display) else { throw ToggleError(message: "Cannot identify active display") }
                    let origin = CGDisplayBounds(display).origin
                    return DisplayPosition(uuid: uuid, x: Int32(origin.x), y: Int32(origin.y))
                }
                defaults.set(try JSONEncoder().encode(positions), forKey: "savedLayout")
            }
            records[index].bootSession = bootSession
            records[index].lastID = id
            records[index].disabledByApp = true
            saveRecords() // A crash during the transaction must still be recoverable.
        }
        try transaction { config in
            let result = configureEnabled(config, id, enabled)
            guard result == 0 else { throw ToggleError(message: "Display toggle failed (\(result)).") }
        }
    }

    func finishRestore(_ value: String) throws {
        guard isEnabled(value) else { throw ToggleError(message: "Monitor did not come back. Check its cable/power; logout resets session-only changes.") }
        // Restore the baseline only once every originally connected screen is back.
        try restoreLayout()
        if let index = records.firstIndex(where: { $0.uuid == value }) { records[index].disabledByApp = false }
        saveRecords()
        if disabledUUIDs.isEmpty { defaults.removeObject(forKey: "savedLayout") }
    }

    private func restoreLayout() throws {
        guard let data = defaults.data(forKey: "savedLayout") else { return }
        let positions = try JSONDecoder().decode([DisplayPosition].self, from: data)
        let active = try activeIDs()
        let resolved = positions.compactMap { position -> (UInt32, DisplayPosition)? in
            guard let id = resolve(position.uuid), active.contains(id) else { return nil }
            return (id, position)
        }
        // Do not rearrange a setup someone has changed by plugging/unplugging.
        guard Set(resolved.map { $0.0 }) == Set(active), resolved.count == positions.count else { return }
        guard resolved.contains(where: { id, position in
            let origin = CGDisplayBounds(id).origin
            return Int32(origin.x) != position.x || Int32(origin.y) != position.y
        }) else { return }
        try transaction { config in
            for (id, position) in resolved {
                try check(CGConfigureDisplayOrigin(config, id, position.x, position.y), "Restore monitor layout")
            }
        }
    }

    func status() -> String {
        monitors.map { monitor in
            "\(monitor.enabled ? "●" : "○") \(monitor.name)\(monitor.isMain ? " (main)" : "") — \(monitor.enabled ? "enabled" : "disabled/unavailable") [ID: \(monitor.id.map(String.init) ?? "unknown")]"
        }.joined(separator: "\n")
    }

    func snapshot() throws -> Data {
        var displays: [String: [Double]] = [:]
        for id in try activeIDs() {
            guard let value = uuid(for: id) else { throw ToggleError(message: "Cannot identify active display") }
            let bounds = CGDisplayBounds(id)
            displays[value] = [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height]
        }
        return try JSONSerialization.data(withJSONObject: [
            "main": uuid(for: CGMainDisplayID()) ?? "unknown", "displays": displays
        ], options: [.sortedKeys])
    }
}
