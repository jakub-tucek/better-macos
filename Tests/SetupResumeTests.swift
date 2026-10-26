import AppKit

func runSetupResumeTests() {
    let suite = "better-macos.setup-resume.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DashboardModel(); model.enabledModules = [.windows, .bluetooth]
    let draft = SetupDraft(current: model, defaults: defaults)
    draft.accessibilityGranted = true
    draft.step = .configure(.windows)
    draft.windowsShortcuts = true
    draft.saveCheckpoint()
    let resumed = SetupDraft(current: model, defaults: defaults)
    resumed.accessibilityGranted = true
    resumed.resumeCheckpoint()
    expect(resumed.step == .configure(.windows) && resumed.windowsShortcuts, "Saved setup resumes its current step and unsaved settings")
    let denied = SetupDraft(current: model, defaults: defaults)
    denied.resumeCheckpoint()
    expect(denied.step == .access(.windows), "Resuming configuration rechecks required access rather than trusting the saved grant")
    expect(defaults.object(forKey: "windows.shortcuts") == nil, "Resuming a draft never commits feature settings")
    expect(denied.cancel() && !denied.hasCheckpoint, "Explicit Cancel discards the saved draft")
    draft.saveForLater()
    expect(draft.allowClose() && draft.hasCheckpoint, "Save for later survives the native window-close delegate")
    expect(draft.configuration.inactivePreferences(for: .windows)["windows.shortcuts"] as? Bool == true, "Setup stages the shortcut choice before starting a newly enabled Windows owner")
    draft.discardCheckpoint()
    for module: AppModule in [.windows, .arrangement, .quitGuard, .spaces] {
        let isolated = SetupDraft(current: model, defaults: defaults)
        isolated.selected = [module]
        isolated.controls.matchScreenEdges = true
        isolated.controls.quitGuardEnabled = true
        isolated.controls.spacesEnabled = true
        isolated.bluetoothGranted = true
        expect(isolated.needsAccessibility && !isolated.accessGranted(for: module), "\(module.title) requires Accessibility independently of Bluetooth")
    }
}
