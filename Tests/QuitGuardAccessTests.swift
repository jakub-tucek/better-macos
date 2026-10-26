import AppKit

func runQuitGuardAccessTests() {
    let suite = "better-macos.quit-access.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var trusted = false
    var tapAttempts = 0
    let owner = QuitGuard(defaults: defaults, permissionCheck: { trusted }, makeTap: { _ in tapAttempts += 1; return nil })
    do { try owner.setEnabled(true) } catch {}
    expect(owner.enabled && !owner.isRunning, "Denied Accessibility keeps Hold to quit requested, without pretending it is active")
    expect(tapAttempts == 0, "Denied access never attempts a keyboard event tap")
    trusted = true
    do { try owner.startIfEnabled() } catch {}
    expect(tapAttempts == 1 && owner.enabled, "After grant the saved request retries activation without an off/on cycle")
    try? owner.setEnabled(false)
    try? owner.startIfEnabled()
    expect(tapAttempts == 1 && !owner.enabled, "Explicit disable cancels pending activation")
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    trusted = false
    var settingsOpened = 0
    let model = DashboardModel()
    let host = AppDelegate(model: model, preferences: defaults, makeQuitGuard: { owner },
        accessibilityCheck: { trusted }, openAccessibility: { settingsOpened += 1 },
        controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: false, displaySettling: false) })
    model.onModuleChanged(.quitGuard, true)
    model.onQuitGuardChanged(true)
    expect(model.quitGuardEnabled && model.quitGuardNeedsAccess && settingsOpened == 1 && model.statusNeedsAttention,
           "Host preserves requested On and opens Accessibility with a warning when activation is blocked")
    model.errorMessage = "Unrelated error"
    trusted = true
    host.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    expect(tapAttempts == 2 && settingsOpened == 1 && !model.quitGuardNeedsAccess && model.quitGuardIssue != nil,
           "Returning after grant automatically retries the listener and distinguishes tap failure from permission denial")
    model.onQuitGuardChanged(false)
    expect(model.quitGuardIssue == nil && model.errorMessage == "Unrelated error", "Disabling clears only Hold to quit's activation warning")
    host.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    expect(tapAttempts == 2, "Foreground recheck respects an explicit Off choice")
    model.onModuleChanged(.quitGuard, false)
}
