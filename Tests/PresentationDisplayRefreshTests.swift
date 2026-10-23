import AppKit
import SwiftUI

private struct PresentationLogin: LoginServicing {
    var status: LoginStatus { .notRegistered }
    func register() throws { fatalError("Presentation cannot register login") }
    func unregister() throws { fatalError("Presentation cannot unregister login") }
    func openSettings() { fatalError("Presentation cannot open system settings") }
}

private final class PresentationDisplayRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        precondition(arguments == ["--restore"], "Only injected display recovery is permitted")
        return ""
    }
}

private func presentationViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(presentationViews)
}

private func presentationEvents(until ready: () -> Bool, timeout: TimeInterval = 0.5, afterDispatch: (NSEvent) -> Void = { _ in }) {
    let deadline = Date().addingTimeInterval(timeout)
    while !ready() && Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: min(deadline, Date().addingTimeInterval(0.01)), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
            afterDispatch(event)
        }
        NSApp.updateWindows()
    }
}

private func presentationWindowBounds(_ window: NSWindow) -> CGRect? {
    // Query only this fixture's window, never another application's inventory.
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]])?.first,
          let values = info[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: values as CFDictionary),
          bounds.width > 0, bounds.height > 0 else { return nil }
    return bounds
}

private func presentationClick(_ view: NSView, at point: NSPoint) {
    guard let window = view.window else { expect(false, "presentation click has a fixture window"); return }
    let intendedLocation = view.convert(point, to: nil)
    presentationEvents(until: { presentationWindowBounds(window) != nil })
    guard let bounds = presentationWindowBounds(window), let screenTop = NSScreen.screens.first?.frame.maxY else {
        expect(false, "native fixture window has server geometry before a click"); return
    }
    // In a locked session WindowServer can scale/translate even an invisible
    // popup. NSEvent's factory uses logical coordinates, but nextEvent converts
    // its CG screen location through that server transform. Target the rendered
    // fixture, then verify the dequeued event still reaches the intended point.
    let physical = NSPoint(x: bounds.minX + intendedLocation.x / window.frame.width * bounds.width,
        y: screenTop - bounds.minY - (window.frame.height - intendedLocation.y) / window.frame.height * bounds.height)
    let location = window.convertPoint(fromScreen: physical)
    let time = ProcessInfo.processInfo.systemUptime
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.001,
        windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    var delivered = 0
    func record(_ event: NSEvent) {
        let actual = event.locationInWindow
        // WindowServer bounds are integral pixels; allow only their rounding,
        // far less than the switch's 22-point height. Never retry a missed click.
        expect(abs(actual.x - intendedLocation.x) < 2 && abs(actual.y - intendedLocation.y) < 2,
            "native fixture \(event.type) arrives at its intended control point (\(actual), expected \(intendedLocation))")
        delivered += 1
    }
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
        guard event.window === window else { return event }
        record(event)
        return event
    }!
    defer { NSEvent.removeMonitor(monitor) }
    // SwiftUI needs currentEvent from nextEvent, not direct mouseDown dispatch.
    NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false)
    presentationEvents(until: { delivered == 2 }, afterDispatch: { event in
        // NSSwitch consumes mouse-up inside its native tracking loop. That event
        // becomes currentEvent without passing through the outer local monitor.
        if event.type == .leftMouseDown, delivered == 1, let tracked = NSApp.currentEvent,
           tracked.type == .leftMouseUp, tracked.window === window, tracked.eventNumber == up.eventNumber {
            record(tracked)
        }
    })
    expect(delivered == 2, "native fixture dispatches exactly one mouse-down/up pair")
}

/// Real production popup/Settings, fixture-owned invisible anchor, injected
/// discovery/actions only. Never starts the application, watchdog or live owners.
private func runStatusQuickMenuTests() {
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    let controller = StatusQuickMenuController()
    var actions: [StatusQuickAction] = []
    let first = controller.show(relativeTo: anchor, windowsEnabled: true, orderFront: false) { actions.append($0) }
    let content = first.contentView
    expect(first.animationBehavior == .none && first.styleMask.contains(.nonactivatingPanel),
           "quick panel disables window animations and does not activate the app")
    var reused = true
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<50 {
        controller.dismiss()
        let next = controller.show(relativeTo: anchor, windowsEnabled: true, orderFront: false) { actions.append($0) }
        reused = reused && next === first && next.contentView === content && next.contentLayoutRect.size == StatusQuickMenuController.size
    }
    print("Quick panel: 50 cached show/dismiss cycles in \(ProcessInfo.processInfo.systemUptime - start)s (hidden native fixture)")
    expect(reused, "repeated right-click presentation retains one hosting tree and stable geometry")
    expect(actions.isEmpty, "opening and closing the quick panel never invokes an action")
    func key(_ code: UInt16, _ text: String) {
        first.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: first.windowNumber, context: nil, characters: text,
                                           charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
    }
    key(36, "\r")
    expect(actions == [.windows] && !controller.isPresented, "Return routes selected quick action exactly once after dismissal")
    key(36, "\r")
    expect(actions == [.windows], "a dismissed panel rejects stale keyboard activation")
    _ = controller.show(relativeTo: anchor, windowsEnabled: false, orderFront: false) { actions.append($0) }
    key(126, "\u{f700}"); key(36, "\r")
    expect(actions == [.windows, .quit], "keyboard traversal skips unavailable Window actions")
    _ = controller.show(relativeTo: anchor, windowsEnabled: true, orderFront: false) { actions.append($0) }
    key(53, "\u{1b}")
    expect(!controller.isPresented && actions.count == 2, "Escape dismisses quick menu without invoking a command")
}

func runPresentationDisplayRefreshTests() {
    _ = NSApplication.shared
    runPresentationGateTests()
    runStatusQuickMenuTests()
    let suite = "better-macos.presentation-display-refresh.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let modules = ModuleSettings(defaults: defaults)
    for module in AppModule.allCases { modules.set(module, enabled: false) }
    let mouse = MouseLifecycle(settings: modules, makeModule: { MouseModule(backend: FakeMouseBackend(), recovery: FakeMouseRecovery()) })
    let model = DashboardModel()
    model.widgetLayout = WidgetLayout(entries: [WidgetEntry(.displays)])
    // UI projection of an injected ready supervisor; the real safety owner is
    // never started or made ready. All monitor actions below are counters.
    model.watchdogReady = true
    var snapshots = 0
    var failSnapshot = false
    var windows: [NSWindow] = []
    let host = AppDelegate(commandRunner: PresentationDisplayRunner(), mouseLifecycle: mouse, model: model, preferences: defaults,
        presentWindow: { windows.append($0) }, displayRecoveryPending: { false }, displaySnapshotRefresh: {
            snapshots += 1
            if failSnapshot { throw ToggleError(message: "Injected display discovery failure") }
            model.monitors = [
                Monitor(uuid: "fixture-first", name: "First", id: 1, enabled: true, isMain: true, disabledByApp: false),
                Monitor(uuid: "fixture-second", name: "Second", id: 2, enabled: true, isMain: false, disabledByApp: false)
            ]
            model.activeMonitorCount = 2; model.displaySupported = true
         }, loginService: PresentationLogin(), diagnostics: Diagnostics())
    let anchorWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 60, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
    anchorWindow.isReleasedWhenClosed = false; anchorWindow.alphaValue = 0
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
    anchorWindow.contentView = anchor; anchorWindow.orderFront(nil)
    defer {
        model.onClose(); anchorWindow.close()
        for window in windows { window.close() }
        // Remove the actual screen observer and cancel the host's deferred work.
        model.onModuleChanged(.monitors, false)
        withExtendedLifetime(host) {}
    }
    func show() -> NSHostingView<QuickActionsView> {
        guard let root = host.presentDashboard(relativeTo: anchor) as? NSHostingView<QuickActionsView> else {
            fatalError("Production popup must return its own hosting view")
        }
        root.window?.alphaValue = 0
        var previousGeometry: [CGRect] = []
        var stablePasses = 0
        presentationEvents(until: {
            root.layoutSubtreeIfNeeded()
            guard presentationViews(root).contains(where: { ($0 as? NSScrollView)?.documentView != nil }),
                  let window = root.window, let serverBounds = presentationWindowBounds(window) else { return false }
            let geometry = [root.bounds, window.frame, serverBounds]
            stablePasses = geometry == previousGeometry ? stablePasses + 1 : 0
            previousGeometry = geometry
            return stablePasses >= 3
        })
        guard stablePasses >= 3 else {
            fatalError("Production popup must mount native scroll content and stabilize client/server geometry before interaction")
        }
        return root
    }
    func settle() {
        let deadline = Date().addingTimeInterval(3)
        while model.displaySettling && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(!model.displaySettling, "deferred fixture display discovery settles")
    }
    // The real module path registers the screen observer and requests startup
    // discovery; all other features are off and Mouse has an injected backend.
    model.onModuleChanged(.monitors, true)
    let cold = show()
    expect(model.displaySettling && snapshots == 0, "cold popup retains the pending initial display settle")
    settle()
    expect(snapshots == 1, "cold popup performs one coalesced initial snapshot")
    let quickMenu = host.presentStatusQuickMenu(relativeTo: anchor, orderFront: false)!
    expect(cold.window?.isVisible != true, "popup closes before right-click panel presentation")
    expect(snapshots == 1 && !model.displaySettling, "right-click presentation performs no new discovery or settling")
    func menuKey(_ code: UInt16, _ text: String) {
        quickMenu.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: quickMenu.windowNumber, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
    }
    let beforeSettings = windows.count
    // Windows is unavailable in this fixture: Quick actions is initially selected.
    menuKey(125, "\u{f701}"); menuKey(125, "\u{f701}"); menuKey(36, "\r")
    expect(windows.count == beforeSettings + 1, "native quick-panel Settings selection reaches production host presentation")
    model.onClose()

    var monitorActions = 0
    model.onMonitorChanged = { uuid, enabled in
        expect(uuid == "fixture-first" && !enabled, "first click reaches the intended injected monitor action")
        monitorActions += 1
    }
    let stable = show()
    // Locate the actual native switch rather than assuming header/card metrics.
    // This fixture contains only display controls; no live display IDs are used.
    let switches = presentationViews(stable).compactMap { $0 as? NSSwitch }
    guard let displaySwitch = switches.min(by: {
        $0.convert($0.bounds, to: stable).midY < $1.convert($1.bounds, to: stable).midY
    }) else {
        fatalError("Production popup must mount its native display switch")
    }
    presentationClick(stable, at: displaySwitch.convert(NSPoint(x: displaySwitch.bounds.midX, y: displaySwitch.bounds.midY), to: stable))
    expect(monitorActions == 1, "stable popup's first display-control click acts without an activation/loading click")
    expect(!model.displaySettling && snapshots == 1, "stable popup opening neither invalidates nor rediscovers displays")
    model.onOpenSettings(.displays)
    expect(!model.displaySettling && model.settingsGroup == .displays, "Settings from a stable popup inherits no presentation-only settle")
    let settings = windows.last!
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    settings.contentView?.layoutSubtreeIfNeeded()
    if let navigation = settings.contentView.flatMap({ presentationViews($0).compactMap { $0 as? SettingsTabButton }.first { $0.selected } }) {
        expect(navigation.tag == 2, "Settings tabs reflect Displays before first keyboard input")
        expect(settings.makeFirstResponder(navigation), "fixture Settings tabs accept native keyboard focus")
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: settings.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124)!
        settings.sendEvent(down)
        // Category tabs move keyboard focus with arrows and select with Space.
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: settings.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        settings.sendEvent(space)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        expect(model.settingsGroup == .sound, "native keyboard navigation acts immediately after stable popup-to-Settings handoff")
    } else { expect(false, "production Settings exposes its native category tabs") }

    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    expect(model.displaySettling, "an actual screen-change observer still invalidates the settled snapshot")
    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
    let changing = show()
    presentationClick(changing, at: NSPoint(x: changing.bounds.width - 33, y: 84))
    expect(monitorActions == 1 && model.displaySettling, "opening during real settling cannot enable or dispatch a display control")
    RunLoop.main.run(until: Date().addingTimeInterval(0.75))
    expect(!model.displaySettling && snapshots == 2, "presentation does not restart the existing screen-change quiet-period deadline")
    model.onClose()

    failSnapshot = true
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    settle()
    expect(snapshots == 3 && model.errorMessage != nil, "failed discovery preserves an unsuccessful snapshot for retry")
    failSnapshot = false
    _ = show()
    expect(model.displaySettling && snapshots == 3, "reopening after discovery failure schedules a legitimate retry")
    settle()
    expect(snapshots == 4, "presentation retry completes a new snapshot after discovery failure")
    model.onClose()

    model.onRestoreAll()
    let deadline = Date().addingTimeInterval(2)
    while !model.displaySettling && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(model.displaySettling, "injected recovery helper completion still requests a deferred snapshot")
    _ = show()
    expect(model.displaySettling, "presentation cannot bypass the operation-completion settle")
    settle()
    expect(snapshots == 5, "operation completion and concurrent presentation coalesce without losing the refresh")
    model.onClose()

    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    expect(model.displaySettling, "monitor-only ownership invalidates the display snapshot on wake")
    settle()
    expect(snapshots == 6, "wake refresh does not depend on an enabled Window layouts owner")
    model.onModuleChanged(.monitors, false)
    _ = show()
    expect(!model.displaySettling && snapshots == 6, "presentation without display owners or recovery does not start discovery")
    model.onClose()
    failSnapshot = true
    model.onModuleChanged(.monitors, true)
    settle()
    expect(snapshots == 7 && model.errorMessage != nil, "cold owner initialization failure remains eligible for retry")
    failSnapshot = false
    _ = show()
    expect(model.displaySettling, "presentation retries a missing cold snapshot instead of reusing unloaded state")
    settle()
    expect(snapshots == 8, "cold initialization retry discovers once and can become fresh")
}

private func runPresentationGateTests() {
    var reads = 0
    weak var activeGate: DisplayRefreshGate?
    let gate = DisplayRefreshGate(delay: 0.08) {
        reads += 1
        // Reentrant UI publication during discovery must not enqueue a second
        // quiet period, even before the host marks that snapshot fresh.
        activeGate?.requestRefreshForPresentation(snapshotIsFresh: false)
    }
    activeGate = gate
    gate.requestRefreshForPresentation(snapshotIsFresh: true)
    expect(!gate.isSettling, "presentation of a fresh snapshot does not enter settling")
    gate.requestRefreshForPresentation(snapshotIsFresh: false)
    expect(gate.isSettling && reads == 0, "missing snapshot presentation requests deferred discovery")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    for _ in 0..<100 { gate.requestRefreshForPresentation(snapshotIsFresh: false) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    expect(reads == 1 && !gate.isSettling, "presentation storms and reentrant discovery cannot extend or recreate the refresh")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    expect(reads == 1 && !gate.isSettling, "no hidden follow-up discovery remains after presentation during refresh")
    gate.requestRefresh()
    gate.requestRefreshForPresentation(snapshotIsFresh: true)
    expect(gate.isSettling, "fresh presentation cannot cancel an explicit topology refresh")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    expect(reads == 2 && !gate.isSettling, "explicit refresh still runs even when the UI already has a snapshot")
    gate.requestRefreshForPresentation(snapshotIsFresh: false)
    gate.cancel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    expect(reads == 2 && !gate.isSettling, "shutdown cancellation still rejects deferred presentation work")
}
