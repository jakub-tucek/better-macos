import AppKit

func runScreenEdgeAccessTests() {
    let suite = "better-macos.screen-edge-access.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var trusted = false
    var opened = 0
    let model = DashboardModel()
    let host = AppDelegate(model: model, preferences: defaults,
        accessibilityCheck: { trusted }, openAccessibility: { opened += 1 },
        controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: false, displaySettling: false,
            cursorRequested: defaults.bool(forKey: "arrangement.matchEdges"), arrangementEnabled: true) })
    model.onMatchScreenEdgesChanged(true)
    expect(opened == 1, "Explicit screen-edge enable opens Accessibility when access is denied, even before watchdog readiness")
    expect(model.screenEdgesNeedsAccess && model.statusSymbol == "exclamationmark.triangle.fill", "Denied screen-edge access publishes actionable status and warning icon")
    model.keepAwakeActive = true
    expect(model.statusSymbol == "exclamationmark.triangle.fill", "Keep awake cannot mask a permission warning")
    host.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    expect(opened == 1, "Passive permission rechecks never reopen System Settings")
    trusted = true
    host.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    expect(!model.screenEdgesActive, "Granting access never bypasses watchdog readiness")
    expect(!model.screenEdgesNeedsAccess && model.screenEdgesIssue == nil && !model.statusNeedsAttention, "Returning from Settings rechecks permission and clears only the resolved warning")
    model.errorMessage = "Unrelated failure"
    model.onCheckScreenEdgeAccess()
    expect(model.statusNeedsAttention && model.errorMessage == "Unrelated failure", "Permission retry preserves unrelated failures and their warning icon")
    trusted = false
    model.onCheckScreenEdgeAccess()
    model.onMatchScreenEdgesChanged(false)
    expect(!model.screenEdgesNeedsAccess && model.screenEdgesIssue == nil && opened == 1, "Disabling screen edges clears its permission warning without reopening Settings")
}
