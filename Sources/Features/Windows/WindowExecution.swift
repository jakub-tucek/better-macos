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
    func enhancedUserInterface(_ root: Element) -> Bool?
    func setEnhancedUserInterface(_ root: Element, _ enabled: Bool)
}

/// Verified window execution. Host admission and queued lifecycle checks
/// remain in the host/coordinator; this module owns AX-level refusal and readback.
class WindowExecution<Access: WindowNativeAccess>: WindowPositionBackend {
    private let access: Access
    private var elements: [String: Access.Element] = [:]
    // Keep identities for shortcut originals across foreground-app changes. Every
    // write still requires a fresh app scan and native identity/focus validation.
    private var focusedElements: [String: Access.Element] = [:]
    private let diagnostics: Diagnostics

    init(access: Access, diagnostics: Diagnostics = .shared) { self.access = access; self.diagnostics = diagnostics }
    var permitted: Bool { access.permitted }
    func requestPermission() { access.requestPermission() }
    func displays() -> [WindowDisplay] { access.displays() }

    func windows() throws -> [PositionedWindow] {
        try windows(in: nil)
    }
    private func windows(in application: WindowApplication?) throws -> [PositionedWindow] {
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
        let applications = application.map { [$0] } ?? access.applications()
        let result = applications.flatMap { app -> [PositionedWindow] in
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
                let token = elements.first(where: { access.equal($0.value, window) })?.key ??
                    focusedElements.first(where: { access.equal($0.value, window) })?.key ?? UUID().uuidString
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
    /// Shortcut readback only: AX rounds fractional tiles, so allow one point per edge.
    /// Saved layouts keep exact verification.
    static func reached(_ actual: CGRect?, _ expected: CGRect) -> Bool {
        guard let actual else { return false }
        return abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1 &&
            abs(actual.maxX - expected.maxX) <= 1 && abs(actual.maxY - expected.maxY) <= 1
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
    /// Shortcuts identify the window by AX focus, so sibling windows that are
    /// unreadable or share geometry or titles do not block it. Saved layouts keep
    /// whole-app discovery and its uniqueness rules.
    func focusedWindow() throws -> PositionedWindow? {
        guard permitted else { throw ToggleError(message: "Accessibility permission is unavailable") }
        guard let app = access.frontmostApplication(), app.pid != access.ownPID, let bundle = app.bundle else { return nil }
        guard let visible = access.inventory() else {
            throw ToggleError(message: "WindowServer discovery failed; no snapshot was accepted")
        }
        let root = access.application(app.pid)
        guard access.setTimeout(root, seconds: 0.05), let focus = access.focused(root),
              let element = access.windows(root)?.first(where: { access.focusEqual(focus, $0) }) else {
            return unsupported("no_focused_window", frame: nil)
        }
        guard access.setTimeout(element, seconds: 0.05), let frame = access.frame(element) else {
            return unsupported("unreadable_frame", frame: nil)
        }
        // AX lists other Spaces too; require the matching on-screen WindowServer entry.
        let onScreen = visible.contains { info in
            access.ownerPID(info) == app.pid && access.bounds(info) == frame && access.layer(info) == 0
        }
        guard onScreen else { return unsupported("not_on_screen", frame: frame) }
        guard access.string(element, .subrole) == "AXStandardWindow" else { return unsupported("not_standard", frame: frame) }
        guard access.bool(element, .minimized) == false, access.bool(element, .fullScreen) == false else {
            return unsupported("minimized_or_full_screen", frame: frame)
        }
        guard access.isSettable(element, .position), access.isSettable(element, .size) else {
            return unsupported("not_settable", frame: frame)
        }
        let token = focusedElements.first(where: { access.equal($0.value, element) })?.key ??
            elements.first(where: { access.equal($0.value, element) })?.key ?? UUID().uuidString
        if focusedElements[token] == nil && focusedElements.count >= 64,
           let evicted = focusedElements.keys.sorted().first { focusedElements.removeValue(forKey: evicted) }
        focusedElements[token] = element
        return PositionedWindow(token: token, app: bundle, title: access.string(element, .title) ?? "", frame: frame, supported: true)
    }
    private func unsupported(_ reason: String, frame: CGRect?) -> PositionedWindow? {
        var fields = ["reason": reason, "displays": describe(access.displays())]
        if let frame { fields["frame"] = Self.describe(frame) }
        diagnostics.emit("windows", "focus_unsupported", outcome: "blocked", level: .warning, fields: fields)
        return nil
    }

    func moveFocused(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        guard permitted else { return refuse("permission", frame, focused: true) }
        guard let element = focusedElements[window.token] ?? elements[window.token] else {
            return refuse("unknown_window", frame, focused: true)
        }
        guard let frontmost = access.frontmostApplication(), frontmost.pid != access.ownPID,
              frontmost.bundle == window.app else { return refuse("frontmost_changed", frame, focused: true) }
        guard access.bool(element, .minimized) == false, access.bool(element, .fullScreen) == false else {
            return refuse("window_state_changed", frame, focused: true)
        }
        guard let values = access.writeValues(frame) else { return refuse("write_values", frame, focused: true) }
        let displays = access.displays()
        guard focusedElement().map({ access.focusEqual($0, element) }) == true else { return refuse("focus_changed", frame, focused: true) }
        // Apps with AXEnhancedUserInterface on (Chrome, when an assistive app requests it)
        // animate or drop AX size changes. Rectangle disables it for the adjustment.
        let root = access.application(frontmost.pid)
        let enhancedUI = access.enhancedUserInterface(root) == true
        if enhancedUI { access.setEnhancedUserInterface(root, false) }
        defer { if enhancedUI { access.setEnhancedUserInterface(root, true) } }
        return place(element, at: frame, values: values, displays: displays)
    }

    private func place(_ element: Access.Element, at frame: CGRect, values: Access.WriteValues, displays: [WindowDisplay]) -> Bool {
        // macOS caps size to the window's current display, so size again after crossing displays.
        let written = access.write(element, .size, values) && access.write(element, .position, values) &&
            access.write(element, .size, values)
        var readback = written ? access.frame(element) : nil
        if written, let current = readback, !Self.reached(current, frame),
           abs(current.width - frame.width) <= 1, abs(current.height - frame.height) <= 1,
           access.write(element, .position, values) {
            readback = access.frame(element)
        }
        if written, Self.reached(readback, frame) { return true }
        var reason = written ? "readback_mismatch" : "write_failed"
        if recoverFocused(element, requested: frame, displays: displays, reason: &reason) { return true }
        return refuse(reason, frame, focused: true, actual: readback)
    }

    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        guard permitted else { return refuse("permission", frame) }
        guard let element = elements[window.token] else { return refuse("unknown_window", frame) }
        guard let snapshot = try? windows(in: nil) else { return refuse("discovery_failed", frame) }
        let fresh = snapshot.filter { $0.app == window.app && $0.title == window.title }
        guard fresh.count == 1 else { return refuse(fresh.isEmpty ? "title_missing" : "title_ambiguous", frame) }
        guard fresh[0].supported else { return refuse("unsupported", frame, actual: fresh[0].frame) }
        guard let freshElement = elements[fresh[0].token], access.equal(element, freshElement) else { return refuse("identity_changed", frame) }
        guard Self.destinationIsClear(frame, for: fresh[0], in: snapshot) else { return refuse("destination_occupied", frame) }
        guard access.string(element, .title) == window.title,
              access.bool(element, .minimized) == false,
              access.bool(element, .fullScreen) == false else { return refuse("window_state_changed", frame) }
        guard let values = access.writeValues(frame) else { return refuse("write_values", frame) }
        let written = access.write(element, .position, values) && access.write(element, .size, values) &&
            access.write(element, .position, values)
        let readback = written ? access.frame(element) : nil
        if written, readback == frame { return true }
        return refuse(written ? "readback_mismatch" : "write_failed", frame, actual: readback)
    }

    // Geometry and a closed reason only; titles and app identities stay out of logs.
    private func refuse(_ reason: String, _ requested: CGRect, focused: Bool = false, actual: CGRect? = nil) -> Bool {
        var fields = ["reason": reason, "focused": String(focused), "requested": Self.describe(requested),
                      "displays": describe(access.displays())]
        if let actual { fields["actual"] = Self.describe(actual) }
        diagnostics.emit("windows", "move_refused", outcome: "blocked", level: .warning, fields: fields)
        return false
    }

    /// One resize-first retry, then position using the accepted size. Never retry
    /// discovery refusals or redirect recovery to a newly focused window.
    private func recoverFocused(_ element: Access.Element, requested: CGRect, displays: [WindowDisplay], reason: inout String) -> Bool {
        guard let bounds = displays.first(where: { $0.bounds.contains(requested) })?.bounds else {
            reason += "+recovery_no_display"; return false
        }
        func admitted() -> Bool {
            permitted && access.displays() == displays &&
                access.bool(element, .minimized) == false && access.bool(element, .fullScreen) == false &&
                focusedElement().map { access.focusEqual($0, element) } == true
        }
        guard let values = access.writeValues(requested), admitted() else { reason += "+recovery_not_admitted"; return false }
        // A refused resize must not prevent a position-only rescue.
        _ = access.write(element, .size, values)
        guard let actual = access.frame(element),
              [actual.minX, actual.minY, actual.width, actual.height].allSatisfy(\.isFinite),
              actual.width > 0, actual.height > 0 else { reason += "+recovery_unreadable"; return false }
        let recovered = CGRect(
            x: max(bounds.minX, min(requested.minX, bounds.maxX - actual.width)),
            y: max(bounds.minY, min(requested.minY, bounds.maxY - actual.height)),
            width: actual.width, height: actual.height)
        guard let position = access.writeValues(recovered), admitted() else { reason += "+recovery_not_admitted"; return false }
        _ = access.write(element, .position, position)
        // A size the app limits still counts once the window sits fully on the display.
        guard bounds.contains(recovered) else { reason += "+recovery_oversized"; return false }
        let final = access.frame(element)
        guard Self.reached(final, recovered) else {
            reason += "+recovery_readback_mismatch:" + (final.map(Self.describe) ?? "unreadable")
            return false
        }
        return true
    }
    private func describe(_ displays: [WindowDisplay]) -> String {
        displays.map { Self.describe($0.bounds) }.joined(separator: " ")
    }
    private static func describe(_ rect: CGRect) -> String {
        "\(rect.minX),\(rect.minY),\(rect.width)x\(rect.height)"
    }
}
