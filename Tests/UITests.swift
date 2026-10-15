import AppKit
import SwiftUI
import IOKit.pwr_mgt

private final class SetupAudioBackend: AudioRoutingBackend {
    var writes: [String] = []
    var fail = false
    func devices() throws -> [AudioDevice] { [AudioDevice(uid: "old", name: "Old", directions: [.output], bluetooth: false), AudioDevice(uid: "new", name: "New", directions: [.output], bluetooth: false)] }
    func current(_ direction: AudioDirection) throws -> String? { direction == .output ? "new" : nil }
    func select(_ uid: String, direction: AudioDirection) throws { writes.append(uid); if fail { throw ToggleError(message: "Repeated routing failure") } }
}
private final class SetupPowerBackend: PowerAssertionBackend {
    var creates = 0
    var fail = false
    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID { creates += 1; if fail { throw ToggleError(message: "Repeated assertion failure") }; return IOPMAssertionID(creates) }
    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws {}
    func release(_ id: IOPMAssertionID) throws {}
}

private final class SetupSpaceInterceptor: SpaceIntercepting {
    var isRunning = false
    var overrideEnabled = false
    var starts = 0
    var failStart = false
    func start() { starts += 1; isRunning = !failStart }
    func teardown() { isRunning = false }
}

private final class UIClipboard: ClipboardAccess {
    var changeCount = 0
    var markedPrivate = false
    var reads = 0
    func text() -> String? { reads += 1; return "never read" }
    func image() -> Data? { reads += 1; return nil }
    func write(_ entry: ClipboardEntry) -> Bool { fatalError("UI setup must not write a clipboard") }
}
private final class UIArchive: ClipboardPersistence {
    var writes = 0
    var fail = false
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws { writes += 1; if fail { throw CocoaError(.fileWriteNoPermission) } }
    func clear() throws { if fail { throw CocoaError(.fileWriteNoPermission) } }
}
private final class UIWindows: WindowPositionBackend {
    var permitted = true
    var reads = 0
    var moves = 0
    func requestPermission() { fatalError("UI setup must not request permission implicitly") }
    func displays() -> [WindowDisplay] { [] }
    func windows() throws -> [PositionedWindow] { reads += 1; return [] }
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool { moves += 1; return true }
}

func runUITests() throws {
    runAwakeQuickActionTests()
    let suite = "fix-mac-os.ui-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UISettingsStore(defaults: defaults)
    expect(!store.isExistingInstall, "fresh UI detection does not rely solely on missing wizard-completion key")
    defaults.set(true, forKey: "windows.auto")
    expect(store.isExistingInstall, "legacy Windows-only preferences prevent a forced upgrade wizard")
    defaults.removeObject(forKey: "windows.auto")
    defaults.set(true, forKey: "quitGuard.enabled")
    expect(store.isExistingInstall, "existing feature preferences remain an existing install without setup completion")
    defaults.removeObject(forKey: "quitGuard.enabled")
    let seeded = store.loadLayout(modules: [.audio, .keepAwake], existing: true)
    expect(seeded.entries.map(\.kind) == ["keepAwake", "audio"], "migration seeds only relevant curated widgets")
    var edited = seeded
    edited.add(.clipboard); edited.add(.clipboard)
    expect(edited.entries.filter { $0.known == .clipboard }.count == 1, "widget catalog allows only one instance per kind")
    edited.move("clipboard", by: -1)
    edited.move("clipboard", before: "keepAwake")
    edited.entries[0].expanded = true
    edited.entries[0].windowLayoutID = "absent-layout"
    store.save(edited)
    expect(store.loadLayout(modules: [], existing: true) == edited, "layout order, presentation and absent targets survive relaunch without feature reseeding")
    var unknown = WidgetEntry(.audio); unknown.kind = "future-kind"
    edited.entries.append(unknown); edited.entries.append(unknown); edited.normalize()
    store.save(edited)
    expect(store.loadLayout(modules: [], existing: true).entries.filter { $0.kind == "future-kind" }.count == 1, "unknown widget kinds survive normalized persistence")
    let newerLayout = try JSONDecoder().decode(WidgetLayout.self, from: Data(#"{"version":2,"entries":[{"kind":"future-only"},{"kind":"audio","expanded":true}]}"#.utf8))
    expect(newerLayout.entries.count == 2 && newerLayout.entries[0].known == nil && newerLayout.entries[1].expanded, "unknown kinds with no old presentation fields do not reset otherwise usable widgets")
    let model = DashboardModel()
    model.enabledModules = []
    model.widgetLayout = WidgetLayout()
    var liveMutations = 0
    model.onClipboardPersistence = { _ in liveMutations += 1 }
    model.onClipboardRecording = { _ in liveMutations += 1 }
    model.onKeepAwakeStart = { liveMutations += 1 }
    model.onApplyMouse = { liveMutations += 1 }
    let draft = SetupDraft(current: model, defaults: defaults)
    draft.selected = [.clipboard, .mouse]; draft.syncSelection()
    expect(draft.steps == [.welcome, .selection, .configure(.input), .configure(.clipboard), .permissions, .widgets, .review], "wizard configures only selected groups in stable order")
    draft.controls.onClipboardPersistence(true)
    draft.controls.onClipboardDays(12)
    draft.controls.onClipboardExclusions("fixture.secret")
    draft.controls.onApplyMouse(); draft.controls.onKeepAwakeStart(); draft.controls.onClipboardRecording(true)
    expect(liveMutations == 0 && !model.clipboardPersistence && !model.clipboardRecording && !draft.controls.clipboardRecording, "shared draft controls cannot start capture, a timed session, pointer Apply, or live preference writes")
    draft.step = .configure(.clipboard); draft.back(); draft.next()
    expect(draft.controls.clipboardDays == 12 && draft.configuration.clipboardExclusions == "fixture.secret", "wizard Back preserves its configuration draft")
    draft.step = .permissions; draft.next()
    expect(draft.widgets.entries.map(\.kind) == ["clipboard"], "fresh wizard suggests widgets for selected features only")
    draft.widgets.entries.removeAll(); draft.back(); draft.next()
    expect(draft.widgets.entries.isEmpty, "Back and Continue never repopulate a deliberately emptied widget draft")
    draft.widgets.add(.clipboard); draft.saveCheckpoint()
    let restarted = SetupDraft(current: model, defaults: defaults)
    expect(restarted.hasCheckpoint && restarted.selected.isEmpty && !restarted.controls.clipboardPersistence, "interrupted setup is offered but never silently resumed or applied")
    restarted.resumeCheckpoint()
    expect(restarted.selected == [.clipboard, .mouse] && restarted.configuration.clipboardPersistence && restarted.configuration.clipboardDays == 12, "explicit Resume restores validated configuration, feature intent, and widget draft")
    restarted.discardCheckpoint()
    expect(!restarted.hasCheckpoint && liveMutations == 0, "Cancel discards checkpoint without affecting feature settings")
    model.enabledModules = [.audio]; model.widgetLayout.entries = []
    model.audioPreferences[.output] = ["saved-uid"]
    let repeatDraft = SetupDraft(current: model, defaults: defaults)
    repeatDraft.step = .permissions; repeatDraft.next()
    expect(repeatDraft.widgets.entries.isEmpty && repeatDraft.configuration.outputPreferences == ["saved-uid"], "repeat setup starts from current preferences and preserves an intentional empty home")
    repeatDraft.selected = [.windows, .bluetooth]; repeatDraft.accessibilityGranted = false; repeatDraft.bluetoothGranted = false
    expect(repeatDraft.unresolvedPermissions.count == 2, "denied contextual permissions remain explicit and do not block Do later")
    for feature in DashboardTab.features {
        let group = SettingsGroup.forFeature(feature)
        expect(group.modules.contains { $0.dashboardFeature == feature }, "\(feature.rawValue) retains a grouped Settings destination")
    }
    expect(UILaunchRoute.launch(arguments: ["--show-audio"]) == .widget(.audio) && UILaunchRoute.launch(arguments: ["--show-windows"]) == .widget(.windows), "everyday launch flags open temporary inline widgets without changing persisted layout")
    expect(UILaunchRoute.launch(arguments: ["--show-keyboard"]) == .settings(.input) && UILaunchRoute.launch(arguments: ["--show-bluetooth"]) == .settings(.sound), "configuration launch flags deep-link to equivalent grouped settings")
    expect(UILaunchRoute.launch(arguments: ["--show-modules"]) == .settings(.general) && UILaunchRoute.launch(arguments: []) == .home, "legacy Settings and default launch routes remain reachable")
    for module in AppModule.allCases {
        expect(SettingsGroup.allCases.filter { $0.modules.contains(module) }.count == 1, "\(module.title) has one unambiguous per-feature settings group")
    }

    // Exercise the actual Finish callback with isolated preferences and fake OS boundaries.
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: module == .clipboard) }
    let board = UIClipboard(); let archive = UIArchive()
    let history = ClipboardHistory(board: board, archive: archive, source: { "fixture" })
    let clipboard = ClipboardModule(defaults: defaults, history: history)
    let hostModel = DashboardModel(); hostModel.enabledModules = [.clipboard]
    let host = AppDelegate(clipboard: clipboard, model: hostModel, preferences: defaults)
    clipboard.onChange = {
        hostModel.clipboardPersistence = clipboard.persistence; hostModel.clipboardStoragePending = history.storagePending
        hostModel.clipboardDays = clipboard.history.ageDays
    }
    let clipboardOnly = SetupDraft(current: hostModel, defaults: defaults)
    clipboardOnly.widgets.add(.clipboard)
    var finished: [String] = []
    hostModel.onFinishSetup(clipboardOnly) { finished = $0 }
    expect(!finished.isEmpty && !history.recording && !history.persistent && board.reads == 0 && archive.writes == 0, "actual host Finish selecting Clipboard and its widget never captures or enables persistence")
    expect(defaults.integer(forKey: UISettingsStore.completionKey) == 1 && hostModel.widgetLayout.entries.first?.known == .clipboard, "actual Finish persists completion independently from features and widget layout")
    history.setRecording(true)
    let entriesBeforeRemoval = history.entries
    _ = hostModel.onSaveWidgets(WidgetLayout())
    expect(history.recording && history.entries == entriesBeforeRemoval && ModuleSettings(defaults: defaults).enabled == [.clipboard], "actual host widget removal neither disables Clipboard nor stops recording or changes history")
    history.setRecording(false)
    let failingDraft = SetupDraft(current: hostModel, defaults: defaults)
    failingDraft.controls.onClipboardPersistence(true); failingDraft.controls.onClipboardDays(4)
    archive.fail = true
    hostModel.onFinishSetup(failingDraft) { finished = $0 }
    expect(finished.contains { $0.contains("Clipboard: failed") } && finished.contains { $0.contains("layout saved") }, "actual Finish reports per-feature storage failure separately from successful layout application")
    expect(!history.recording && board.reads == 0, "failed Finish cannot accidentally capture clipboard contents")
    archive.fail = false
    history.poll()
    let windowsBackend = UIWindows()
    let positions = WindowPositions(backend: windowsBackend, defaults: defaults)
    positions.acceptsActions = { false }
    positions.automatic = true; positions.paused = true; positions.selected = "absent"; positions.exclusions = "changed"
    positions.save("No capture"); positions.restore("absent"); positions.requestPermission()
    expect(!positions.automatic && !positions.paused && positions.selected.isEmpty && positions.exclusions.isEmpty && windowsBackend.reads == 0 && windowsBackend.moves == 0, "window settings and quick Restore recheck host admission at invocation time")
    positions.acceptsActions = { true }; positions.automatic = true
    expect(positions.automatic, "window configuration can resume after canceled quit reopens admission")
    let scheduledBackend = FakeWindowBackend()
    var work: [() -> Void] = []
    let scheduledPositions = WindowPositions(backend: scheduledBackend, defaults: defaults, schedule: { work.append($0) })
    var admitted = true
    scheduledPositions.acceptsActions = { admitted }
    scheduledPositions.reconcile(ready: true, settled: true)
    scheduledPositions.save("Scheduled fixture")
    scheduledPositions.restore(scheduledPositions.selected)
    admitted = false
    while !work.isEmpty { work.removeFirst()() }
    expect(scheduledBackend.moves.isEmpty, "queued quick window Restore rechecks admission before its first OS write")
    withExtendedLifetime(host) {}
    runSetupActivationOrderingTests()
    runSetupOutcomeTests()
    runNativeUIInteractionTests()
    runSetupDesktopIntentTests()
    runSetupDesktopPermissionTests()
}

private func runAwakeQuickActionTests() {
    let model = DashboardModel()
    model.enabledModules = []
    let actions = AwakeSessionActions(model: model)
    var calls: [String] = []
    model.onKeepAwakeMinutesChanged = { calls.append("duration:\($0)"); model.keepAwakeMinutes = $0 }
    model.onKeepAwakeStart = { calls.append("start:\(model.keepAwakeMinutes)") }
    actions.start(minutes: 15)
    expect(calls.isEmpty, "popup presets never activate a disabled feature")
    model.enabledModules = [.keepAwake]
    for minutes in AwakeSessionActions.presets { actions.start(minutes: minutes) }
    expect(calls == AwakeSessionActions.presets.flatMap { ["duration:\($0)", "start:\($0)"] }, "one-click presets set the duration before invoking the existing admitted Start callback")
    calls.removeAll()
    for minutes in [0, 1445] { actions.start(minutes: minutes) }
    expect(calls.isEmpty, "popup refuses out-of-cap durations")
    actions.start(minutes: 5); actions.start(minutes: 1440)
    expect(calls == ["duration:5", "start:5", "duration:1440", "start:1440"], "custom duration preserves existing five-minute minimum and 24-hour cap")
    calls.removeAll(); model.stoppingModules = [.keepAwake]
    actions.start(minutes: 30)
    expect(calls.isEmpty, "popup cannot start while feature recovery is stopping")
    expect(actions.status == "Inactive", "inactive popup does not imply indefinite protection")
    model.keepAwakeActive = true; model.keepAwakeRemaining = 61.1
    expect(actions.status == "1:02 remaining", "timed popup countdown rounds up seconds without losing remaining time")
    model.keepAwakeProtectionFailed = true
    expect(actions.status == "Protection needs retry", "protection failure takes precedence over a retained timed deadline")
    model.keepAwakeProtectionFailed = false; model.keepAwakeRemaining = 0
    expect(actions.status == "Active · app rules", "app-only protection stays distinct from timed and inactive sessions")

    let suite = "fix-mac-os.popup-awake.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    let power = SetupPowerBackend()
    let awake = KeepAwakeModule(defaults: defaults, backend: power, now: { 100 }, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
    let hostModel = DashboardModel()
    let host = AppDelegate(model: hostModel, preferences: defaults, makeKeepAwake: { awake })
    hostModel.onModuleChanged(.keepAwake, true)
    AwakeSessionActions(model: hostModel).start(minutes: 45)
    expect(awake.remaining == 2700 && awake.active && power.creates == 1, "production popup action reaches real host Start with fake assertions and selected preset")
    hostModel.onKeepAwakeExtend()
    expect(awake.remaining == 3600, "popup extension callback extends the owned timed session by fifteen minutes")
    hostModel.onKeepAwakeStop()
    expect(!awake.active && awake.remaining == 0, "popup End session callback releases timed ownership through the host")
    power.fail = true
    AwakeSessionActions(model: hostModel).start(minutes: 30)
    expect(awake.protectionFailed && AwakeSessionActions(model: hostModel).status == "Protection needs retry", "failed production Start never renders a healthy countdown")
    power.fail = false
    hostModel.onKeepAwakeStop()
    try? awake.deactivate()
    withExtendedLifetime(host) {}
}

/// Explicit snapshot route: only a fresh model and a window owned by this test
/// process. No AppDelegate, clipboard, host modules, permissions or screen capture.
func renderCompactUIFixtures(directory: String) throws {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for dark in [false, true] {
        for scenario in ["inactive", "active", "recovery", "editing", "empty"] {
            let active = scenario == "active" || scenario == "recovery"
            let model = DashboardModel()
            model.watchdogReady = true
            model.enabledModules = [.keepAwake, .audio, .clipboard, .bluetooth]
            model.widgetLayout = WidgetLayout(entries: [.init(.keepAwake), .init(.audio, expanded: true), .init(.clipboard), .init(.bluetooth)])
            model.keepAwakeActive = active; model.keepAwakeCanStop = active
            model.keepAwakeRemaining = active ? 1794 : 0
            model.keepAwakeAppNames = active ? ["Fixture Presentation"] : []
            model.keepDisplayAwake = active
            model.clipboardRecording = false
            model.audioDevices = [AudioDevice(uid: "fixture-output", name: "Studio headphones — USB audio", directions: [.output], bluetooth: false), AudioDevice(uid: "fixture-input", name: "Built-in microphone", directions: [.input], bluetooth: false)]
            model.audioRoutes = [.output: "fixture-output", .input: "fixture-input"]
            model.audioStatus = "Preferred routes"
            if scenario == "recovery" {
                model.widgetLayout.entries.removeAll()
                model.keepAwakeProtectionFailed = true
                model.keepAwakeAppsPaused = true
                model.errorMessage = "Fixture: assertion release needs retry."
            }
            if scenario == "empty" { model.widgetLayout.entries.removeAll() }
            if scenario == "editing" { model.popupWidgetEditor.begin(model.widgetLayout) }
            let view = NSHostingView(rootView: QuickActionsView(model: model))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: model.popupHeight), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = window.contentView!.bounds
            view.layoutSubtreeIfNeeded()
            window.display()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: root.appendingPathComponent("popup-\(scenario)-\(dark ? "dark" : "light").png"))
            window.orderOut(nil)
        }
    }
}

private func runSetupDesktopPermissionTests() {
    let suite = "fix-mac-os.setup-desktop-permission.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: module == .spaces) }
    defaults.set(true, forKey: "animations.enabled")
    defaults.set(false, forKey: "spaces.enabled")
    var permission = false
    var permissionRequests = 0
    let interceptor = SetupSpaceInterceptor()
    let engine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true })
    let spaces = SpacesModule(defaults: defaults, engine: engine, makeInterceptor: { _ in interceptor },
        permissionCheck: { permission }, requestPermission: { permissionRequests += 1 }, conflictingAppRunning: { false })
    spaces.isAvailable = true
    let model = DashboardModel(); model.enabledModules = [.spaces]; model.animationsEnabled = true
    let animations = AnimationPreferences(defaults: defaults, read: { _ in nil }, write: { _, _ in })
    let host = AppDelegate(spaces: spaces, model: model, preferences: defaults, animations: animations,
        restartAnimationClients: {}, controlStateSnapshot: {
            SystemControlLifecycle.State(watchdogReady: true, displaySettling: false)
        })
    let draft = SetupDraft(current: model, defaults: defaults)
    draft.controls.onSpacesChanged(true)
    model.onFinishSetup(draft) { _ in }
    if case .pendingAccess = draft.outcomes[.spaces] { expect(true, "setup desktop On with denied permission reports Pending access") }
    else { expect(false, "denied setup desktop On must remain Pending access") }
    expect(spaces.savedEnabled && spaces.needsStartupRestore && !spaces.isEnabled && permissionRequests == 0,
           "Finish retains denied desktop On intent without implicitly asking for permission")
    for _ in 0..<3 { model.onMonitorDisableModeChanged(false) }
    expect(permissionRequests == 0 && spaces.needsStartupRestore && spaces.savedEnabled && interceptor.starts == 0,
           "ready host refreshes never prompt or consume the pending desktop ticket while permission is denied")
    // Exercise the feature's automatic seam directly as well, not just a host guard.
    do { try spaces.restoreSavedState() } catch {}
    expect(permissionRequests == 0 && spaces.needsStartupRestore,
           "direct automatic restoration is permission-passive and retains its ticket")
    permission = true
    model.onMonitorDisableModeChanged(false)
    expect(spaces.savedEnabled && spaces.isEnabled && !spaces.needsStartupRestore && interceptor.starts == 1,
           "a later permission grant activates the pending fake interceptor exactly once")
    for _ in 0..<3 { model.onMonitorDisableModeChanged(false) }
    expect(interceptor.starts == 1 && permissionRequests == 0,
            "repeated ready/granted refreshes do not reactivate or ask for permission")
    permission = false
    for enabled in [false, true] {
        model.onAnimationsChanged(enabled)
        let deadline = Date().addingTimeInterval(3)
        while model.animationsBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    expect(!model.animationsBusy && spaces.savedEnabled && spaces.needsStartupRestore && !spaces.isEnabled && permissionRequests == 0,
           "ordinary animation On re-arms an existing desktop choice after permission revocation without prompting")
    permission = true
    for _ in 0..<3 { model.onMonitorDisableModeChanged(false) }
    expect(spaces.isEnabled && interceptor.starts == 2 && !spaces.needsStartupRestore && permissionRequests == 0,
           "ordinary animation restoration after revocation resumes once when permission returns")
    try? spaces.setEnabled(false)
    let deadline = Date().addingTimeInterval(2)
    while spaces.isDraining && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    permission = false
    do { try spaces.setEnabled(true); expect(false, "explicit desktop enable must surface denied permission") }
    catch { expect(permissionRequests == 1 && !spaces.isEnabled,
                   "the explicit contextual desktop toggle retains its permission-request behavior through the fake callback") }
    // requestRestore is also used after canceled quit and animation completion.
    spaces.requestRestore(enabled: true)
    for enabled in [false, true] {
        model.onAnimationsChanged(enabled)
        let deadline = Date().addingTimeInterval(3)
        while model.animationsBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    expect(!model.animationsBusy && permissionRequests == 1 && spaces.savedEnabled && spaces.needsStartupRestore && !spaces.isEnabled,
           "restore requests and ordinary animation Off/On stay permission-passive and keep denied intent pending")
    permission = true
    for _ in 0..<3 { model.onMonitorDisableModeChanged(false) }
    expect(spaces.isEnabled && interceptor.starts == 3 && permissionRequests == 1 && !spaces.needsStartupRestore,
           "animation/canceled-quit restoration intent activates once after a later grant without extra requests")
    spaces.stop()
    withExtendedLifetime(host) {}

    var checks = 0
    var raceRequests = 0
    let raceInterceptor = SetupSpaceInterceptor()
    let raceEngine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true })
    let raceSpaces = SpacesModule(defaults: defaults, engine: raceEngine, makeInterceptor: { _ in raceInterceptor },
        permissionCheck: { checks += 1; return checks == 1 }, requestPermission: { raceRequests += 1 }, conflictingAppRunning: { false })
    raceSpaces.isAvailable = true
    do { try raceSpaces.restoreSavedState() } catch {}
    expect(raceRequests == 0 && raceSpaces.needsStartupRestore && raceInterceptor.starts == 0,
           "revocation between automatic permission checks neither prompts nor consumes the restore ticket")
    raceSpaces.stop()

    let retryInterceptor = SetupSpaceInterceptor(); retryInterceptor.failStart = true
    let retryEngine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true })
    let retrySpaces = SpacesModule(defaults: defaults, engine: retryEngine, makeInterceptor: { _ in retryInterceptor },
        permissionCheck: { true }, requestPermission: { fatalError("Automatic retry must not ask for access") }, conflictingAppRunning: { false })
    retrySpaces.isAvailable = true
    do { try retrySpaces.restoreSavedState() } catch {}
    expect(retrySpaces.needsStartupRestore && !retrySpaces.isEnabled && retryInterceptor.starts == 1,
           "a failed automatic interceptor start retains its pending ticket")
    retryInterceptor.failStart = false
    do { try retrySpaces.restoreSavedState(); try retrySpaces.restoreSavedState() } catch {}
    expect(!retrySpaces.needsStartupRestore && retrySpaces.isEnabled && retryInterceptor.starts == 2,
           "a successful automatic retry consumes its ticket only once")
    retrySpaces.stop()

    defaults.removeObject(forKey: "spaces.enabled")
    defaults.set(false, forKey: "animations.enabled")
    var legacyRequests = 0
    let legacyInterceptor = SetupSpaceInterceptor()
    let legacyEngine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true })
    let legacySpaces = SpacesModule(defaults: defaults, engine: legacyEngine, makeInterceptor: { _ in legacyInterceptor },
        permissionCheck: { false }, requestPermission: { legacyRequests += 1 }, conflictingAppRunning: { false })
    legacySpaces.isAvailable = true
    let legacyModel = DashboardModel(); legacyModel.enabledModules = [.spaces]
    let legacyAnimations = AnimationPreferences(defaults: defaults, read: { _ in nil }, write: { _, _ in })
    let legacyHost = AppDelegate(spaces: legacySpaces, model: legacyModel, preferences: defaults, animations: legacyAnimations,
        restartAnimationClients: {}, controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: true, displaySettling: false) })
    legacyModel.onAnimationsChanged(true)
    let legacyDeadline = Date().addingTimeInterval(3)
    while legacyModel.animationsBusy && Date() < legacyDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(!legacyModel.animationsBusy && defaults.object(forKey: "spaces.enabled") == nil && legacyRequests == 0 && legacyInterceptor.starts == 0,
           "ordinary animation On preserves the legacy unset desktop-choice behavior when access is unavailable")
    legacySpaces.stop()
    withExtendedLifetime(legacyHost) {}
}

private func runSetupDesktopIntentTests() {
    // Optional case selection makes the three pre-fix failures independently
    // runnable; all cases run in the normal isolated suite.
    let filterIndex = CommandLine.arguments.firstIndex(of: "--setup-space-case")
    let filter = filterIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    for scenario in ["inactive-off", "animation-on-desktop-off", "pending-on", "ordinary-animation-off"] where filter == nil || filter == scenario {
        let suite = "fix-mac-os.setup-desktop-intent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: module == .spaces) }
        let animationWasOn = scenario != "animation-on-desktop-off"
        defaults.set(animationWasOn, forKey: "animations.enabled")
        defaults.set(scenario != "pending-on", forKey: "spaces.enabled")
        let interceptor = SetupSpaceInterceptor()
        let engine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true })
        let spaces = SpacesModule(defaults: defaults, engine: engine, makeInterceptor: { _ in interceptor },
            permissionCheck: { true }, conflictingAppRunning: { false })
        spaces.isAvailable = true
        var ready = scenario != "pending-on"
        let model = DashboardModel(); model.enabledModules = [.spaces]
        model.animationsEnabled = animationWasOn
        let animations = AnimationPreferences(defaults: defaults, read: { _ in nil }, write: { _, _ in })
        let host = AppDelegate(spaces: spaces, model: model, preferences: defaults, animations: animations,
            restartAnimationClients: {}, controlStateSnapshot: {
                SystemControlLifecycle.State(watchdogReady: ready, displaySettling: false)
            })
        func waitForAnimation() {
            let deadline = Date().addingTimeInterval(3)
            while model.animationsBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            expect(!model.animationsBusy, "\(scenario): fake animation transaction finishes without live writes or client restart")
        }
        if scenario == "ordinary-animation-off" {
            model.onAnimationsChanged(false); waitForAnimation()
            expect(spaces.savedEnabled && !spaces.isEnabled && interceptor.starts == 0,
                   "ordinary animation Off preserves saved desktop On intent while suspending runtime interception")
            model.onAnimationsChanged(true); waitForAnimation()
            expect(spaces.savedEnabled && spaces.isEnabled && interceptor.starts == 1,
                   "ordinary animation On still restores the saved desktop choice through the fake interceptor")
        } else {
            let draft = SetupDraft(current: model, defaults: defaults)
            draft.controls.onSpacesChanged(scenario == "pending-on")
            if scenario == "animation-on-desktop-off" { draft.controls.onAnimationsChanged(true) }
            var finished = false
            model.onFinishSetup(draft) { _ in finished = true }
            let deadline = Date().addingTimeInterval(3)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            expect(finished, "\(scenario): actual host Finish completes with fake gesture and animation backends")
            if scenario == "pending-on" {
                expect(spaces.savedEnabled && !spaces.isEnabled && interceptor.starts == 0,
                       "reviewed desktop On is saved while runtime readiness is unavailable")
                if case .pendingHardware = draft.outcomes[.spaces] { expect(true, "unavailable desktop On reports pending readiness, not applied") }
                else { expect(false, "unavailable desktop On must report pending readiness") }
                ready = true
                model.onMonitorDisableModeChanged(false) // Existing read/refresh path; no display operation.
                expect(spaces.savedEnabled && spaces.isEnabled && interceptor.starts == 1,
                       "later host readiness restores the reviewed pending desktop On intent once")
            } else {
                expect(!spaces.savedEnabled && interceptor.starts == 0,
                       "\(scenario): reviewed desktop Off persists and never starts an intermediate interceptor")
                model.onMonitorDisableModeChanged(false)
                expect(!spaces.savedEnabled && !spaces.isEnabled && interceptor.starts == 0,
                       "\(scenario): a later ready refresh cannot resurrect obsolete saved desktop On")
            }
        }
        spaces.stop()
        withExtendedLifetime(host) {}
    }
}

private func runNativeUIInteractionTests() {
    let suite = "fix-mac-os.native-ui-interactions.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    let model = DashboardModel(); model.enabledModules = []
    let started = DispatchSemaphore(value: 0); let release = DispatchSemaphore(value: 0)
    var restarts = 0
    let animations = AnimationPreferences(defaults: defaults, read: { _ in nil }, write: { setting, _ in
        if setting.id == AnimationPreferences.settings[0].id { started.signal(); release.wait() }
    })
    let engine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true })
    let spaces = SpacesModule(defaults: defaults, engine: engine)
    var presented: [NSWindow] = []
    // This is the real host/window path, with presentation (activation/orderFront)
    // suppressed. All animation writes and client restarts stay inside fakes.
    let host = AppDelegate(spaces: spaces, model: model, preferences: defaults, animations: animations,
        presentWindow: { presented.append($0) }, restartAnimationClients: { restarts += 1 })
    let store = UISettingsStore(defaults: defaults)
    let original = WidgetLayout(entries: [WidgetEntry(.clipboard)])
    _ = model.onSaveWidgets(original)
    let popup = model.popupWidgetEditor
    popup.begin(model.widgetLayout); popup.draft?.add(.audio)
    popup.cancel()
    expect(popup.draft == nil && model.widgetLayout == original && store.loadLayout(modules: [], existing: true) == original,
           "production popup Cancel action discards its actual editor session without invoking host persistence")
    popup.begin(model.widgetLayout); popup.draft?.add(.audio)
    expect(popup.done(save: model.onSaveWidgets) && popup.draft == nil && model.widgetLayout.entries.count == 2,
           "production popup Done action invokes actual host persistence and closes only its committed draft")
    expect(store.loadLayout(modules: [], existing: true) == model.widgetLayout,
           "interaction-level Done is persisted across store recreation")
    popup.begin(model.widgetLayout); popup.draft?.entries.removeAll()
    expect(!popup.done(save: { _ in false }) && popup.draft != nil && !model.widgetLayout.entries.isEmpty,
           "rejected production Done retains the editable draft instead of losing it during quit admission")
    popup.cancel()

    model.onOpenSettings(.quickActions)
    let settings = presented.last!
    let content = settings.contentViewController
    model.settingsWidgetEditor.begin(model.widgetLayout)
    model.settingsWidgetEditor.draft?.entries.removeAll()
    model.onOpenSettings(.clipboard)
    model.onOpenSettings(.quickActions)
    model.onOpenSettings(nil)
    expect(presented.suffix(4).allSatisfy { $0 === settings } && settings.contentViewController === content,
           "actual host gear/deep-link actions reuse one native Settings window and hosting controller")
    expect(model.settingsGroup == .quickActions && model.settingsWidgetEditor.draft?.entries.isEmpty == true && !model.widgetLayout.entries.isEmpty,
           "actual Settings links preserve selected group and uncommitted editor draft across destinations")
    model.settingsWidgetEditor.cancel()
    expect(!model.widgetLayout.entries.isEmpty, "Settings Cancel uses the same production session without affecting the saved popup")
    model.settingsWidgetEditor.begin(model.widgetLayout); model.settingsWidgetEditor.draft?.entries.removeAll()
    expect(model.settingsWidgetEditor.done(save: model.onSaveWidgets) && model.widgetLayout.entries.isEmpty,
           "Settings Done persists its real editor draft through the host callback")

    model.onRunSetup()
    let setupWindow = presented.last!
    let draft = host.setupSession!
    model.onRunSetup()
    expect(presented.last === setupWindow && host.setupSession === draft,
           "actual repeated Run setup action reuses the existing native setup session")
    draft.next(); draft.setSelected(.spaces, enabled: true)
    draft.controls.onAnimationsChanged(true)
    draft.step = .review
    expect(draft.finish(using: model.onFinishSetup), "production confirmed Finish action admits the real host application sequence")
    let startDeadline = Date().addingTimeInterval(2)
    var began = false
    while !began && Date() < startDeadline {
        began = started.wait(timeout: .now()) == .success
        if !began { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    expect(began && draft.applying && !draft.finish(using: model.onFinishSetup),
           "real asynchronous Finish is in flight and rejects a duplicate confirmed Finish")
    setupWindow.performClose(nil)
    expect(host.setupSession === draft && draft.applying && !draft.cancel(),
           "native window close delegate and production Cancel action both block while Finish is applying")
    model.onSkipSetup()
    expect(host.setupSession === draft, "retained Skip callback cannot dismiss an applying setup transaction")
    release.signal()
    let finishDeadline = Date().addingTimeInterval(3)
    while draft.applying && Date() < finishDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(!draft.applying && draft.step == .results && restarts == 1 && !draft.results.isEmpty,
           "real asynchronous Finish completion transitions the production wizard to per-feature results using only fake writes/restart")
    setupWindow.performClose(nil)
    expect(host.setupSession == nil, "native close is admitted after Finish and releases its setup session")
    model.onRunSetup()
    let repeated = host.setupSession!
    expect(repeated !== draft && repeated.selected == [.spaces] && repeated.controls.animationsEnabled,
           "repeat setup after native close starts a new draft seeded from successfully applied current choices")
    presented.last?.performClose(nil)
    settings.close(); spaces.stop()
    withExtendedLifetime(host) {}
}

private struct SetupBluetoothRunner: CommandRunning {
    let failure: Bool
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        if failure { throw ToggleError(message: "Repeated Bluetooth failure") }
        if arguments == ["--power"] { return "0" }
        if arguments == ["--paired", "--format", "json"] { return "[]" }
        fatalError("Setup must not write Bluetooth hardware in this fixture")
    }
}

private func runSetupOutcomeTests() {
    let suite = "fix-mac-os.setup-outcomes.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    defaults.set(true, forKey: "audio.automatic"); defaults.set(["old"], forKey: "audio.output.preferences")
    defaults.set(["old.app": "Old app"], forKey: "keepAwake.apps")
    defaults.set(true, forKey: "menuBar.compact")
    let audioBackend = SetupAudioBackend(); audioBackend.fail = true
    let power = SetupPowerBackend(); power.fail = true
    let audio = AudioModule(backend: audioBackend, defaults: defaults)
    let awake = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false, runningApps: { ["old.app": "Old app"] }, processInstances: { [:] })
    let spacing = MenuBarSpacing(defaults: defaults, read: { _ in nil }, write: { _, _ in throw ToggleError(message: "Repeated spacing failure") })
    let model = DashboardModel(); model.enabledModules = []; model.errorMessage = "Repeated assertion failure"
    let host = AppDelegate(model: model, preferences: defaults, makeAudio: { audio }, makeKeepAwake: { awake }, menuBarSpacing: spacing)
    let draft = SetupDraft(current: model, defaults: defaults)
    draft.selected = [.audio, .keepAwake, .menuBar]; draft.syncSelection()
    model.onFinishSetup(draft) { _ in }
    if case .failed(let detail) = draft.outcomes[.audio] { expect(detail.contains("Repeated routing failure"), "actual Finish reports synchronous activation routing failure from Audio authority") }
    else { expect(false, "Audio activation failure must not be reported applied") }
    if case .failed(let detail) = draft.outcomes[.keepAwake] { expect(detail.contains("Repeated assertion failure"), "actual Finish reports awake activation failure even when global error already has identical text") }
    else { expect(false, "Awake activation failure must not be reported applied") }
    if case .failed(let detail) = draft.outcomes[.menuBar] { expect(detail.contains("Repeated spacing failure"), "actual Finish retains spacing activation failure before configuration begins") }
    else { expect(false, "Spacing activation failure must not be reported applied") }
    expect(!audioBackend.writes.isEmpty && power.creates > 0, "failure fixtures exercised actual activation backend attempts, not just final preferences")
    model.errorMessage = "output: Repeated routing failure"
    model.onFinishSetup(draft) { _ in }
    if case .failed = draft.outcomes[.audio], case .failed = draft.outcomes[.keepAwake], case .failed = draft.outcomes[.menuBar] {
        expect(true, "repeated identical failures remain failed on a second actual Finish")
    } else { expect(false, "global banner equality cannot erase repeated per-feature failures") }
    audio.stop(); try? awake.deactivate()
    withExtendedLifetime(host) {}

    for scenario in ["denied", "off", "failed"] {
        let btSuite = "fix-mac-os.setup-bluetooth.\(UUID().uuidString)"
        let btDefaults = UserDefaults(suiteName: btSuite)!
        for module in AppModule.allCases { ModuleSettings(defaults: btDefaults).set(module, enabled: false) }
        let routing = AudioModule(backend: SetupAudioBackend(), defaults: btDefaults)
        let backend = BluetoothBackend(runner: SetupBluetoothRunner(failure: scenario == "failed"), blueutil: "fixture-blueutil", audioTool: nil)
        let bluetooth = BluetoothModule(defaults: btDefaults, backend: backend, importLegacyConfiguration: false, authorizationProvider: { scenario == "denied" ? .denied : .allowedAlways })
        let btModel = DashboardModel(); btModel.enabledModules = []; btModel.errorMessage = "Repeated Bluetooth failure"
        let btHost = AppDelegate(model: btModel, preferences: btDefaults, makeAudio: { routing }, makeBluetooth: { bluetooth })
        let btDraft = SetupDraft(current: btModel, defaults: btDefaults); btDraft.selected = [.bluetooth]; btDraft.syncSelection()
        btModel.onFinishSetup(btDraft) { _ in }
        let deadline = Date().addingTimeInterval(2)
        while bluetooth.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        btModel.onFinishSetup(btDraft) { _ in }
        switch (scenario, btDraft.outcomes[.bluetooth]) {
        case ("denied", .pendingAccess): expect(true, "actual Finish distinguishes denied Bluetooth access using the feature's authorization provider")
        case ("off", .pendingHardware(let detail)): expect(detail.contains("radio is off"), "actual Finish reports radio-off hardware readiness, not applied")
        case ("failed", .failed(let detail)): expect(detail.contains("Repeated Bluetooth failure"), "actual Finish reports Bluetooth backend failure independent of identical global banner")
        default: expect(false, "Bluetooth outcome must reflect authoritative \(scenario) state")
        }
        bluetooth.stop(); routing.stop()
        withExtendedLifetime(btHost) {}
        btDefaults.removePersistentDomain(forName: btSuite)
    }
}

private func runSetupActivationOrderingTests() {
    let suite = "fix-mac-os.setup-activation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    defaults.set(true, forKey: "audio.automatic")
    defaults.set(["old"], forKey: "audio.output.preferences")
    defaults.set(["old.app": "Old app"], forKey: "keepAwake.apps")
    defaults.set(true, forKey: "keepAwake.display")
    defaults.set(true, forKey: "menuBar.compact")
    defaults.set("unselected sentinel", forKey: "clipboard.exclusions")
    let audioBackend = SetupAudioBackend(); let power = SetupPowerBackend()
    let audio = AudioModule(backend: audioBackend, defaults: defaults)
    let awake = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false, runningApps: { ["old.app": "Old app"] }, processInstances: { [:] })
    var spacingWrites = 0
    let spacing = MenuBarSpacing(defaults: defaults, read: { _ in nil }, write: { _, _ in spacingWrites += 1 })
    let model = DashboardModel(); model.enabledModules = []
    let host = AppDelegate(model: model, preferences: defaults, makeAudio: { audio }, makeKeepAwake: { awake }, menuBarSpacing: spacing)
    let draft = SetupDraft(current: model, defaults: defaults)
    draft.selected = [.audio, .keepAwake, .menuBar]; draft.syncSelection()
    draft.controls.onAudioAutomatic(false)
    draft.controls.onAudioPreferences(["new"], .output)
    draft.controls.onKeepAwakeRemoveApp("old.app")
    draft.controls.onKeepDisplayAwakeChanged(false)
    draft.controls.onCompactMenuBarChanged(false)
    var results: [String] = []
    model.onFinishSetup(draft) { results = $0 }
    expect(!results.isEmpty && model.enabledModules == draft.selected, "actual Finish enables selected owners using injected backends")
    expect(audioBackend.writes.isEmpty, "disabled Audio saved automatic On cannot write an obsolete route before reviewed Off is installed")
    expect(power.creates == 0, "disabled Keep awake cannot acquire even an intermediate assertion for app rules removed in review")
    expect(spacingWrites == 0, "disabled Menu bar cannot write compact spacing before reviewed Off is installed")
    expect(defaults.string(forKey: "clipboard.exclusions") == "unselected sentinel", "preactivation staging leaves unselected feature preferences untouched")
    audio.stop(); try? awake.deactivate()
    withExtendedLifetime(host) {}

    let refusedSuite = "fix-mac-os.setup-refused.\(UUID().uuidString)"
    let refusedDefaults = UserDefaults(suiteName: refusedSuite)!
    defer { refusedDefaults.removePersistentDomain(forName: refusedSuite) }
    for module in AppModule.allCases { ModuleSettings(defaults: refusedDefaults).set(module, enabled: false) }
    refusedDefaults.set(true, forKey: "monitors.confirmDisable")
    let recovery = Data([1, 2, 3])
    refusedDefaults.set(recovery, forKey: "pendingArrangement")
    let refusedModel = DashboardModel(); refusedModel.enabledModules = []; refusedModel.stoppingModules = [.monitors]
    let refusedHost = AppDelegate(model: refusedModel, preferences: refusedDefaults)
    let refusedDraft = SetupDraft(current: refusedModel, defaults: refusedDefaults)
    refusedDraft.setSelected(.monitors, enabled: true); refusedDraft.controls.onMonitorDisableModeChanged(false)
    refusedModel.onFinishSetup(refusedDraft) { _ in }
    expect(refusedDefaults.bool(forKey: "monitors.confirmDisable") && ModuleSettings(defaults: refusedDefaults).enabled.isEmpty,
           "actual refused activation restores staged preferences for the owner which never activated")
    expect(refusedDefaults.data(forKey: "pendingArrangement") == recovery,
           "staging refusal never overwrites the existing display recovery journal")
    let overrideBackend = SetupAudioBackend()
    let overrideAudio = AudioModule(backend: overrideBackend, defaults: refusedDefaults)
    overrideAudio.automaticAllowed = true; overrideAudio.start(); overrideAudio.automatic = true
    overrideAudio.select("new", direction: .output)
    overrideBackend.writes.removeAll()
    overrideAudio.configureForSetup(automatic: true, output: ["old"], input: [], outputFallback: "", inputFallback: "")
    expect(overrideAudio.isOverridden(.output) && overrideBackend.writes.isEmpty,
           "batch setup configuration preserves an active Audio manual override when automatic routing stays On")
    overrideAudio.stop()
    withExtendedLifetime(refusedHost) {}
}
