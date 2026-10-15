import AppKit

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
    let saved = store.loadLayout(modules: [], existing: true)
    var canceled = saved; canceled.entries.removeAll()
    expect(store.loadLayout(modules: [], existing: true) == saved, "canceling a value-semantic edit draft leaves persisted widgets intact")
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
    let failingDraft = SetupDraft(current: hostModel, defaults: defaults)
    failingDraft.controls.onClipboardPersistence(true); failingDraft.controls.onClipboardDays(4)
    archive.fail = true
    hostModel.onFinishSetup(failingDraft) { finished = $0 }
    expect(finished.contains { $0.contains("Clipboard: needs attention") } && finished.contains { $0.contains("layout saved") }, "actual Finish reports per-feature storage failure separately from successful layout application")
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
    withExtendedLifetime(host) {}
}
