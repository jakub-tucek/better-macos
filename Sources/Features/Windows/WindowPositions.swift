import AppKit
import ApplicationServices

struct WindowDisplay: Codable, Equatable {
    var id: String
    var bounds: CGRect
}

struct PositionedWindow: Codable {
    var token: String
    var app: String
    var title: String
    var frame: CGRect
    var supported: Bool
    var display: String = ""
}

struct WindowLayout: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var displays: [WindowDisplay]
    var windows: [PositionedWindow]
}

struct WindowMove {
    var window: PositionedWindow
    var frame: CGRect
    var temporary = false
}

/// Avoid creating an ambiguous geometry correlation while swapping same-app windows.
enum WindowMovePlanner {
    static func plan(_ requested: [WindowMove], current: [PositionedWindow], displays: [WindowDisplay]) -> [WindowMove]? {
        var remaining = requested, positions = current, result: [WindowMove] = []
        func blocked(_ move: WindowMove) -> Bool {
            positions.contains { $0.app == move.window.app && $0.token != move.window.token && $0.frame == move.frame }
        }
        func record(_ move: WindowMove) {
            result.append(move)
            if let index = positions.firstIndex(where: { $0.token == move.window.token }) { positions[index].frame = move.frame }
        }
        while !remaining.isEmpty {
            if let index = remaining.firstIndex(where: { !blocked($0) }) {
                record(remaining.remove(at: index)); continue
            }
            // A cycle needs a one-pixel parking position. Never stage if a final
            // target is occupied by a window that is not itself going to move.
            guard result.count < requested.count * 3,
                  remaining.allSatisfy({ move in positions.filter { $0.app == move.window.app && $0.token != move.window.token && $0.frame == move.frame }.allSatisfy { blocker in remaining.contains { $0.window.token == blocker.token } } }),
                  let first = remaining.first,
                  let currentWindow = positions.first(where: { $0.token == first.window.token }),
                  let display = displays.first(where: { $0.bounds.contains(currentWindow.frame) }) else { return nil }
            let candidates = [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)].map {
                currentWindow.frame.offsetBy(dx: $0.x, dy: $0.y)
            }
            guard let parking = candidates.first(where: { frame in
                display.bounds.contains(frame) && !positions.contains { $0.app == first.window.app && $0.frame == frame } &&
                    !requested.contains { $0.window.app == first.window.app && $0.frame == frame }
            }) else { return nil }
            record(WindowMove(window: first.window, frame: parking, temporary: true))
        }
        return result
    }
}

protocol WindowPositionBackend: AnyObject {
    var permitted: Bool { get }
    func requestPermission()
    func displays() -> [WindowDisplay]
    func windows() throws -> [PositionedWindow]
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool
    func focusedWindow() throws -> PositionedWindow?
    func moveFocused(_ window: PositionedWindow, to frame: CGRect) -> Bool
}

extension WindowPositionBackend {
    func focusedWindow() throws -> PositionedWindow? { nil }
    func moveFocused(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        guard permitted, let focused = try? focusedWindow(), focused.token == window.token else { return false }
        return move(window, to: frame)
    }
}

/// Main-thread coordinator. Each write yields to lifecycle notifications and checks its generation.
final class WindowPositions: ObservableObject {
    @Published private(set) var layouts: [WindowLayout] = []
    @Published var summary = "Save a named layout to begin."
    @Published private var automaticValue: Bool
    @Published private var pausedValue: Bool
    @Published private var exclusionsValue: String
    @Published private var selectedValue: String
    @Published private var shortcutsValue: Bool
    @Published private(set) var shortcutsActive = false
    @Published private(set) var shortcutStatus = "Shortcuts are off."
    var shortcutsEnabled: Bool {
        get { shortcutsValue }
        set {
            guard acceptsActions(), !stopped else { return }
            shortcutsValue = newValue; defaults.set(newValue, forKey: "windows.shortcuts")
            unregisterShortcuts(); reconcileShortcuts()
        }
    }
    private let shortcuts: WindowShortcutRegistering
    private var shortcutAttempted = false
    private var shortcutGeneration = 0
    private var originalFrames: [String: CGRect] = [:]
    var automatic: Bool {
        get { automaticValue }
        set { guard acceptsActions() else { return }; automaticValue = newValue; defaults.set(newValue, forKey: "windows.auto"); pending = false; generation += 1 }
    }
    var paused: Bool {
        get { pausedValue }
        set { guard acceptsActions() else { return }; pausedValue = newValue; defaults.set(newValue, forKey: "windows.paused"); pending = false; generation += 1 }
    }
    var exclusions: String {
        get { exclusionsValue }
        set { guard acceptsActions() else { return }; exclusionsValue = newValue; defaults.set(newValue, forKey: "windows.exclusions"); generation += 1 }
    }
    var selected: String {
        get { selectedValue }
        set { guard acceptsActions() else { return }; selectedValue = newValue; defaults.set(newValue, forKey: "windows.selected"); generation += 1 }
    }
    var acceptsActions: () -> Bool = { true }
    var activity: ActivityJournal?
    @Published private(set) var ready = false
    private let backend: WindowPositionBackend
    private let defaults: UserDefaults
    private let schedule: (@escaping () -> Void) -> Void
    private var generation = 0 {
        didSet {
            if let activeRestore { activity?.finish(activeRestore, result: .windowsCanceled(activityMoved)) }
            activeRestore = nil; activityMoved = 0
        }
    }
    private var activeRestore: ActivityOperationID?
    private var activityMoved = 0
    private var pending = false
    private var lastDisplaySet: [String]?
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    var onWake: (() -> Void)?

    init(backend: WindowPositionBackend = AXWindowPositionBackend(), defaults: UserDefaults = .standard,
         shortcuts: WindowShortcutRegistering = WindowShortcutRegistration(),
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: $0) }) {
        self.backend = backend; self.defaults = defaults
        self.shortcuts = shortcuts
        shortcutsValue = defaults.bool(forKey: "windows.shortcuts")
        self.schedule = schedule
        automaticValue = defaults.bool(forKey: "windows.auto")
        pausedValue = defaults.bool(forKey: "windows.paused")
        exclusionsValue = defaults.string(forKey: "windows.exclusions") ?? ""
        selectedValue = defaults.string(forKey: "windows.selected") ?? ""
        if let data = defaults.data(forKey: "windows.layouts") {
            layouts = (try? JSONDecoder().decode([WindowLayout].self, from: data)) ?? []
        }
    }

    func start() {
        guard wakeObserver == nil else { return }
        stopped = false
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.invalidate() }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wake(); self?.onWake?()
        }
        WindowConnectionNotifications.add(self)
    }
    func stop() {
        stopped = true; invalidate()
        originalFrames.removeAll()
        onWake = nil
        WindowConnectionNotifications.remove(self)
        let center = NSWorkspace.shared.notificationCenter
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let sleepObserver { center.removeObserver(sleepObserver) }
        wakeObserver = nil; sleepObserver = nil
    }
    deinit { stop() }
    func invalidate() { ready = false; pending = false; generation += 1; unregisterShortcuts() }
    func wake() { invalidate(); pending = automatic && !paused }
    func connectionChanged() { wake(); onWake?() }
    func reconcile(ready: Bool, settled: Bool) {
        if !ready { generation += 1 }
        self.ready = ready && !stopped
        reconcileShortcuts()
        guard settled, !stopped else { return }
        let ids = backend.displays().map(\.id).sorted()
        if let previous = lastDisplaySet, previous != ids { pending = automatic && !paused }
        lastDisplaySet = ids
        guard self.ready, pending else { return }
        pending = false
        guard automatic, !paused else { return }
        let candidates = layouts.filter { $0.displays.map(\.id).sorted() == ids }
        if let layout = candidates.first(where: { $0.id == selected }) ?? (candidates.count == 1 ? candidates.first : nil) {
            restore(layout.id, trigger: .automatic)
        } else { summary = "No unique saved layout for this display set; select one." }
    }
    func requestPermission() { guard acceptsActions() else { return }; backend.requestPermission() }
    var permitted: Bool { backend.permitted }
    var canCapture: Bool { acceptsActions() && ready && !stopped && permitted }
    private func unregisterShortcuts() {
        shortcutGeneration += 1
        shortcuts.stop(); shortcutsActive = false; shortcutAttempted = false
    }
    func retryShortcuts() {
        guard acceptsActions(), !stopped else { return }
        unregisterShortcuts(); reconcileShortcuts()
    }
    private func reconcileShortcuts() {
        guard shortcutsEnabled, canCapture else {
            unregisterShortcuts()
            shortcutStatus = shortcutsEnabled ? "Waiting for Accessibility access and stable displays." : "Shortcuts are off."
            return
        }
        guard !shortcutAttempted else { return }
        shortcutAttempted = true
        let ticket = shortcutGeneration
        shortcutsActive = shortcuts.start { [weak self] action in
            guard let self, self.shortcutGeneration == ticket, self.shortcutsActive else { return }
            self.performShortcut(action)
        }
        shortcutStatus = shortcutsActive ? "Ready · acts on the focused window." : "Shortcuts unavailable. Quit other window managers, then retry."
    }
    func performShortcut(_ action: WindowShortcutAction) {
        guard shortcutsEnabled, shortcutsActive, canCapture else { return }
        let window: PositionedWindow
        do {
            guard let focused = try backend.focusedWindow(), focused.supported, !excluded.contains(focused.app) else {
                shortcutStatus = "Focus a supported window in an app that is not excluded."; return
            }
            window = focused
        } catch { shortcutStatus = "Window discovery failed: \(error.localizedDescription)"; return }
        let displays = backend.displays()
        guard let frame = action.destination(for: window.frame, displays: displays, original: originalFrames[window.token]) else {
            shortcutStatus = action == .restore ? "No original size saved for this window." : "No available destination display."; return
        }
        guard canCapture, displays == backend.displays() else { return }
        // A manual move supersedes any queued automatic layout restoration.
        pending = false; generation += 1
        if action != .restore && originalFrames[window.token] == nil {
            if originalFrames.count >= 64, let key = originalFrames.keys.sorted().first { originalFrames.removeValue(forKey: key) }
            originalFrames[window.token] = window.frame
        }
        if backend.moveFocused(window, to: frame) {
            if action == .restore { originalFrames.removeValue(forKey: window.token) }
            shortcutStatus = "\(action.title) applied."
        } else {
            shortcutStatus = "Window could not reach the requested size or position. The app may limit resizing; try Restore original size."
        }
    }
    func canRestore(_ id: String) -> Bool {
        guard canCapture, let layout = layouts.first(where: { $0.id == id }) else { return false }
        return layout.displays.map(\.id).sorted() == backend.displays().map(\.id).sorted()
    }
    private var excluded: Set<String> { Set(exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
    @discardableResult private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(layouts) else { return false }
        defaults.set(data, forKey: "windows.layouts")
        return true
    }
    func delete(_ id: String) { guard acceptsActions() else { return }; generation += 1; layouts.removeAll { $0.id == id }; persist(); if selected == id { selected = "" } }
    @discardableResult func rename(_ id: String, to name: String) -> Bool {
        guard acceptsActions() else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = layouts.firstIndex(where: { $0.id == id }) else { return false }
        layouts[index].name = trimmed
        persist()
        return true
    }
    func save(_ name: String) {
        guard acceptsActions() else { return }
        let operation = activity?.begin(.windowSave, trigger: .user)
        var outcome = ActivityResult.blocked
        defer { if let operation { activity?.finish(operation, result: outcome) } }
        guard ready, backend.permitted else { summary = "Wait for stable displays and grant Accessibility access."; return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { summary = "Enter a layout name."; return }
        let displays = backend.displays()
        guard !displays.isEmpty else { summary = "No available displays."; return }
        let snapshot: [PositionedWindow]
        do { snapshot = try backend.windows() }
        catch { outcome = .failed; summary = "Window discovery failed: \(error.localizedDescription)"; return }
        let windows = snapshot.filter { !excluded.contains($0.app) }.compactMap { window -> PositionedWindow? in
            guard let display = displays.max(by: { $0.bounds.intersection(window.frame).area < $1.bounds.intersection(window.frame).area }), display.bounds.intersects(window.frame) else { return nil }
            var saved = window; saved.display = display.id
            saved.frame.origin.x -= display.bounds.minX; saved.frame.origin.y -= display.bounds.minY
            return saved
        }
        let layout = WindowLayout(name: name, displays: displays, windows: windows)
        layouts.append(layout); selected = layout.id
        let persisted = persist()
        summary = "Saved \(windows.count) windows in \(name)."
        outcome = persisted ? .windowsSaved(windows.count) : .failed
    }
    func restore(_ id: String, trigger: ActivityTrigger = .user) {
        guard acceptsActions() else { return }
        generation += 1
        let ticket = generation
        let operation = activity?.begin(.windowRestore, trigger: trigger)
        activeRestore = operation
        func finish(_ result: ActivityResult) {
            if let operation { activity?.finish(operation, result: result) }
            if activeRestore == operation { activeRestore = nil }
        }
        pending = false
        guard ready, !stopped, backend.permitted else { finish(.blocked); summary = "Wait for stable displays and grant Accessibility access."; return }
        guard let layout = layouts.first(where: { $0.id == id }) else { finish(.blocked); return }
        let displays = backend.displays()
        guard displays.map(\.id).sorted() == layout.displays.map(\.id).sorted() else { finish(.blocked); summary = "Saved display set is not connected."; return }
        let current: [PositionedWindow]
        do { current = try backend.windows() }
        catch { finish(.failed); summary = "Window discovery failed: \(error.localizedDescription). Try Restore now again."; return }
        var moved = 0, missing = 0, ambiguous = 0, unsupported = 0, failed = 0, skipped = 0
        var requested: [WindowMove] = []
        for saved in layout.windows {
            if excluded.contains(saved.app) { skipped += 1; continue }
            let matches = current.filter { $0.app == saved.app && $0.title == saved.title }
            let savedMatches = layout.windows.filter { $0.app == saved.app && $0.title == saved.title }
            guard !matches.isEmpty else { missing += 1; continue }
            guard !saved.title.isEmpty, matches.count == 1, savedMatches.count == 1 else { ambiguous += 1; continue }
            guard saved.supported, matches[0].supported, let display = displays.first(where: { $0.id == saved.display }) else { unsupported += 1; continue }
            var frame = saved.frame
            frame.origin.x += display.bounds.minX; frame.origin.y += display.bounds.minY
            guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0 else { unsupported += 1; continue }
            frame.size.width = min(frame.width, display.bounds.width); frame.size.height = min(frame.height, display.bounds.height)
            frame.origin.x = max(display.bounds.minX, min(frame.minX, display.bounds.maxX - frame.width))
            frame.origin.y = max(display.bounds.minY, min(frame.minY, display.bounds.maxY - frame.height))
            requested.append(WindowMove(window: matches[0], frame: frame))
        }
        guard let writes = WindowMovePlanner.plan(requested, current: current, displays: displays) else {
            finish(.blocked)
            summary = "Restore skipped: overlapping same-app targets cannot be moved without ambiguous geometry."
            return
        }
        func publish() {
            summary = "Restored \(moved); missing \(missing); ambiguous \(ambiguous); unsupported \(unsupported); excluded \(skipped); failed \(failed)."
            finish(.windowsRestored(ActivityWindowCounts(restored: moved, missing: missing, ambiguous: ambiguous, unsupported: unsupported, excluded: skipped, failed: failed)))
        }
        func step(_ index: Int) {
            guard ticket == generation, acceptsActions() else { finish(.windowsCanceled(moved)); return }
            guard ready, !stopped, backend.permitted, backend.displays() == displays else {
                summary = "Restore canceled after \(moved) windows; display state, permission, or settings changed."
                finish(.windowsCanceled(moved))
                return
            }
            guard index < writes.count else { publish(); return }
            let write = writes[index]
            if backend.move(write.window, to: write.frame) {
                if !write.temporary { moved += 1 }
                activityMoved = moved
            } else {
                failed += 1
                // Every move can be a prerequisite for another destination.
                // Failure invalidates the collision-free ordering, not just parking.
                publish(); return
            }
            schedule { [weak self] in guard self != nil else { return }; step(index + 1) }
        }
        if writes.isEmpty { publish() }
        else { schedule { [weak self] in guard self != nil else { return }; step(0) } }
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

private let windowConnectionChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
    WindowConnectionNotifications.changed()
}

/// C callbacks never dereference a module pointer. Removing a module also makes
/// already queued callbacks inert, even if CoreGraphics is concurrently notifying.
private enum WindowConnectionNotifications {
    static let lock = NSLock()
    static let modules = NSHashTable<WindowPositions>.weakObjects()
    static var registered = false
    static func add(_ module: WindowPositions) {
        lock.lock(); modules.add(module); lock.unlock()
        if !registered { registered = CGDisplayRegisterReconfigurationCallback(windowConnectionChanged, nil) == .success }
    }
    static func remove(_ module: WindowPositions) {
        lock.lock(); modules.remove(module); let empty = modules.allObjects.isEmpty; lock.unlock()
        if registered && empty { CGDisplayRemoveReconfigurationCallback(windowConnectionChanged, nil); registered = false }
    }
    static func changed() {
        lock.lock(); let targets = modules.allObjects; lock.unlock()
        for module in targets {
            DispatchQueue.main.async { [weak module] in
                guard let module else { return }
                lock.lock(); let active = modules.contains(module); lock.unlock()
                if active { module.connectionChanged() }
            }
        }
    }
}

final class AXWindowPositionBackend: WindowPositionBackend {
    private var elements: [String: AXUIElement] = [:]
    private let permissionCheck: () -> Bool
    private let windowInfo: () -> [[String: Any]]?
    init(permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         windowInfo: @escaping () -> [[String: Any]]? = { CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] }) {
        self.permissionCheck = permissionCheck
        self.windowInfo = windowInfo
    }
    var permitted: Bool { permissionCheck() }
    func requestPermission() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    func displays() -> [WindowDisplay] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let r = screen.visibleFrame
            return WindowDisplay(id: CFUUIDCreateString(nil, uuid) as String, bounds: CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height))
        }
    }
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }; return result
    }
    func windows() throws -> [PositionedWindow] {
        var nextElements: [String: AXUIElement] = [:]
        defer { elements = nextElements }
        guard permitted else { throw ToggleError(message: "Accessibility permission is unavailable") }
        guard let visible = windowInfo() else {
            throw ToggleError(message: "WindowServer discovery failed; no snapshot was accepted")
        }
        let visiblePIDs = Set(visible.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var incomplete = false
        var unreadableApps = Set<String>()
        let result = NSWorkspace.shared.runningApplications.flatMap { app -> [PositionedWindow] in
            if ProcessInfo.processInfo.systemUptime >= deadline { incomplete = true; return [] }
            guard ProcessInfo.processInfo.systemUptime < deadline, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let bundle = app.bundleIdentifier, visiblePIDs.contains(app.processIdentifier) else { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard AXUIElementSetMessagingTimeout(root, 0.05) == .success else { incomplete = true; return [] }
            guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { unreadableApps.insert(bundle); return [] }
            let records = windows.compactMap { window -> PositionedWindow? in
                guard ProcessInfo.processInfo.systemUptime < deadline else { incomplete = true; return nil }
                guard AXUIElementSetMessagingTimeout(window, 0.05) == .success else { incomplete = true; return nil }
                guard let p = value(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                      let s = value(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
                let readTitle = value(window, kAXTitleAttribute) as? String
                if readTitle == nil { unreadableApps.insert(bundle) }
                let title = readTitle ?? ""
                var positionSettable = DarwinBoolean(false), sizeSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable)
                AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
                let frame = CGRect(origin: point, size: size)
                // AX lists other Spaces too. Require a corresponding on-screen CG window.
                let onScreen = visible.contains { info in
                    guard info[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
                          let bounds = info[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                    return rect == frame && (info[kCGWindowLayer as String] as? Int == 0)
                }
                let supported = onScreen && value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole &&
                    value(window, kAXMinimizedAttribute) as? Bool == false && value(window, "AXFullScreen") as? Bool == false && positionSettable.boolValue && sizeSettable.boolValue
                let token = elements.first(where: { CFEqual($0.value, window) })?.key ?? UUID().uuidString
                nextElements[token] = window
                return PositionedWindow(token: token, app: bundle, title: title, frame: frame, supported: supported)
            }
            // Geometry is not a window identity. A hidden same-geometry sibling
            // makes correlation ambiguous, even when titles differ.
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
    private func focusedElement() -> CFTypeRef? {
        guard permitted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementSetMessagingTimeout(root, 0.05) == .success,
              let focused = value(root, kAXFocusedWindowAttribute) else { return nil }
        return focused
    }
    private func isFocused(_ element: AXUIElement) -> Bool {
        guard let focused = focusedElement() else { return false }
        return CFEqual(focused, element)
    }
    func focusedWindow() throws -> PositionedWindow? {
        let snapshot = try windows()
        guard let focused = focusedElement() else { return nil }
        return snapshot.first { window in
            guard window.supported, let element = elements[window.token] else { return false }
            return CFEqual(focused, element)
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
        guard fresh.count == 1, fresh[0].supported, let freshElement = elements[fresh[0].token], CFEqual(element, freshElement) else { return false }
        guard Self.destinationIsClear(frame, for: fresh[0], in: snapshot) else { return false }
        guard value(element, kAXTitleAttribute) as? String == window.title,
              value(element, kAXMinimizedAttribute) as? Bool == false,
              value(element, "AXFullScreen") as? Bool == false else { return false }
        var size = frame.size, point = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &point) else { return false }
        guard !requireFocus || isFocused(element) else { return false }
        // Move onto the destination before requesting its larger size, then
        // correct any position adjustment caused by the application's resize.
        guard AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) == .success,
              AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) == .success,
              AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) == .success else { return false }
        guard let actualP = value(element, kAXPositionAttribute), CFGetTypeID(actualP) == AXValueGetTypeID(),
              let actualS = value(element, kAXSizeAttribute), CFGetTypeID(actualS) == AXValueGetTypeID() else { return false }
        var actualPoint = CGPoint.zero, actualSize = CGSize.zero
        return AXValueGetValue(actualP as! AXValue, .cgPoint, &actualPoint) && AXValueGetValue(actualS as! AXValue, .cgSize, &actualSize) && actualPoint == point && actualSize == size
    }
}
