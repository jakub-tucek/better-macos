import AppKit
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
    history.setRecording(true)
    let entriesBeforeRemoval = history.entries
    hostModel.onSaveWidgets(WidgetLayout())
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
}
