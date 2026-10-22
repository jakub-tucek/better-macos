import Foundation

struct WindowApplication {
    var pid: Int32
    var bundle: String?
}

enum WindowStringAttribute { case title, subrole }
enum WindowBoolAttribute { case minimized, fullScreen }
enum WindowGeometryAttribute { case position, size }

/// Native access only. Discovery policy, identity lifetime and write ordering belong
/// to WindowExecution, so deterministic adapters exercise the production algorithm.
protocol WindowNativeAccess {
    associatedtype Element
    associatedtype Focus
    associatedtype WriteValues
    associatedtype InventoryEntry
    var permitted: Bool { get }
    var uptime: TimeInterval { get }
    var ownPID: Int32 { get }
    func requestPermission()
    func displays() -> [WindowDisplay]
    func inventory() -> [InventoryEntry]?
    func ownerPID(_ entry: InventoryEntry) -> Int32?
    func bounds(_ entry: InventoryEntry) -> CGRect?
    func layer(_ entry: InventoryEntry) -> Int?
    func applications() -> [WindowApplication]
    func frontmostApplication() -> WindowApplication?
    func application(_ pid: Int32) -> Element
    func setTimeout(_ element: Element, seconds: Float) -> Bool
    func windows(_ root: Element) -> [Element]?
    func frame(_ element: Element) -> CGRect?
    func string(_ element: Element, _ attribute: WindowStringAttribute) -> String?
    func bool(_ element: Element, _ attribute: WindowBoolAttribute) -> Bool?
    func isSettable(_ element: Element, _ attribute: WindowGeometryAttribute) -> Bool
    func equal(_ lhs: Element, _ rhs: Element) -> Bool
    func focused(_ root: Element) -> Focus?
    func focusEqual(_ focus: Focus, _ element: Element) -> Bool
    func writeValues(_ frame: CGRect) -> WriteValues?
    func write(_ element: Element, _ attribute: WindowGeometryAttribute, _ values: WriteValues) -> Bool
}

/// Verified whole-desktop execution. Host admission and queued lifecycle checks
/// remain in the host/coordinator; this module owns AX-level refusal and readback.
class WindowExecution<Access: WindowNativeAccess>: WindowPositionBackend {
    private let access: Access
    private var elements: [String: Access.Element] = [:]

    init(access: Access) { self.access = access }
    var permitted: Bool { access.permitted }
    func requestPermission() { access.requestPermission() }
    func displays() -> [WindowDisplay] { access.displays() }

    func windows() throws -> [PositionedWindow] {
        var nextElements: [String: Access.Element] = [:]
        defer { elements = nextElements }
        guard permitted else { throw ToggleError(message: "Accessibility permission is unavailable") }
        guard let visible = access.inventory() else {
            throw ToggleError(message: "WindowServer discovery failed; no snapshot was accepted")
        }
        let visiblePIDs = Set(visible.compactMap { access.ownerPID($0) })
        let deadline = access.uptime + 0.75
        var incomplete = false
        var unreadableApps = Set<String>()
        let result = access.applications().flatMap { app -> [PositionedWindow] in
            if access.uptime >= deadline { incomplete = true; return [] }
            guard access.uptime < deadline, app.pid != access.ownPID,
                  let bundle = app.bundle, visiblePIDs.contains(app.pid) else { return [] }
            let root = access.application(app.pid)
            guard access.setTimeout(root, seconds: 0.05) else { incomplete = true; return [] }
            guard let windows = access.windows(root) else { unreadableApps.insert(bundle); return [] }
            let records = windows.compactMap { window -> PositionedWindow? in
                guard access.uptime < deadline else { incomplete = true; return nil }
                guard access.setTimeout(window, seconds: 0.05) else { incomplete = true; return nil }
                guard let frame = access.frame(window) else { return nil }
                let readTitle = access.string(window, .title)
                if readTitle == nil { unreadableApps.insert(bundle) }
                let title = readTitle ?? ""
                let positionSettable = access.isSettable(window, .position)
                let sizeSettable = access.isSettable(window, .size)
                // AX lists other Spaces too. Geometry alone cannot prove identity.
                let onScreen = visible.contains { info in
                    guard access.ownerPID(info) == app.pid, let rect = access.bounds(info) else { return false }
                    return rect == frame && access.layer(info) == 0
                }
                let supported = onScreen && access.string(window, .subrole) == "AXStandardWindow" &&
                    access.bool(window, .minimized) == false && access.bool(window, .fullScreen) == false && positionSettable && sizeSettable
                let token = elements.first(where: { access.equal($0.value, window) })?.key ?? UUID().uuidString
                nextElements[token] = window
                return PositionedWindow(token: token, app: bundle, title: title, frame: frame, supported: supported)
            }
            if records.count != windows.count { unreadableApps.insert(bundle) }
            return records.map { record in
                var record = record
                if records.count != windows.count || !Self.hasUniqueGeometry(record.frame, in: records.map(\.frame)) { record.supported = false }
                return record
            }
        }
        if incomplete { throw ToggleError(message: "Accessibility discovery timed out; no snapshot was accepted") }
        if !unreadableApps.isEmpty { throw ToggleError(message: "Incomplete Accessibility metadata for \(unreadableApps.sorted().joined(separator: ", "))") }
        return result.map { record in
            var record = record
            if unreadableApps.contains(record.app) { record.supported = false }
            return record
        }
    }

    static func hasUniqueGeometry(_ frame: CGRect, in frames: [CGRect]) -> Bool {
        frames.filter { $0 == frame }.count == 1
    }
    static func destinationIsClear(_ frame: CGRect, for window: PositionedWindow, in snapshot: [PositionedWindow]) -> Bool {
        !snapshot.contains { $0.app == window.app && $0.token != window.token && $0.frame == frame }
    }
    private func focusedElement() -> Access.Focus? {
        guard permitted, let app = access.frontmostApplication(), app.pid != access.ownPID else { return nil }
        let root = access.application(app.pid)
        guard access.setTimeout(root, seconds: 0.05) else { return nil }
        return access.focused(root)
    }
    func focusedWindow() throws -> PositionedWindow? {
        let snapshot = try windows()
        guard let focused = focusedElement() else { return nil }
        return snapshot.first { window in
            guard window.supported, let element = elements[window.token] else { return false }
            return access.focusEqual(focused, element)
        }
    }
    func moveFocused(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        move(window, to: frame, requireFocus: true)
    }
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        move(window, to: frame, requireFocus: false)
    }
    private func move(_ window: PositionedWindow, to frame: CGRect, requireFocus: Bool) -> Bool {
        guard permitted, let element = elements[window.token] else { return false }
        guard let snapshot = try? windows() else { return false }
        let fresh = snapshot.filter { $0.app == window.app && $0.title == window.title }
        guard fresh.count == 1, fresh[0].supported, let freshElement = elements[fresh[0].token], access.equal(element, freshElement) else { return false }
        guard Self.destinationIsClear(frame, for: fresh[0], in: snapshot) else { return false }
        guard access.string(element, .title) == window.title,
              access.bool(element, .minimized) == false,
              access.bool(element, .fullScreen) == false else { return false }
        guard let values = access.writeValues(frame) else { return false }
        guard !requireFocus || focusedElement().map({ access.focusEqual($0, element) }) == true else { return false }
        // Move before resize, then correct any resize-induced position adjustment.
        guard access.write(element, .position, values),
              access.write(element, .size, values),
              access.write(element, .position, values) else { return false }
        guard let actual = access.frame(element) else { return false }
        return actual.origin == frame.origin && actual.size == frame.size
    }
}
