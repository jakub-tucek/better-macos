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

/// Main-thread coordinator. No delayed AX writes: every restore uses a fresh snapshot.
final class WindowPositions: ObservableObject {
    @Published private(set) var layouts: [WindowLayout] = []
    @Published var summary = "Save a named layout to begin."
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "windows.auto"); pending = false } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "windows.paused"); pending = false } }
    @Published var exclusions: String { didSet { defaults.set(exclusions, forKey: "windows.exclusions") } }
    @Published var selected: String { didSet { defaults.set(selected, forKey: "windows.selected") } }
    @Published private(set) var ready = false
    private let backend: WindowPositionBackend
    private let defaults: UserDefaults
    private var pending = false
    private var lastDisplaySet: [String]?
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    var onWake: (() -> Void)?

    init(backend: WindowPositionBackend = AXWindowPositionBackend(), defaults: UserDefaults = .standard) {
        self.backend = backend; self.defaults = defaults
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
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.invalidate() }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wake(); self?.onWake?()
        }
    }
    func stop() {
        stopped = true; invalidate()
        let center = NSWorkspace.shared.notificationCenter
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let sleepObserver { center.removeObserver(sleepObserver) }
        wakeObserver = nil; sleepObserver = nil
    }
    deinit { stop() }
    func invalidate() { ready = false; pending = false }
    func wake() { invalidate(); pending = automatic && !paused }
    func reconcile(ready: Bool, settled: Bool) {
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
    func delete(_ id: String) { layouts.removeAll { $0.id == id }; persist(); if selected == id { selected = "" } }
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
        pending = false
        guard ready, !stopped, backend.permitted else { summary = "Wait for stable displays and grant Accessibility access."; return }
        guard let layout = layouts.first(where: { $0.id == id }) else { return }
        let displays = backend.displays()
        guard displays.map(\.id).sorted() == layout.displays.map(\.id).sorted() else { summary = "Saved display set is not connected."; return }
        let current = backend.windows()
        var moved = 0, missing = 0, ambiguous = 0, unsupported = 0, failed = 0, skipped = 0
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
            if backend.move(matches[0], to: frame) { moved += 1 } else { failed += 1 }
        }
        summary = "Restored \(moved); missing \(missing); ambiguous \(ambiguous); unsupported \(unsupported); excluded \(skipped); failed \(failed)."
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

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
        elements = [:]
        guard permitted else { return [] }
        let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        let visiblePIDs = Set(visible.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        return NSWorkspace.shared.runningApplications.flatMap { app -> [PositionedWindow] in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let bundle = app.bundleIdentifier, visiblePIDs.contains(app.processIdentifier) else { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
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
                let token = UUID().uuidString; elements[token] = window
                return PositionedWindow(token: token, app: bundle, title: title, frame: frame, supported: supported)
            }
        }
    }
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        guard permitted, let element = elements[window.token] else { return false }
        var size = frame.size, point = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &point) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) == .success,
              AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) == .success else { return false }
        guard let actualP = value(element, kAXPositionAttribute), CFGetTypeID(actualP) == AXValueGetTypeID(),
              let actualS = value(element, kAXSizeAttribute), CFGetTypeID(actualS) == AXValueGetTypeID() else { return false }
        var actualPoint = CGPoint.zero, actualSize = CGSize.zero
        return AXValueGetValue(actualP as! AXValue, .cgPoint, &actualPoint) && AXValueGetValue(actualS as! AXValue, .cgSize, &actualSize) && actualPoint == point && actualSize == size
    }
}
