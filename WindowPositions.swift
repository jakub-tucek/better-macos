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

protocol WindowPositionBackend: AnyObject {
    var permitted: Bool { get }
    func requestPermission()
    func displays() -> [WindowDisplay]
    func windows() -> [PositionedWindow]
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool
}

/// Main-thread coordinator. Each write yields to lifecycle notifications and checks its generation.
final class WindowPositions: ObservableObject {
    @Published private(set) var layouts: [WindowLayout] = []
    @Published var summary = "Save a named layout to begin."
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "windows.auto"); pending = false; generation += 1 } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "windows.paused"); pending = false; generation += 1 } }
    @Published var exclusions: String { didSet { defaults.set(exclusions, forKey: "windows.exclusions"); generation += 1 } }
    @Published var selected: String { didSet { defaults.set(selected, forKey: "windows.selected") } }
    @Published private(set) var ready = false
    private let backend: WindowPositionBackend
    private let defaults: UserDefaults
    private let schedule: (@escaping () -> Void) -> Void
    private var generation = 0
    private var pending = false
    private var lastDisplaySet: [String]?
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var observingConnections = false
    var onWake: (() -> Void)?

    init(backend: WindowPositionBackend = AXWindowPositionBackend(), defaults: UserDefaults = .standard,
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.backend = backend; self.defaults = defaults
        self.schedule = schedule
        automatic = defaults.bool(forKey: "windows.auto")
        paused = defaults.bool(forKey: "windows.paused")
        exclusions = defaults.string(forKey: "windows.exclusions") ?? ""
        selected = defaults.string(forKey: "windows.selected") ?? ""
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
        observingConnections = CGDisplayRegisterReconfigurationCallback(windowConnectionChanged, Unmanaged.passUnretained(self).toOpaque()) == .success
    }
    func stop() {
        stopped = true; invalidate()
        onWake = nil
        if observingConnections {
            CGDisplayRemoveReconfigurationCallback(windowConnectionChanged, Unmanaged.passUnretained(self).toOpaque())
            observingConnections = false
        }
        let center = NSWorkspace.shared.notificationCenter
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let sleepObserver { center.removeObserver(sleepObserver) }
        wakeObserver = nil; sleepObserver = nil
    }
    deinit { stop() }
    func invalidate() { ready = false; pending = false; generation += 1 }
    func wake() { invalidate(); pending = automatic && !paused }
    func connectionChanged() { wake(); onWake?() }
    func reconcile(ready: Bool, settled: Bool) {
        if !ready { generation += 1 }
        self.ready = ready && !stopped
        guard settled, !stopped else { return }
        let ids = backend.displays().map(\.id).sorted()
        if let previous = lastDisplaySet, previous != ids { pending = automatic && !paused }
        lastDisplaySet = ids
        guard self.ready, pending else { return }
        pending = false
        guard automatic, !paused else { return }
        let candidates = layouts.filter { $0.displays.map(\.id).sorted() == ids }
        if let layout = candidates.first(where: { $0.id == selected }) ?? (candidates.count == 1 ? candidates.first : nil) {
            restore(layout.id)
        } else { summary = "No unique saved layout for this display set; select one." }
    }
    func requestPermission() { backend.requestPermission() }
    private var excluded: Set<String> { Set(exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) }
    private func persist() { if let data = try? JSONEncoder().encode(layouts) { defaults.set(data, forKey: "windows.layouts") } }
    func delete(_ id: String) { generation += 1; layouts.removeAll { $0.id == id }; persist(); if selected == id { selected = "" } }
    func save(_ name: String) {
        guard ready, backend.permitted else { summary = "Wait for stable displays and grant Accessibility access."; return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { summary = "Enter a layout name."; return }
        let displays = backend.displays()
        guard !displays.isEmpty else { summary = "No available displays."; return }
        let windows = backend.windows().filter { !excluded.contains($0.app) }.compactMap { window -> PositionedWindow? in
            guard let display = displays.max(by: { $0.bounds.intersection(window.frame).area < $1.bounds.intersection(window.frame).area }), display.bounds.intersects(window.frame) else { return nil }
            var saved = window; saved.display = display.id
            saved.frame.origin.x -= display.bounds.minX; saved.frame.origin.y -= display.bounds.minY
            return saved
        }
        let layout = WindowLayout(name: name, displays: displays, windows: windows)
        layouts.append(layout); selected = layout.id; persist()
        summary = "Saved \(windows.count) windows in \(name)."
    }
    func restore(_ id: String) {
        generation += 1
        let ticket = generation
        pending = false
        guard ready, !stopped, backend.permitted else { summary = "Wait for stable displays and grant Accessibility access."; return }
        guard let layout = layouts.first(where: { $0.id == id }) else { return }
        let displays = backend.displays()
        guard displays.map(\.id).sorted() == layout.displays.map(\.id).sorted() else { summary = "Saved display set is not connected."; return }
        let current = backend.windows()
        var moved = 0, missing = 0, ambiguous = 0, unsupported = 0, failed = 0, skipped = 0
        var writes: [(PositionedWindow, CGRect)] = []
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
            writes.append((matches[0], frame))
        }
        func publish() {
            summary = "Restored \(moved); missing \(missing); ambiguous \(ambiguous); unsupported \(unsupported); excluded \(skipped); failed \(failed)."
        }
        func step(_ index: Int) {
            guard ticket == generation, ready, !stopped, backend.permitted, backend.displays() == displays else {
                summary = "Restore canceled after \(moved) windows; display state, permission, or settings changed."
                return
            }
            guard index < writes.count else { publish(); return }
            if backend.move(writes[index].0, to: writes[index].1) { moved += 1 } else { failed += 1 }
            schedule { [weak self] in guard self != nil else { return }; step(index + 1) }
        }
        if writes.isEmpty { publish() }
        else { schedule { [weak self] in guard self != nil else { return }; step(0) } }
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

private let windowConnectionChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard flags.contains(.addFlag) || flags.contains(.removeFlag), let context else { return }
    let module = Unmanaged<WindowPositions>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { [weak module] in module?.connectionChanged() }
}

final class AXWindowPositionBackend: WindowPositionBackend {
    private var elements: [String: AXUIElement] = [:]
    var permitted: Bool { AXIsProcessTrusted() }
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
    func windows() -> [PositionedWindow] {
        var nextElements: [String: AXUIElement] = [:]
        defer { elements = nextElements }
        guard permitted else { return [] }
        let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        let visiblePIDs = Set(visible.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var incomplete = false
        let result = NSWorkspace.shared.runningApplications.flatMap { app -> [PositionedWindow] in
            if ProcessInfo.processInfo.systemUptime >= deadline { incomplete = true; return [] }
            guard ProcessInfo.processInfo.systemUptime < deadline, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let bundle = app.bundleIdentifier, visiblePIDs.contains(app.processIdentifier) else { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
            let records = windows.compactMap { window -> PositionedWindow? in
                guard ProcessInfo.processInfo.systemUptime < deadline else { incomplete = true; return nil }
                AXUIElementSetMessagingTimeout(window, 0.05)
                guard let p = value(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                      let s = value(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
                let title = value(window, kAXTitleAttribute) as? String ?? ""
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
            return records.map { record in
                var record = record
                if records.count != windows.count || !Self.hasUniqueGeometry(record.frame, in: records.map(\.frame)) { record.supported = false }
                return record
            }
        }
        return incomplete ? [] : result
    }
    static func hasUniqueGeometry(_ frame: CGRect, in frames: [CGRect]) -> Bool {
        frames.filter { $0 == frame }.count == 1
    }
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        guard permitted, let element = elements[window.token] else { return false }
        let fresh = windows().filter { $0.app == window.app && $0.title == window.title }
        guard fresh.count == 1, fresh[0].supported, let freshElement = elements[fresh[0].token], CFEqual(element, freshElement) else { return false }
        guard value(element, kAXTitleAttribute) as? String == window.title,
              value(element, kAXMinimizedAttribute) as? Bool == false,
              value(element, "AXFullScreen") as? Bool == false else { return false }
        var size = frame.size, point = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &point) else { return false }
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
