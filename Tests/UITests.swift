import AppKit
import ClipboardPolicy
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
    var requestedTimeouts: [TimeInterval] = []
    var fail = false
    var renewals = 0
    var failRenewal = false
    var failRelease = false
    var releases = 0
    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID {
        creates += 1; requestedTimeouts.append(timeout)
        if fail { throw ToggleError(message: "Repeated assertion failure") }
        return IOPMAssertionID(creates)
    }
    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws {
        renewals += 1
        if failRenewal { throw ToggleError(message: "Fixture renewal failure") }
    }
    func release(_ id: IOPMAssertionID) throws {
        releases += 1
        if failRelease { throw ToggleError(message: "Fixture assertion release failure") }
    }
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
    runBuiltinCatalogTests()
    try runRegisteredOwnerChoiceTests()
    runStoredStateTests()
    runAudioPreferenceAdditionTests()
    try renderReleaseUIFixtures()
    runAwakeCountdownTests()
    runAwakeQuickActionTests()
    runAwakeNativeEditorTests()
    runPopupSizingTests()
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

private func runBuiltinCatalogTests() {
    expect(BuiltinFeatures.definitions.map(\.module) == AppModule.allCases, "catalog registers every stable feature exactly once without changing setup order")
    expect(AppModule.allCases.map(\.rawValue) == ["monitors", "arrangement", "bluetooth", "audio", "spaces", "menuBar", "quitGuard", "keepAwake", "windows", "clipboard", "mouse"], "feature persistence IDs remain stable")
    let groups: [(SettingsGroup, [AppModule])] = [(.general, []), (.quickActions, []), (.displays, [.monitors, .arrangement, .windows]), (.sound, [.audio, .bluetooth]), (.input, [.quitGuard, .mouse]), (.system, [.spaces, .menuBar, .keepAwake]), (.clipboard, [.clipboard])]
    for (group, modules) in groups { expect(group.modules == modules, "catalog preserves Settings order for \(group.rawValue)") }
    let destinations: [DashboardTab] = [.monitors, .monitors, .bluetooth, .audio, .spaces, .menuBar, .keyboard, .keepAwake, .windows, .clipboard, .mouse]
    expect(AppModule.allCases.map(\.dashboardFeature) == destinations, "catalog preserves shared display and keyboard navigation")
    expect(Set(BuiltinFeatures.widgets.map(\.kind)) == Set(WidgetKind.allCases) && BuiltinFeatures.widgets.count == 6, "catalog registers each widget exactly once")
    expect(WidgetKind.allCases.map(\.rawValue) == ["keepAwake", "audio", "displays", "windows", "clipboard", "bluetooth"], "widget persistence IDs remain stable")
    expect(WidgetLayout.suggested(for: Set(AppModule.allCases)).entries.map(\.kind) == ["keepAwake", "audio", "displays", "windows", "clipboard", "bluetooth"], "catalog preserves suggestion order independently of feature order")
    expect(WidgetKind.allCases.map(\.module) == [.keepAwake, .audio, .monitors, .windows, .clipboard, .bluetooth], "widgets retain distinct owning feature choices")
    expect(WidgetKind.windows.title == "Window layouts" && WidgetKind.displays.title == "Displays", "widget labels are not inferred from feature titles")
    expect(WidgetLayout.suggested(for: [.arrangement]).entries.isEmpty, "arrangement alone does not imply the monitor widget")
}

private func runRegisteredOwnerChoiceTests() throws {
    for setup in [false, true] {
        let suite = "fix-mac-os.registered-awake.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults)
        for module in AppModule.allCases { settings.set(module, enabled: false) }
        let power = SetupPowerBackend()
        var discoveries = 0
        let awake = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false,
            runningApps: { discoveries += 1; return [:] }, processInstances: { [:] })
        let model = DashboardModel(); model.enabledModules = []
        var constructions = 0
        let host = AppDelegate(model: model, preferences: defaults, makeKeepAwake: { constructions += 1; return awake }, displaySnapshotRefresh: {})
        expect(constructions == 0, "host registration and catalog lookup do not construct owners")
        model.onModuleChanged(.keepAwake, true)
        model.onKeepAwakeStart()
        expect(awake.active && constructions == 1, "registered awake choice still activates one typed owner")
        power.failRelease = true
        let before = discoveries
        let draft = SetupDraft(current: model, defaults: defaults); draft.selected = []; draft.syncSelection()
        if setup { model.onFinishSetup(draft) { _ in } }
        else { model.onModuleChanged(.keepAwake, false) }
        expect(settings.enabled.contains(.keepAwake) && awake.active && constructions == 1, "\(setup ? "setup" : "UI") awake disable refusal retains choice, assertions and owner")
        expect(discoveries > before && model.stoppingModules.isEmpty, "awake refusal reactivates observation without a stuck stopping marker")
        if setup {
            if case .failed(let detail) = draft.outcomes[.keepAwake] { expect(detail.contains("release failure"), "setup receives the registered awake preparation failure") }
            else { expect(false, "setup must report failed awake disable") }
        }
        power.failRelease = false
        if setup { model.onFinishSetup(draft) { _ in } }
        else { model.onModuleChanged(.keepAwake, false) }
        expect(!settings.enabled.contains(.keepAwake) && !awake.active && power.releases > 0, "registered awake retry releases owned assertions before committing disable")
        withExtendedLifetime(host) {}
    }
    for setup in [false, true] {
        let suite = "fix-mac-os.registered-clipboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults)
        for module in AppModule.allCases { settings.set(module, enabled: module == .clipboard) }
        defaults.set(true, forKey: "clipboard.persistence")
        let board = UIClipboard(); let archive = UIArchive()
        let history = ClipboardHistory(board: board, archive: archive, source: { "fixture" })
        try history.configurePersistence(true, ageDays: 7)
        history.setRecording(true)
        archive.fail = true; board.changeCount += 1; history.poll()
        expect(history.storagePending, "registered Clipboard fixture owns pending archive work")
        let clipboard = ClipboardModule(defaults: defaults, history: history)
        let model = DashboardModel(); model.enabledModules = [.clipboard]
        let host = AppDelegate(clipboard: clipboard, model: model, preferences: defaults, displaySnapshotRefresh: {})
        let draft = SetupDraft(current: model, defaults: defaults); draft.selected = []; draft.syncSelection()
        if setup { model.onFinishSetup(draft) { _ in } }
        else { model.onModuleChanged(.clipboard, false) }
        expect(settings.enabled.contains(.clipboard) && history.storagePending && history.recording, "\(setup ? "setup" : "UI") unload refusal retains pending work and does not perform quit preparation")
        if setup {
            if case .failed(let detail) = draft.outcomes[.clipboard] { expect(detail.contains("cleanup is pending"), "setup receives the registered Clipboard veto") }
            else { expect(false, "setup must report failed Clipboard unload") }
        }
        archive.fail = false
        if setup { model.onFinishSetup(draft) { _ in } }
        else { model.onModuleChanged(.clipboard, false) }
        expect(!settings.enabled.contains(.clipboard) && !history.storagePending && !history.recording, "Clipboard retry flushes before unload stops runtime work")
        expect(defaults.bool(forKey: "clipboard.persistence") && history.persistent, "module unload preserves independent retention intent")
        let reloaded = ClipboardHistory(board: board, archive: archive, source: { "fixture" })
        try reloaded.configurePersistence(true, ageDays: 7, load: true)
        expect(!reloaded.recording, "retained Clipboard history reload never resumes capture")
        withExtendedLifetime(host) {}
    }
}

private func runAudioPreferenceAdditionTests() {
    let input = AudioDevice(uid: "in", name: "Microphone", directions: [.input], bluetooth: false)
    let output = AudioDevice(uid: "out", name: "Speaker", directions: [.output], bluetooth: false)
    for direction in AudioDirection.allCases {
        let own = direction == .input ? input : output
        let other = direction == .input ? output : input
        let empty = AudioPreferenceAdditions(devices: [], preferred: [], direction: direction)
        expect(empty.devices.isEmpty && empty.emptyMessage == "No available devices.", "\(direction) empty inventory disables Add and explains no devices")
        let wrong = AudioPreferenceAdditions(devices: [other], preferred: [], direction: direction)
        expect(wrong.devices.isEmpty && wrong.emptyMessage == "No available devices.", "\(direction) excludes devices supporting only the opposite direction")
        let full = AudioPreferenceAdditions(devices: [input, output], preferred: [own.uid, "offline"], direction: direction)
        expect(full.devices.isEmpty && full.emptyMessage == "All available devices already added.", "\(direction) distinguishes exhausted candidates from empty discovery")
        let available = AudioPreferenceAdditions(devices: [input, output], preferred: [other.uid, "offline"], direction: direction)
        expect(available.devices == [own] && available.emptyMessage == nil, "\(direction) enables Add only for unsaved devices in that direction")
    }
}

/// Early-exit synthetic route. Own windows, isolated defaults, no runtime host.
func renderReleaseUIFixtures(directory: String? = nil) throws {
    _ = NSApplication.shared
    let root = directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let root { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    let suite = "fix-mac-os.release-ui-fixtures.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func settle(_ window: NSWindow) {
        for _ in 0..<4 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    func mount(_ view: AnyView, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view)
        settle(window); return window
    }
    func scroll(_ view: NSView) -> NSScrollView? {
        if let value = view as? NSScrollView, value.hasVerticalScroller, value.frame.width > 300 { return value }
        for child in view.subviews { if let found = scroll(child) { return found } }
        return nil
    }
    func snapshot(_ window: NSWindow, _ name: String) throws {
        guard let root else { return }
        settle(window)
        let view = window.contentView!
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
    }
    var evidence: [String] = []
    for dark in [false, true] {
        let suffix = dark ? "dark" : "light"
        let model = DashboardModel(); model.enabledModules = [.audio, .clipboard]; model.watchdogReady = true
        model.settingsGroup = .sound
        for scenario in ["empty", "added", "available"] {
            model.audioDevices = scenario == "empty" ? [] : [AudioDevice(uid: "in", name: "Fixture microphone", directions: [.input], bluetooth: false), AudioDevice(uid: "out", name: "Fixture speakers", directions: [.output], bluetooth: false)]
            model.audioPreferences = scenario == "added" ? [.input: ["in"], .output: ["out"]] : [:]
            let window = mount(AnyView(SettingsView(model: model)), dark: dark)
            try snapshot(window, "settings-audio-\(scenario)-\(suffix)")
            if let scroller = scroll(window.contentView!), let document = scroller.documentView {
                document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroller.contentSize.height)))
                try snapshot(window, "settings-audio-\(scenario)-bottom-\(suffix)")
            }
            window.orderOut(nil)
        }
        model.settingsGroup = .clipboard
        let clipboard = mount(AnyView(SettingsView(model: model)), dark: dark)
        try snapshot(clipboard, "settings-clipboard-\(suffix)"); clipboard.orderOut(nil)
        model.audioDevices = []
        let draft = SetupDraft(current: model, defaults: defaults)
        draft.selected = [.audio]; draft.syncSelection(); draft.step = .configure(.sound)
        let wizard = mount(AnyView(SetupWizard(model: model, draft: draft, close: {})), dark: dark)
        try snapshot(wizard, "wizard-audio-empty-\(suffix)"); wizard.orderOut(nil)

        // Force long content on both sides of navigation so clamping cannot hide retention.
        model.settingsGroup = .sound
        model.audioPreferences = [.input: (0..<24).map { "fixture-input-\($0)" }, .output: (0..<24).map { "fixture-output-\($0)" }]
        let settings = mount(AnyView(SettingsView(model: model)), dark: dark)
        if let scroller = scroll(settings.contentView!) {
            scroller.documentView?.scroll(NSPoint(x: 0, y: 450)); settle(settings)
            let before = scroller.contentView.bounds.origin.y
            model.settingsGroup = .quickActions
            model.widgetLayout.entries = WidgetKind.allCases.map { WidgetEntry($0, expanded: true) }
            model.settingsWidgetEditor.begin(model.widgetLayout)
            settle(settings)
            let after = scroll(settings.contentView!)?.contentView.bounds.origin.y ?? -1
            evidence.append("Settings \(suffix): before=\(before), after=\(after)")
            expect(before == 450 && after == 0, "native Settings \(suffix) category navigation resets a proven nonzero content offset")
            try snapshot(settings, "settings-navigation-\(suffix)")
        } else { expect(false, "native Settings content scroller exists") }
        settings.orderOut(nil)
        draft.selected = Set(AppModule.allCases); draft.syncSelection(); draft.step = .selection
        draft.controls.audioPreferences = model.audioPreferences
        let navigation = mount(AnyView(SetupWizard(model: model, draft: draft, close: {})), dark: dark)
        if let scroller = scroll(navigation.contentView!) {
            scroller.documentView?.scroll(NSPoint(x: 0, y: 450)); settle(navigation)
            let before = scroller.contentView.bounds.origin.y
            draft.step = .configure(.sound); settle(navigation)
            let after = scroll(navigation.contentView!)?.contentView.bounds.origin.y ?? -1
            evidence.append("Wizard \(suffix): before=\(before), after=\(after)")
            expect(before == 450 && after == 0, "native wizard \(suffix) step navigation resets a proven nonzero content offset")
            try snapshot(navigation, "wizard-navigation-\(suffix)")
        } else { expect(false, "native wizard content scroller exists") }
        navigation.orderOut(nil)
    }
    if let root { try evidence.joined(separator: "\n").write(to: root.appendingPathComponent("scroll-evidence.txt"), atomically: true, encoding: .utf8) }
}

private func runAwakeCountdownTests() {
    let examples: [(TimeInterval, String)] = [
        (0.001, "1 sec left"), (1, "1 sec left"), (45, "45 sec left"),
        (59, "59 sec left"), (59.001, "1 min 00 sec left"), (60, "1 min 00 sec left"),
        (60.001, "1 min 01 sec left"), (728, "12 min 08 sec left"),
        (3599, "59 min 59 sec left"), (3599.001, "1 hr left"), (3600, "1 hr left"),
        (3600.001, "1 hr 1 min left"), (5000, "1 hr 24 min left"),
        (5040, "1 hr 24 min left"), (7199, "2 hr left"), (7200, "2 hr left"),
        (86400, "24 hr left")
    ]
    for (remaining, expected) in examples {
        expect(AwakeCountdown.text(remaining: remaining) == expected, "readable awake countdown at \(remaining) seconds is \(expected)")
    }
    for remaining: TimeInterval in [0, -0.001, -.infinity, .infinity, .nan, 86401, .greatestFiniteMagnitude] {
        expect(AwakeCountdown.text(remaining: remaining) == nil, "expired or invalid awake interval cannot produce a false zero countdown or conversion trap")
    }
    let model = DashboardModel()
    let actions = AwakeSessionActions(model: model)
    model.keepAwakeActive = true; model.keepAwakeRemaining = 728
    expect(actions.status == "12 min 08 sec left", "shared session status uses the readable exact countdown")
    model.keepAwakeProtectionFailed = true
    expect(actions.status == "Protection needs retry", "failed timed session never presents a healthy countdown")
    model.keepAwakeProtectionFailed = false; model.keepAwakeRemaining = 0
    expect(actions.status == "Ending session", "expired assertion ownership without app rules does not imply app-only protection")
    model.keepAwakeAppNames = ["Fixture app"]
    expect(actions.status == "Active · app rules", "active app-only protection has a state label, never zero time left")
    model.keepAwakeActive = false; model.keepAwakeAppNames = []
    expect(actions.status == "Inactive", "expired inactive session does not display a zero countdown")
    model.keepAwakeRemaining = 60
    expect(actions.status == "Session pending", "unacquired timed intent does not claim active protection")
}

/// Real text field/editor and responder transitions in an unpresented native
/// window. SwiftUI button events/AX actions are unavailable in that hidden host;
/// Start invokes the exact action registered by the mounted production Button.
private final class AwakeNativeEditorFixture {
    let commands = AwakeDurationEditorCommands()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    let view: NSHostingView<AnyView>
    init(model: DashboardModel, showsStart: Bool = true) {
        view = NSHostingView(rootView: AnyView(AwakeDurationEditor(model: model, showsStart: showsStart, commands: commands)))
        window.contentView = view
        window.isReleasedWhenClosed = false
        settle()
    }
    func settle() {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            window.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    private func findField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.findField($0) }.first
    }
    var text: String? { findField(view)?.stringValue }
    func type(_ text: String) {
        guard let field = findField(view) else { expect(false, "production editor exposes a native editable field"); return }
        expect(window.makeFirstResponder(field), "hidden native duration field accepts first responder")
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { expect(false, "production duration field owns a native field editor"); return }
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle()
        expect(self.text == text, "native field editor delivers raw input to the actual production TextField")
    }
    func leaveField() {
        expect(window.makeFirstResponder(nil), "native duration editor relinquishes first responder")
        settle()
    }
    func removeEditor() {
        window.makeFirstResponder(nil)
        view.rootView = AnyView(Text("Another destination"))
        settle()
        window.orderOut(nil)
    }
    func close() {
        window.performClose(nil)
        removeEditor()
    }
}

private func runAwakeNativeEditorTests() {
    _ = NSApplication.shared
    let suite = "fix-mac-os.awake-native-editor.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    let power = SetupPowerBackend()
    var clock: TimeInterval = 100
    let awake = KeepAwakeModule(defaults: defaults, backend: power, now: { clock }, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
    let model = DashboardModel()
    let host = AppDelegate(model: model, preferences: defaults, makeKeepAwake: { awake })
    model.onModuleChanged(.keepAwake, true)
    let fixture = AwakeNativeEditorFixture(model: model)
    fixture.type("7")
    expect(awake.selectedMinutes == 30, "native typing does not persist an uncommitted draft")
    expect(fixture.commands.start(), "mounted production Start action is available to the hidden native host")
    fixture.settle()
    expect(awake.selectedMinutes == 7 && defaults.integer(forKey: "keepAwake.minutes") == 7 && awake.remaining == 420 && power.requestedTimeouts == [420],
           "production Start consumes native typed seven without Return or focus loss and requests the exact timeout")
    clock += 3
    fixture.type("13")
    fixture.leaveField()
    expect(awake.selectedMinutes == 13 && awake.remaining == 417 && power.requestedTimeouts == [420],
           "native focus loss commits next duration without changing the active deadline or acquiring assertions")
    fixture.type("17")
    model.onKeepAwakeMinutesChanged(45)
    fixture.settle()
    expect(fixture.text == "17", "external model publication cannot replace a focused native draft")
    fixture.leaveField()
    fixture.commands.start()
    expect(awake.selectedMinutes == 17 && awake.remaining == 417,
           "focus-loss commit and subsequent Start preserve typed draft despite an intervening model change")
    fixture.type("17")
    model.onKeepAwakeMinutesChanged(60)
    fixture.window.makeFirstResponder(nil)
    fixture.commands.start()
    fixture.settle()
    expect(awake.selectedMinutes == 17 && fixture.text == "17" && awake.remaining == 417,
           "pending model publication plus immediate focus loss and Start cannot replace the native draft")
    model.onKeepAwakeStop()
    for raw in ["", "0", "1.5", "999999999999999999999999999999"] {
        fixture.type(raw)
        fixture.leaveField()
        fixture.commands.start()
        fixture.settle()
        expect(fixture.text == raw && awake.selectedMinutes == 17 && awake.remaining == 0 && power.requestedTimeouts == [420],
               "native invalid edit survives focus loss and cannot start the previous duration")
    }
    fixture.type("19")
    power.fail = true
    fixture.commands.start()
    fixture.settle()
    expect(fixture.text == "19" && awake.selectedMinutes == 19 && awake.remaining == 0 && power.requestedTimeouts == [420, 1140],
           "failed production Start preserves native text and explicit saved choice")
    power.fail = false
    fixture.commands.start()
    expect(awake.remaining == 1140 && power.requestedTimeouts == [420, 1140, 1140],
           "retrying actual Start after failure uses the unchanged native draft")
    model.onKeepAwakeStop()
    fixture.type("")
    fixture.close()
    expect(!fixture.commands.start() && awake.selectedMinutes == 19 && awake.remaining == 0,
           "removing or closing an invalid native editor revokes Start without committing or starting stale input")
    let reopened = AwakeNativeEditorFixture(model: model)
    expect(reopened.text == "19", "reopened native editor restores the last valid choice, not the invalid discarded edit")
    reopened.removeEditor()

    let setup = SetupDraft(current: model, defaults: defaults)
    let setupFixture = AwakeNativeEditorFixture(model: setup.controls, showsStart: false)
    setupFixture.type("23")
    setupFixture.leaveField()
    setupFixture.removeEditor()
    expect(setup.controls.keepAwakeMinutes == 23 && awake.selectedMinutes == 19 && !setupFixture.commands.start(),
           "native setup navigation commits only its staged duration and never starts or persists a live session")
    let invalidSetupFixture = AwakeNativeEditorFixture(model: setup.controls, showsStart: false)
    invalidSetupFixture.type("")
    invalidSetupFixture.leaveField()
    expect(invalidSetupFixture.text == "" && setup.controls.keepAwakeMinutes == 23,
           "invalid native setup edit remains visible after focus loss without replacing its last staged choice")
    invalidSetupFixture.removeEditor()
    expect(setup.controls.keepAwakeMinutes == 23 && awake.selectedMinutes == 19,
           "navigating away from an invalid native setup edit cannot persist a stale live choice")
    expect(setup.cancel(), "setup Cancel accepts the staged native edit")
    expect(defaults.integer(forKey: "keepAwake.minutes") == 19 && !awake.active,
           "canceling setup preserves the existing persisted duration and assertion state")
    withExtendedLifetime(host) {}
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
    actions.start(minutes: 1); actions.start(minutes: 1440)
    expect(calls == ["duration:1", "start:1", "duration:1440", "start:1440"], "custom duration accepts one minute through the 24-hour cap")
    calls.removeAll()
    for text in ["", "0", "-1", "1.5", "1441", "999999999999999999999999999999999", " 7", "7 ", "abc", "1e2"] {
        var draft = AwakeDurationDraft(minutes: 30)
        draft.text = text
        expect(draft.minutes == nil && !draft.commit(to: model) && !draft.commit(to: model, start: true),
               "invalid native numeric draft \(text) cannot commit or silently start the saved choice")
        expect(draft.text == text, "invalid numeric draft stays visible for correction")
    }
    expect(calls.isEmpty && model.keepAwakeMinutes == 1440, "invalid raw keyboard edits preserve the last valid choice")
    for text in ["1", "7", "42", "1440", "0007"] {
        var draft = AwakeDurationDraft(minutes: model.keepAwakeMinutes)
        draft.text = text
        expect(draft.commit(to: model, start: true), "raw integer keyboard input commits and starts")
        expect(calls.suffix(2) == ["duration:\(Int(text)!)", "start:\(Int(text)!)"], "typed custom Start uses its validated draft, not a stale selected duration")
    }
    expect(actions.recentDuration == 7, "only the last non-default choice is offered as a quick preset")
    actions.start(minutes: 30)
    expect(actions.recentDuration == nil, "default presets do not acquire a duplicate recent chip")
    calls.removeAll(); model.stoppingModules = [.keepAwake]
    actions.start(minutes: 30)
    expect(calls.isEmpty, "popup cannot start while feature recovery is stopping")
    expect(actions.status == "Inactive", "inactive popup does not imply indefinite protection")
    model.keepAwakeActive = true; model.keepAwakeRemaining = 61.1
    expect(actions.status == "1 min 02 sec left", "timed popup countdown rounds up seconds without losing remaining time")
    model.keepAwakeProtectionFailed = true
    expect(actions.status == "Protection needs retry", "protection failure takes precedence over a retained timed deadline")
    model.keepAwakeProtectionFailed = false; model.keepAwakeRemaining = 0; model.keepAwakeAppNames = ["Fixture app"]
    expect(actions.status == "Active · app rules", "app-only protection stays distinct from timed and inactive sessions")

    let suite = "fix-mac-os.popup-awake.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    let power = SetupPowerBackend()
    var clock: TimeInterval = 100
    let awake = KeepAwakeModule(defaults: defaults, backend: power, now: { clock }, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
    let hostModel = DashboardModel()
    let transactions = HostTransactions()
    let host = AppDelegate(model: hostModel, preferences: defaults, makeKeepAwake: { awake }, transactions: transactions)
    hostModel.onModuleChanged(.keepAwake, true)
    AwakeSessionActions(model: hostModel).start(minutes: 45)
    expect(awake.remaining == 2700 && awake.active && power.creates == 1, "production popup action reaches real host Start with fake assertions and selected preset")
    var typed = AwakeDurationDraft(minutes: 45)
    typed.text = "7"
    expect(awake.selectedMinutes == 45, "uncommitted numeric edits do not persist")
    typed.commit(to: hostModel)
    expect(awake.selectedMinutes == 7 && awake.remaining == 2700 && power.creates == 1,
           "committing a duration during a session saves only the next duration without changing active ownership")
    let recreated = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
    expect(recreated.selectedMinutes == 7 && !recreated.active && recreated.remaining == 0,
           "recreation restores a custom integer duration but never the active session")
    hostModel.onKeepAwakeExtend()
    expect(awake.remaining == 3600, "popup extension callback extends the owned timed session by fifteen minutes")
    power.failRenewal = true
    clock += 10
    awake.tick()
    let retainedRemaining = awake.remaining
    let renewalsBeforeRetry = power.renewals
    AwakeSessionActions(model: hostModel).retry()
    expect(power.renewals == renewalsBeforeRetry + 1 && awake.remaining == retainedRemaining && awake.protectionFailed,
           "user Retry immediately attempts failed renewal without replacing its retained deadline")
    power.failRenewal = false
    clock += 5
    AwakeSessionActions(model: hostModel).retry()
    expect(power.renewals == renewalsBeforeRetry + 2 && awake.remaining == retainedRemaining - 5 && !awake.protectionFailed,
           "successful user Retry preserves elapsed time instead of granting a fresh duration")
    hostModel.onKeepAwakeStop()
    expect(!awake.active && awake.remaining == 0, "popup End session callback releases timed ownership through the host")
    typed.commit(to: hostModel, start: true)
    expect(awake.remaining == 420 && hostModel.keepAwakeMinutes == 7 && AwakeSessionActions(model: hostModel).recentDuration == 7,
           "production custom Start uses raw committed seven-minute input and offers its recent preset")
    hostModel.onKeepAwakeStop()
    AwakeSessionActions(model: hostModel).start(minutes: 120)
    let afterPreset = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
    expect(afterPreset.selectedMinutes == 120 && AwakeSessionActions(model: hostModel).recentDuration == nil,
           "successful quick preset start persists across recreation without a duplicate recent chip")
    hostModel.onKeepAwakeStop()
    power.fail = true
    typed.text = "13"
    typed.commit(to: hostModel, start: true)
    expect(awake.selectedMinutes == 13 && hostModel.keepAwakeMinutes == 13 && typed.text == "13" && awake.remaining == 0,
           "failed custom Start retains its explicit duration and draft instead of resetting to a preset")
    typed.text = ""
    let createsBeforeInvalid = power.creates
    expect(!typed.commit(to: hostModel, start: true) && power.creates == createsBeforeInvalid && awake.selectedMinutes == 13,
           "invalid custom Start after a backend failure cannot restart the previous duration")
    expect(awake.protectionFailed && AwakeSessionActions(model: hostModel).status == "Protection needs retry", "failed production Start never renders a healthy countdown")
    power.fail = false
    hostModel.onKeepAwakeStop()
    try? awake.deactivate()
    AwakeSessionActions(model: hostModel).start(minutes: 30)
    let beforeClosedRetry = power.renewals + power.creates
    let quit = HostTransactions.QuitActions(isBusy: { false }, prepareMouse: { true }, quiesce: {}, prepareClipboard: { true }, needsDisplayRecovery: { false }, restoreDisplays: { _ in }, suspendSpaces: nil, resumeClipboard: {}, restoreSpacesChoice: {}, didReopen: {}, didVeto: { _ in })
    _ = transactions.requestQuit(quit, reply: { _ in })
    hostModel.onKeepAwakeRetry()
    expect(awake.remaining == 1800 && !transactions.acceptsActions && power.renewals + power.creates == beforeClosedRetry,
           "production Retry callback respects HostTransactions admission without invoking application quit")
    try? awake.stop()
    defaults.set(["fixture.app": "Fixture app"], forKey: "keepAwake.apps")
    let appPower = SetupPowerBackend()
    let appAwake = KeepAwakeModule(defaults: defaults, backend: appPower, now: { clock }, automaticUpdates: false,
                                  runningApps: { ["fixture.app": "Fixture app"] }, processInstances: { ["fixture.app": [42]] })
    appAwake.activate()
    try? appAwake.stop()
    try? appAwake.start()
    appPower.failRenewal = true; appAwake.tick()
    let pausedRemaining = appAwake.remaining
    appPower.failRenewal = false
    try? appAwake.retry()
    expect(appAwake.appsPaused && appAwake.activeAppNames.isEmpty && appAwake.remaining == pausedRemaining,
           "explicit Retry preserves paused app intent alongside its timed deadline")
    try? appAwake.deactivate()
    withExtendedLifetime(host) {}
}

private final class PopupFixtureHost {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PopupSizing.width, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
    private(set) var resizeEvents: [NSSize] = []
    init(model: DashboardModel, dark: Bool = false) {
        let view = NSHostingView(rootView: QuickActionsView(model: model, onResize: { [weak self] size in
            DispatchQueue.main.async { [weak self] in
                guard let self, window.contentLayoutRect.size != size else { return }
                resizeEvents.append(size)
                window.setContentSize(size)
            }
        }))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.frame = window.contentView!.bounds
    }
    func settle() {
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    @discardableResult func scrollToBottom() -> Bool {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let view = window.contentView, let scroll = find(view), let document = scroll.documentView,
              document.bounds.height > scroll.contentView.bounds.height else { return false }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        return scroll.contentView.bounds.origin.y > 0
    }
}

private func runPopupSizingTests() {
    expect(PopupSizing(contentHeight: 80, chromeHeight: 76, availableHeight: 650).height == 160,
           "empty popup has a reasonable compact floor rather than screen-height whitespace")
    expect(PopupSizing(contentHeight: 240, chromeHeight: 76, availableHeight: 650).height == 316,
           "short popup follows its measured content plus chrome")
    let long = PopupSizing(contentHeight: 2000, chromeHeight: 76, availableHeight: 500)
    expect(long.height == 500 && long.viewportHeight == 424, "long popup bounds only its scroll viewport to available screen height")
    expect(PopupSizing(contentHeight: 2000, chromeHeight: 76, availableHeight: 1200).height == 650,
           "large screens retain the popup maximum height")
    expect(PopupSizing(contentHeight: 0, chromeHeight: 76, availableHeight: 120).height == 120,
           "available screen space takes precedence over the empty-state floor")

    _ = NSApplication.shared
    let model = DashboardModel(); model.watchdogReady = true
    model.widgetLayout = WidgetLayout()
    model.enabledModules = [.keepAwake, .audio, .clipboard, .bluetooth]
    let host = PopupFixtureHost(model: model)
    host.settle()
    let empty = host.window.contentLayoutRect.height
    expect((160...220).contains(empty), "actual empty SwiftUI popup resizes its native fixture window to compact content")
    model.widgetLayout.entries = [.init(.keepAwake)]
    host.settle()
    let short = host.window.contentLayoutRect.height
    expect(short > empty && short < 350, "adding a real quick widget grows the native popup without filling its screen cap")
    model.keepAwakeActive = true; model.keepAwakeCanStop = true; model.keepAwakeRemaining = 1800
    model.keepAwakeAppNames = ["Fixture app one", "Fixture app two"]
    model.keepAwakeAppsPaused = true
    host.settle()
    expect(host.window.contentLayoutRect.height > short, "active session reasons and Resume grow the actual native popup")
    model.keepAwakeProtectionFailed = true; model.errorMessage = "Fixture recovery requires retry."
    host.settle()
    let recovery = host.window.contentLayoutRect.height
    expect(recovery > short, "global recovery participates in measured popup content")
    model.widgetLayout.entries = WidgetKind.allCases.map { WidgetEntry($0, expanded: true) }
    model.popupWidgetEditor.begin(model.widgetLayout)
    host.settle()
    expect(host.window.contentLayoutRect.height == model.popupHeight, "long real widget editor caps the native window and leaves content scrollable")
    expect(host.scrollToBottom(), "bounded real widget editor scrolls its owned native document to reveal offscreen controls")
    model.popupHeight = 300
    host.settle()
    expect(host.window.contentLayoutRect.height == 300, "open editor responds to a smaller available-screen bound")
    model.popupHeight = 580
    host.settle()
    expect(host.window.contentLayoutRect.height == 580, "restoring the bound regrows a long popup without measuring its previous viewport as content")
    model.popupWidgetEditor.cancel(); model.widgetLayout.entries.removeAll()
    model.keepAwakeActive = false; model.keepAwakeCanStop = false; model.keepAwakeRemaining = 0
    model.keepAwakeProtectionFailed = false; model.errorMessage = nil
    host.settle()
    expect(host.window.contentLayoutRect.height == empty, "removing widgets and recovery shrinks native popup back to the same empty height")
    let events = host.resizeEvents.count
    host.settle()
    expect(host.resizeEvents.count == events && events < 30, "content-sized native popup settles without resize feedback oscillation")
    host.window.orderOut(nil)
}

/// Explicit snapshot route: only a fresh model and a window owned by this test
/// process. No AppDelegate, clipboard, host modules, permissions or screen capture.
func renderCompactUIFixtures(directory: String) throws {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for dark in [false, true] {
        for scenario in ["inactive", "active", "retry", "recovery", "editing", "editing-bottom", "empty", "short", "long", "long-bottom"] {
            let active = scenario == "active" || scenario == "recovery" || scenario == "retry"
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
            if scenario == "retry" { model.keepAwakeProtectionFailed = true }
            if scenario == "recovery" {
                model.widgetLayout.entries.removeAll()
                model.keepAwakeProtectionFailed = true
                model.keepAwakeAppsPaused = true
                model.errorMessage = "Fixture: assertion release needs retry."
            }
            if scenario == "empty" { model.widgetLayout.entries.removeAll() }
            if scenario.hasPrefix("editing") { model.popupWidgetEditor.begin(model.widgetLayout) }
            if scenario == "short" { model.widgetLayout.entries = [.init(.keepAwake)] }
            if scenario.hasPrefix("long") {
                model.widgetLayout.entries = WidgetKind.allCases.map { WidgetEntry($0, expanded: true) }
                model.keepAwakeAppsPaused = true
                model.keepAwakeAppNames = Array(repeating: "Fixture presentation app with a long name", count: 8)
                model.errorMessage = "Fixture recovery: a long message wraps at the popup's fixed width; no live devices are accessed."
            }
            let host = PopupFixtureHost(model: model, dark: dark)
            host.settle()
            if scenario.hasSuffix("-bottom") { host.scrollToBottom(); host.settle() }
            let window = host.window
            let view = window.contentView!
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
