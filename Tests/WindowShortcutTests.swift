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

func renderWindowActionPaletteFixtures(directory: String) throws {
    _ = NSApplication.shared
    let domain = "window-palette-fixtures-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let owner = WindowPositions(backend: ShortcutTestBackend(), defaults: defaults, shortcuts: ShortcutTestRegistration())
    owner.reconcile(ready: true, settled: true)
    let controller = WindowActionPaletteController()
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for dark in [false, true] {
        for compact in [false, true] {
            let panel = controller.show(owner: owner, target: owner.captureActionTarget(), orderFront: false)
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if compact { panel.setContentSize(NSSize(width: 600, height: 420)) }
            for _ in 0..<4 {
                panel.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let view = panel.contentView!
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("window-palette-\(compact ? "compact" : "full")-\(dark ? "dark" : "light").png"))
            controller.dismiss()
        }
    }
    owner.stop()
}

private func runWindowActionPaletteTests() {
    let domain = "window-palette-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let backend = ShortcutTestBackend(), registration = ShortcutTestRegistration()
    let owner = WindowPositions(backend: backend, defaults: defaults, shortcuts: registration, schedule: { $0() })
    expect(WindowActionPaletteState.actions.count == WindowShortcutAction.allCases.count - 1 &&
           Set(WindowActionPaletteState.actions) == Set(WindowShortcutAction.allCases.filter { $0 != .showActions }),
           "palette exposes every movement action exactly once")
    expect(owner.captureActionTarget() == nil, "palette target requires host readiness")
    owner.reconcile(ready: true, settled: true)
    let original = backend.focused!.frame
    let target = owner.captureActionTarget()!
    expect(!owner.shortcutsEnabled && backend.writes.isEmpty, "menu palette captures a target without enabling hotkeys or moving windows")
    owner.reconcile(ready: true, settled: true)
    expect(owner.applyAction(.firstThird, to: target), "menu palette can apply through owner while global hotkeys are off")
    owner.shortcutsEnabled = true
    owner.performShortcut(.restore)
    expect(backend.writes.last == original, "keyboard Restore shares original geometry with palette actions")
    var openings = 0
    owner.onShowActions = { openings += 1 }
    let count = backend.writes.count
    registration.callback?(.showActions)
    expect(openings == 1 && backend.writes.count == count, "registered palette hotkey requests presentation without moving a window")
    let captured = owner.captureActionTarget()!
    backend.focused?.token = "other"
    expect(!owner.applyAction(.right, to: captured) && backend.writes.count == count, "palette never substitutes a newly focused window")
    backend.focused?.token = captured.window.token
    backend.screens[0].bounds.size.width += 1
    expect(!owner.applyAction(.right, to: captured) && backend.writes.count == count, "palette refuses a changed display snapshot")
    backend.screens = captured.displays
    owner.acceptsActions = { false }
    expect(!owner.applyAction(.right, to: captured) && backend.writes.count == count, "host closure blocks captured palette actions")
    owner.acceptsActions = { true }
    owner.exclusions = "test.app"
    expect(!owner.applyAction(.right, to: captured) && backend.writes.count == count, "palette respects current exclusions after opening")
    owner.exclusions = ""
    owner.invalidate(); owner.reconcile(ready: true, settled: true)
    expect(!owner.applyAction(.right, to: captured) && backend.writes.count == count, "readiness recovery cannot revive an old palette target")

    let controller = WindowActionPaletteController()
    let panel = controller.show(owner: owner, target: owner.captureActionTarget(), orderFront: false)
    expect(panel.styleMask.contains(.nonactivatingPanel) && panel.canBecomeKey && !panel.canBecomeMain,
           "palette uses a key-capable nonactivating native panel")
    func key(_ code: UInt16, _ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        panel.sendEvent(event)
    }
    key(124, "\u{f703}")
    expect(backend.writes.count == count, "palette arrow-key preview performs no window write")
    key(36, "\r")
    expect(backend.writes.last == WindowShortcutAction.right.destination(for: original, displays: backend.screens),
           "native palette Right then Return executes the selected action through the owner")
    let afterApply = backend.writes.count
    let canceled = controller.show(owner: owner, target: owner.captureActionTarget(), orderFront: false)
    expect(controller.isPresented, "Escape fixture starts with an owned palette presentation")
    canceled.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: canceled.windowNumber, context: nil, characters: "\u{1b}",
                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
    expect(backend.writes.count == afterApply && !controller.isPresented, "Escape dismisses the palette without a move")
    owner.stop()
}

func runWindowShortcutTests() {
    runShortcutSessionTests()
    runWindowActionPaletteTests()
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
    let thirds = [WindowShortcutAction.firstThird, .middleThird, .lastThird].compactMap { $0.destination(for: frame, displays: [main]) }
    expect(thirds.count == 3 && thirds[0].maxX == thirds[1].minX && thirds[1].maxX == thirds[2].minX && thirds.reduce(CGRect.null) { $0.union($1) } == main.bounds,
           "thirds partition odd-sized work areas exactly without gaps or overlap")
    expect(WindowShortcutAction.firstTwoThirds.destination(for: frame, displays: [main]) == thirds[0].union(thirds[1]) &&
           WindowShortcutAction.lastTwoThirds.destination(for: frame, displays: [main]) == thirds[1].union(thirds[2]),
           "two-thirds actions use the same exact partition boundaries")
    let almost = WindowShortcutAction.almostMaximize.destination(for: frame, displays: [main])!
    expect(main.bounds.contains(almost) && almost.midX == main.bounds.midX && almost.midY == main.bounds.midY && almost.width < main.bounds.width,
           "almost maximize leaves centered margins inside usable screen bounds")
    expect(WindowShortcutAction.showActions.destination(for: frame, displays: [main]) == nil,
           "opening the action palette has no window movement destination")

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
    owner.acceptsActions = { false }
    let closedStarts = registration.starts
    owner.shortcutsEnabled = true
    owner.retryShortcuts()
    expect(!owner.shortcutsEnabled && registration.starts == closedStarts, "closed host blocks opt-in and retry while shortcuts are off")
    owner.acceptsActions = { true }
    owner.shortcutsEnabled = true
    backend.focused?.token = "one"
    owner.stop()
    queued?(.left)
    expect(!owner.shortcutsActive && backend.writes.count == disabledCount, "stopped owner rejects shortcut work")
    expect(defaults.bool(forKey: "windows.shortcuts"), "stopping owner preserves explicit shortcut preference")
    let stoppedStarts = registration.starts
    owner.reconcile(ready: true, settled: true)
    owner.retryShortcuts()
    owner.shortcutsEnabled = false
    expect(registration.starts == stoppedStarts && owner.shortcutsEnabled, "stopped owner cannot register, retry or change opt-in")
    owner.start()
    owner.reconcile(ready: true, settled: true)
    let restartCount = backend.writes.count
    registration.callback?(.restore)
    expect(backend.writes.count == restartCount && owner.shortcutStatus.contains("No original"), "owner stop and restart clear session frames")
    owner.stop()
}

/// Resource facts and traces only; production registration owns preset/rollback.
private final class ShortcutNativeFake: WindowShortcutNativeAccess {
    var trace: [String] = []
    var failInstall = false
    var failKey: UInt32?
    var resourceOnFailure = false
    var onInstall: (() -> Void)?
    var callback: ((WindowShortcutAction) -> Void)?
    func install(_ perform: @escaping (WindowShortcutAction) -> Void) -> (Bool, Int?) {
        trace.append("install"); callback = perform
        onInstall?()
        return (!failInstall, !failInstall || resourceOnFailure ? 99 : nil)
    }
    func register(_ action: WindowShortcutAction) -> (Bool, UInt32?) {
        trace.append("key\(action.rawValue)")
        let succeeds = failKey != action.rawValue
        return (succeeds, succeeds || resourceOnFailure ? action.rawValue : nil)
    }
    func clearCallback() { trace.append("clear"); callback = nil }
    func unregister(_ key: UInt32) { trace.append("release\(key)") }
    func remove(_ handler: Int) { trace.append("remove\(handler)") }
}

private func runShortcutSessionTests() {
    for nth in 1...WindowShortcutAction.allCases.count {
        for returnsResource in [false, true] {
            let native = ShortcutNativeFake()
            native.failKey = UInt32(nth); native.resourceOnFailure = returnsResource
            let registration = WindowShortcutPresetRegistration(native: native)
            expect(!registration.start { _ in }, "nth-key failure refuses the entire preset")
            let released = returnsResource ? nth : nth - 1
            let expected = ["clear", "install"] + (1...nth).map { "key\($0)" } + ["clear"] +
                (0..<released).map { "release\($0 + 1)" } + ["remove99"]
            expect(native.trace == expected && native.callback == nil, "nth-key rollback clears callback then every acquired key then handler")
        }
    }
    for returnsResource in [false, true] {
        let native = ShortcutNativeFake()
        native.failInstall = true; native.resourceOnFailure = returnsResource
        let registration = WindowShortcutPresetRegistration(native: native)
        expect(!registration.start { _ in }, "handler install failure refuses preset")
        expect(native.trace == ["clear", "install", "clear"] + (returnsResource ? ["remove99"] : []),
               "install failure cleans any returned handler without registering keys")
        native.failInstall = false; native.trace = []
        expect(registration.start { _ in }, "production preset retries after failed install")
        native.trace = []; registration.stop()
        expect(native.trace == ["clear"] + WindowShortcutAction.allCases.map { "release\($0.rawValue)" } + ["remove99"],
               "successful preset stop releases all keys before handler")
        native.trace = []; registration.stop()
        expect(native.trace == ["clear"], "preset stop is resource-idempotent")
        expect(registration.start { _ in }, "successful preset can restart after stop")
    }

    let backend = ShortcutTestBackend(), native = ShortcutNativeFake()
    let registration = WindowShortcutPresetRegistration(native: native)
    let session = WindowShortcutSession(backend: backend, registration: registration)
    var admitted = true
    session.admitsAction = { admitted }; session.isExcluded = { _ in false }
    native.failKey = 3
    session.reconcile(enabled: true, admitted: true)
    let failedTrace = native.trace
    session.reconcile(enabled: true, admitted: true)
    expect(!session.active && session.status.contains("unavailable") && native.trace == failedTrace,
           "failed production registration suppresses repeated attempts until retry")
    native.failKey = nil
    session.retry(enabled: true, admitted: true)
    expect(session.active, "session retry registers entire production preset after key conflict clears")
    session.reconcile(enabled: true, admitted: true)
    let stale = native.callback
    session.invalidate(); session.reconcile(enabled: true, admitted: true)
    stale?(.left)
    expect(session.active && backend.writes.isEmpty, "old callback cannot act after successful re-registration")
    native.callback?(.left)
    expect(backend.writes.count == 1, "new callback acts after successful re-registration")
    admitted = false
    native.callback?(.right)
    expect(backend.writes.count == 1, "session callback rechecks current admission")
    admitted = true
    session.stop(); session.reconcile(enabled: true, admitted: true)
    let original = CGRect(x: 100, y: 100, width: 600, height: 400)
    backend.succeeds = false; backend.focused?.frame = original
    native.callback?(.right)
    session.invalidate(); session.reconcile(enabled: true, admitted: true)
    native.callback?(.restore)
    expect(session.status.contains("could not"), "failed restore after invalidation keeps original available")
    backend.succeeds = true
    backend.screens = [WindowDisplay(id: "changed", bounds: CGRect(x: 0, y: 25, width: 500, height: 300))]
    native.callback?(.restore)
    expect(backend.writes.last == CGRect(x: 0, y: 25, width: 500, height: 300),
           "failed move retains original and production restore fits changed display geometry")
    let restoredCount = backend.writes.count
    native.callback?(.restore)
    expect(backend.writes.count == restoredCount, "successful restore consumes original")

    backend.screens = [WindowDisplay(id: "main", bounds: CGRect(x: 0, y: 25, width: 1200, height: 800))]
    // Insert in reverse lexical order: eviction is lexical, not insertion/LRU.
    for index in (0..<64).reversed() {
        backend.focused?.token = String(format: "%03d", index); backend.focused?.frame = original
        native.callback?(.left)
    }
    backend.focused?.token = "extra"; backend.focused?.frame = original
    native.callback?(.right)
    backend.focused?.token = "000"
    let cappedCount = backend.writes.count
    native.callback?(.restore)
    expect(backend.writes.count == cappedCount && session.status.contains("No original"), "64-frame cap evicts lexical minimum rather than oldest insertion")
    backend.focused?.token = "001"
    native.callback?(.restore)
    expect(backend.writes.last == original && backend.writes.count == cappedCount + 1, "cap preserves next lexical original")
    backend.focused?.token = "063"
    native.callback?(.restore)
    expect(backend.writes.count == cappedCount + 2, "cap preserves earliest inserted frame when not lexical minimum")
    session.stop(); session.reconcile(enabled: true, admitted: true)
    backend.focused?.token = "extra"
    let stoppedCount = backend.writes.count
    native.callback?(.restore)
    expect(backend.writes.count == stoppedCount, "session stop clears originals across restart")

    backend.beforeFocus = { session.invalidate(); session.reconcile(enabled: true, admitted: true) }
    session.perform(.left)
    backend.beforeFocus = nil
    expect(session.active && backend.writes.count == stoppedCount, "generation change during discovery cannot reopen canceled shortcut work")
    session.beforeMove = { session.invalidate(); session.reconcile(enabled: true, admitted: true) }
    session.perform(.left)
    session.beforeMove = {}
    expect(session.active && backend.writes.count == stoppedCount, "owner cancellation callback cannot reopen an invalidated action")
    session.invalidate()
    native.onInstall = { session.invalidate() }
    session.reconcile(enabled: true, admitted: true)
    native.onInstall = nil
    expect(!session.active && native.callback == nil && native.trace.last == "remove99",
           "invalidation during registration cannot publish success or retain newly acquired resources")
    session.reconcile(enabled: true, admitted: true)
    expect(session.active, "canceled registration permits a fresh admitted attempt")
}
