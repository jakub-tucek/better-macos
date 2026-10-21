import AppKit

private final class ShortcutTestRegistration: WindowShortcutRegistering {
    var callback: ((WindowShortcutAction) -> Void)?
    var succeeds = true
    var starts = 0
    var stops = 0
    func start(_ perform: @escaping (WindowShortcutAction) -> Void) -> Bool {
        starts += 1; callback = perform; return succeeds
    }
    func stop() { stops += 1; callback = nil }
}

private final class ShortcutTestBackend: WindowPositionBackend {
    var permitted = true
    var screens = [WindowDisplay(id: "main", bounds: CGRect(x: 0, y: 25, width: 1200, height: 800))]
    var focused: PositionedWindow? = PositionedWindow(token: "one", app: "test.app", title: "Document",
        frame: CGRect(x: 100, y: 100, width: 600, height: 400), supported: true)
    var writes: [CGRect] = []
    var succeeds = true
    var beforeFocus: (() -> Void)?
    func requestPermission() {}
    func displays() -> [WindowDisplay] { screens }
    func windows() throws -> [PositionedWindow] { focused.map { [$0] } ?? [] }
    func focusedWindow() throws -> PositionedWindow? { beforeFocus?(); return focused }
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        writes.append(frame)
        if succeeds { focused?.frame = frame }
        return succeeds
    }
}

func runWindowShortcutTests() {
    let main = WindowDisplay(id: "main", bounds: CGRect(x: 0, y: 25, width: 1201, height: 801))
    let left = WindowDisplay(id: "left", bounds: CGRect(x: -900, y: -500, width: 900, height: 700))
    let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
    let lhs = WindowShortcutAction.left.destination(for: frame, displays: [main])!
    let rhs = WindowShortcutAction.right.destination(for: frame, displays: [main])!
    expect(lhs.maxX == rhs.minX && lhs.union(rhs) == main.bounds, "shortcut halves fill odd-sized work areas without gaps")
    let quarters: [WindowShortcutAction] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    let tiles = quarters.compactMap { $0.destination(for: frame, displays: [main]) }
    expect(tiles.count == 4 && tiles.reduce(CGRect.null) { $0.union($1) } == main.bounds,
           "shortcut quarters fill usable area below menu bar")
    for index in tiles.indices {
        expect(tiles.indices.filter { $0 != index }.allSatisfy { tiles[index].intersection(tiles[$0]).isEmpty },
               "shortcut quarters never overlap")
    }
    expect(WindowShortcutAction.maximize.destination(for: frame, displays: [main]) == main.bounds,
           "maximize uses work area rather than full-screen mode")
    let centered = WindowShortcutAction.center.destination(for: frame, displays: [main])!
    expect(centered.size == frame.size && centered.midX == main.bounds.midX && centered.midY == main.bounds.midY,
           "center preserves size within work area")
    let moved = WindowShortcutAction.nextDisplay.destination(for: frame, displays: [main, left])!
    expect(left.bounds.contains(moved) && moved.size == frame.size,
           "next display wraps spatial order and preserves size on negative-origin display")
    expect(WindowShortcutAction.previousDisplay.destination(for: frame, displays: [left, main]) == moved,
           "two-display previous direction is independent of enumeration order")
    expect(WindowShortcutAction.nextDisplay.destination(for: frame, displays: [main]) == nil,
           "single display has no next destination")
    expect(WindowShortcutAction.left.destination(for: frame, displays: []) == nil,
           "missing displays block window shortcuts")
    expect(WindowShortcutAction.left.destination(for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1), displays: [main]) == nil,
           "nonfinite window geometry is rejected")
    expect(WindowShortcutAction.left.destination(for: frame, displays: [WindowDisplay(id: "bad", bounds: .zero)]) == nil,
           "invalid display geometry is rejected")
    let restored = WindowShortcutAction.restore.destination(for: frame, displays: [main], original: left.bounds)!
    expect(main.bounds.contains(restored), "restore clamps to remaining display after disconnect")
    expect(Set(WindowShortcutAction.allCases.map { "\($0.key):\($0.modifiers)" }).count == WindowShortcutAction.allCases.count,
           "window shortcut preset contains no internal conflicts")

    let domain = "window-shortcut-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let backend = ShortcutTestBackend(), registration = ShortcutTestRegistration()
    var scheduled: [() -> Void] = []
    let owner = WindowPositions(backend: backend, defaults: defaults, shortcuts: registration, schedule: { scheduled.append($0) })
    expect(!owner.shortcutsEnabled && registration.starts == 0, "new window shortcut preference is opt-in")
    owner.shortcutsEnabled = true
    expect(registration.starts == 0, "shortcut registration waits for host readiness")
    owner.reconcile(ready: true, settled: true)
    expect(registration.starts == 1 && owner.shortcutsActive, "ready owner registers shortcut preset")
    let queued = registration.callback
    registration.callback?(.left)
    expect(backend.writes.last == CGRect(x: 0, y: 25, width: 600, height: 800), "registered callback moves focused window")
    registration.callback?(.maximize)
    registration.callback?(.restore)
    expect(backend.writes.last == frame, "restore retains original frame across consecutive tiling actions")
    let count = backend.writes.count
    owner.acceptsActions = { false }
    queued?(.right)
    owner.shortcutsEnabled = false
    expect(backend.writes.count == count && owner.shortcutsEnabled, "host closure blocks shortcut execution and preference mutations")
    owner.acceptsActions = { true }
    owner.exclusions = "test.app"
    queued?(.right)
    expect(backend.writes.count == count, "window exclusions apply to keyboard tiling")
    owner.exclusions = ""
    backend.focused?.supported = false
    queued?(.right)
    expect(backend.writes.count == count, "unsupported focused windows are not moved")
    backend.focused?.supported = true
    backend.permitted = false
    queued?(.right)
    expect(backend.writes.count == count, "revoked permission blocks an already delivered shortcut")
    backend.permitted = true
    owner.invalidate()
    queued?(.right)
    expect(!owner.shortcutsActive && registration.callback == nil && backend.writes.count == count,
           "display invalidation unregisters keys and blocks stale callbacks")
    registration.succeeds = false
    owner.reconcile(ready: true, settled: true)
    expect(!owner.shortcutsActive && owner.shortcutsEnabled && owner.shortcutStatus.contains("unavailable"),
           "conflicting shortcut registration retains preference and reports retryable failure")
    registration.succeeds = true
    owner.retryShortcuts()
    expect(owner.shortcutsActive, "shortcut registration can retry after external conflict is removed")
    backend.succeeds = false
    registration.callback?(.right)
    expect(owner.shortcutStatus.contains("could not"), "failed or size-constrained move is reported without a success claim")
    backend.succeeds = true
    registration.callback?(.restore)
    expect(backend.writes.last == frame, "a failed move preserves original geometry for an explicit restore")
    owner.save("Fixture layout")
    owner.restore(owner.layouts[0].id)
    expect(!scheduled.isEmpty, "layout fixture has a queued move before keyboard tiling")
    registration.callback?(.center)
    let manualCount = backend.writes.count
    while !scheduled.isEmpty { scheduled.removeFirst()() }
    expect(backend.writes.count == manualCount, "manual shortcut supersedes queued layout restoration")
    var focusReads = 0
    backend.beforeFocus = {
        focusReads += 1
        if focusReads == 2 { backend.focused?.token = "another-window" }
    }
    registration.callback?(.left)
    backend.beforeFocus = nil
    expect(focusReads == 2 && backend.writes.count == manualCount, "focus change between discovery and write refuses the stale target")
    owner.shortcutsEnabled = false
    let disabledCount = backend.writes.count
    queued?(.left)
    expect(!owner.shortcutsActive && backend.writes.count == disabledCount, "shortcut opt-out unregisters and blocks stale callbacks")
    owner.shortcutsEnabled = true
    owner.stop()
    queued?(.left)
    expect(!owner.shortcutsActive && backend.writes.count == disabledCount, "stopped owner rejects shortcut work")
    expect(defaults.bool(forKey: "windows.shortcuts"), "stopping owner preserves explicit shortcut preference")
}
