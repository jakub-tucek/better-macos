import AppKit
import IOKit.pwr_mgt

private final class FeaturePower: PowerAssertionBackend {
    var calls: [String] = []
    var owned = Set<IOPMAssertionID>()
    var nextID: IOPMAssertionID = 0
    var failCreate = false
    var failRenewal = false
    var failRelease = false

    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID {
        calls.append("create \(display) \(timeout)")
        if failCreate { throw ToggleError(message: "Feature create failure") }
        nextID += 1; owned.insert(nextID); return nextID
    }
    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws {
        calls.append("renew \(id) \(seconds)")
        if failRenewal { throw ToggleError(message: "Feature renewal failure") }
    }
    func release(_ id: IOPMAssertionID) throws {
        calls.append("release \(id)")
        if failRelease { throw ToggleError(message: "Feature release failure") }
        owned.remove(id)
    }
}

func runKeepAwakeFeatureTests() {
    runAwakeFeatureOwnershipTests()
    runAwakeFeatureFailureOrderingTests()
    runAwakeFeatureHostAdmissionTests()
    runAwakeFeatureLifetimeTests()
    runKeepAwakePaletteTests()
}

private func runKeepAwakePaletteTests() {
    let suite = "better-macos.awake-palette.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let power = FeaturePower()
    var admitted = true
    let model = DashboardModel(); model.enabledModules = [.keepAwake]
    let presentation = KeepAwakePresentation(model: model, acceptsActions: { admitted }, chooseApps: { $0([]) })
    let feature = KeepAwakeFeature(makeOwner: {
        KeepAwakeModule(defaults: defaults, backend: power, now: { 100 }, automaticUpdates: false,
                        runningApps: { [:] }, processInstances: { [:] })
    }, acceptsActions: { admitted }, publish: { presentation.publish($0) }, reportError: { model.errorMessage = $0.localizedDescription })
    presentation.bind(feature); feature.reconcile(enabled: true)
    defer { feature.shutdown() }
    let controller = KeepAwakePaletteController()
    let panel = controller.show(model: model, orderFront: false)
    let initial = AwakeSessionActions.presets.firstIndex(of: model.keepAwakeMinutes) ?? 0
    expect(power.calls.isEmpty && !model.keepAwakeActive, "opening sleep palette neither starts a session nor changes power assertions")
    func key(_ code: UInt16, _ text: String) {
        panel.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil, characters: text,
                                           charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
    }
    key(124, "\u{f703}")
    expect(power.calls.isEmpty, "sleep palette arrow selection is preview-only")
    key(36, "\r")
    let minutes = AwakeSessionActions.presets[(initial + 1) % AwakeSessionActions.presets.count]
    expect(model.keepAwakeActive && model.keepAwakeRemaining == Double(minutes * 60) && power.owned.count == 1,
           "native sleep palette Return starts selected duration through the production feature")
    let actions = KeepAwakePaletteActions(model: model)
    actions.perform(.display(true))
    expect(model.keepDisplayAwake && power.owned.count == 2, "sleep palette display switch uses existing assertion policy")
    actions.perform(.extend)
    expect(model.keepAwakeRemaining == Double((minutes + 15) * 60), "sleep palette extension uses existing session deadline")
    key(53, "\u{1b}")
    expect(!controller.isPresented && model.keepAwakeActive && power.owned.count == 2,
           "closing sleep palette keeps the active session running")
    admitted = false
    let before = power.calls.count
    let beforePreferences = defaults.dictionaryRepresentation()
    actions.perform(.start(120)); actions.perform(.display(false)); actions.perform(.end)
    expect(power.calls.count == before && NSDictionary(dictionary: beforePreferences).isEqual(to: defaults.dictionaryRepresentation()),
           "palette callbacks cannot change assertions or preferences after host admission closes")
    admitted = true
    power.failRelease = true
    actions.perform(.end)
    expect(!power.owned.isEmpty && model.keepAwakeCanStop && model.errorMessage == "Feature release failure",
           "sleep palette preserves failed release with its error and an available End session retry")
    power.failRelease = false
    actions.perform(.end)
    expect(power.owned.isEmpty && !model.keepAwakeActive && model.keepAwakeRemaining == 0,
           "allow sleep retries cleanup and ends the session without requesting immediate system sleep")
    model.enabledModules = []
    let afterStop = power.calls.count
    actions.perform(.start(30))
    expect(power.calls.count == afterStop, "disabled Keep awake cannot be started from the palette action seam")
}

private func runAwakeFeatureOwnershipTests() {
    let suite = "better-macos.awake-feature-ownership.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let power = FeaturePower()
    var discoveries = 0
    let owners = (0..<2).map { _ in
        KeepAwakeModule(defaults: defaults, backend: power, now: { 100 }, automaticUpdates: false,
            runningApps: { discoveries += 1; return [:] }, processInstances: { [:] })
    }
    var constructions = 0
    var admitted = true
    var states: [KeepAwakeFeature.State] = []
    var errors: [String] = []
    let feature = KeepAwakeFeature(makeOwner: {
        let owner = owners[min(constructions, 1)]; constructions += 1; return owner
    }, acceptsActions: { admitted }, publish: { states.append($0) }, reportError: { errors.append($0.localizedDescription) })
    expect(!feature.state.loaded && constructions == 0, "awake adapter construction is inert")
    feature.reconcile(enabled: false)
    feature.perform(.start)
    expect(constructions == 0 && power.calls.isEmpty && states.last == KeepAwakeFeature.State(), "disabled reconciliation and unloaded actions never construct an awake owner")
    if case .success = feature.prepareDisable() {} else { expect(false, "unloaded disable succeeds") }
    if case .failed(let detail) = feature.configureForSetup(minutes: 9, display: true, apps: [:]) {
        expect(detail.contains("unavailable"), "unloaded setup reports missing awake owner without constructing one")
    } else { expect(false, "unloaded setup must fail") }

    // Reconciliation is an admitted continuation even with action admission closed.
    admitted = false
    feature.reconcile(enabled: true)
    let firstDiscoveries = discoveries
    feature.reconcile(enabled: true)
    expect(constructions == 1 && discoveries == firstDiscoveries && feature.state.loaded, "awake reconciliation constructs and activates once, without re-entering admission")
    let beforeBlocked = defaults.dictionaryRepresentation()
    let beforeStates = states.count
    let actions: [KeepAwakeFeature.Action] = [.start, .retry, .stop, .extend, .resumeApps,
        .setMinutes(12), .setDisplay(true), .setApp(id: "fixture", name: "Fixture", selected: true),
        .setApp(id: "fixture", name: "fixture", selected: false)]
    for action in actions { feature.perform(action) }
    if case .failed(let detail) = feature.configureForSetup(minutes: 6, display: true, apps: ["fixture": "Fixture"]) {
        expect(detail == "Shutdown in progress.", "awake setup checks host admission itself")
    } else { expect(false, "closed awake setup must fail") }
    expect(NSDictionary(dictionary: beforeBlocked).isEqual(to: defaults.dictionaryRepresentation()) && power.calls.isEmpty && states.count == beforeStates && errors.isEmpty,
           "every direct awake action and setup is inert under closed admission")

    admitted = true
    feature.perform(.setMinutes(7))
    feature.perform(.setDisplay(true))
    feature.perform(.start)
    expect(feature.state.remaining == 420 && feature.state.active && power.owned.count == 2, "typed awake actions project both assertions and the original deadline")
    let oldChange = owners[0].onChange
    let oldError = owners[0].onError
    power.failRelease = true
    let beforeRefusal = discoveries
    if case .failure(let failure) = feature.prepareDisable() {
        expect(failure.detail == "Feature release failure", "awake disable returns original release failure")
    } else { expect(false, "awake failed release must refuse disable") }
    expect(constructions == 1 && discoveries > beforeRefusal && feature.state.active && power.owned.count == 2,
           "awake refusal reactivates the same owner and retains both failed assertion IDs")
    power.failRelease = false
    if case .success = feature.prepareDisable() {} else { expect(false, "awake disable retry succeeds") }
    feature.reconcile(enabled: false)
    expect(!feature.state.loaded && power.owned.isEmpty && states.last == KeepAwakeFeature.State(), "successful awake preparation releases before reconciliation publishes unloaded defaults")
    feature.reconcile(enabled: true)
    expect(constructions == 2 && feature.state.minutes == 7 && !feature.state.active && feature.state.remaining == 0,
           "awake re-enable uses factory again, restores choices but never starts a timed session")
    let published = states.count
    let reported = errors.count
    oldChange?(); oldError?(ToggleError(message: "stale owner"))
    owners[0].tick()
    expect(states.count == published && errors.count == reported && owners[0].onChange == nil && owners[0].onError == nil,
           "unloaded awake owner callbacks are detached and saved callbacks cannot publish or report")

    let secondChange = owners[1].onChange
    let secondError = owners[1].onError
    _ = feature.prepareDisable(); feature.reconcile(enabled: false); feature.reconcile(enabled: true)
    let afterReuse = states.count
    secondChange?(); secondError?(ToggleError(message: "stale generation"))
    expect(constructions == 3 && states.count == afterReuse && errors.count == reported, "callback generation rejects stale callbacks even when an injected factory reuses the same owner")
    feature.perform(.start)
    power.failRelease = true
    let beforeShutdownErrors = errors.count
    feature.shutdown()
    expect(feature.state.loaded && feature.state.active && !power.owned.isEmpty && errors.count == beforeShutdownErrors,
           "best-effort awake shutdown retains failed ownership without adding an error or veto policy")
    power.failRelease = false
    admitted = false
    feature.shutdown()
    expect(feature.state.loaded && !feature.state.active && power.owned.isEmpty, "awake shutdown cleanup remains available with admission closed")
}

private func runAwakeFeatureFailureOrderingTests() {
    let suite = "better-macos.awake-feature-errors.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let power = FeaturePower()
    var now: TimeInterval = 100
    let owner = KeepAwakeModule(defaults: defaults, backend: power, now: { now }, automaticUpdates: false,
        runningApps: { ["fixture.app": "Fixture app"] }, processInstances: { ["fixture.app": [42]] })
    var events: [String] = []
    let feature = KeepAwakeFeature(makeOwner: { owner }, acceptsActions: { true },
        publish: { events.append("state \($0.protectionFailed)") }, reportError: { events.append($0.localizedDescription) })
    feature.reconcile(enabled: true)
    power.failCreate = true
    events = []
    feature.perform(.start)
    expect(events == ["state true", "Feature create failure", "state true"] && feature.state.protectionFailed && feature.state.remaining == 0,
           "awake Start preserves owner publication, error, final projection ordering on creation failure")
    events = []
    let outcome = feature.configureForSetup(minutes: 11, display: true, apps: ["fixture.app": "Fixture app"])
    if case .failed(let detail) = outcome { expect(detail == "Feature create failure", "awake setup returns its existing assertion failure detail") }
    else { expect(false, "failed awake configuration must not claim applied") }
    expect(events == ["state true", "Feature create failure"] && feature.state.minutes == 11 && feature.state.remaining == 0 && feature.state.apps == ["fixture.app": "Fixture app"],
           "failed awake setup projects policy before reporting error and never creates a timed reason")
    power.failCreate = false
    _ = feature.configureForSetup(minutes: 11, display: true, apps: ["fixture.app": "Fixture app"])
    expect(feature.state.active && feature.state.remaining == 0 && !feature.state.protectionFailed, "awake setup retry reconciles existing app policy without a timed session")
    feature.perform(.stop)
    feature.perform(.start)
    now += 10
    power.failRenewal = true
    events = []
    owner.tick()
    expect(events == ["Feature renewal failure", "state true"], "awake asynchronous renewal preserves error-before-state publication ordering")
    let deadline = feature.state.remaining
    power.failRenewal = false
    feature.perform(.retry)
    expect(feature.state.remaining == deadline && feature.state.appsPaused && !feature.state.protectionFailed,
           "awake adapter Retry retains the deadline and paused app instances")
    feature.shutdown()
}

private func runAwakeFeatureHostAdmissionTests() {
    let suite = "better-macos.awake-feature-host.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ModuleSettings(defaults: defaults)
    for module in AppModule.allCases { settings.set(module, enabled: false) }
    let power = FeaturePower()
    let owner = KeepAwakeModule(defaults: defaults, backend: power, now: { 100 }, automaticUpdates: false,
        runningApps: { ["fixture.app": "Fixture app"] }, processInstances: { ["fixture.app": [42]] })
    let model = DashboardModel()
    let transactions = HostTransactions()
    var picks: [([KeepAwakePresentation.AppChoice]) -> Void] = []
    let mouse = MouseLifecycle(settings: settings, makeModule: { MouseModule(backend: FakeMouseBackend(), recovery: FakeMouseRecovery()) })
    let host = AppDelegate(mouseLifecycle: mouse, model: model, preferences: defaults, makeKeepAwake: { owner },
        chooseKeepAwakeApps: { picks.append($0) }, displayRecoveryPending: { false }, displaySnapshotRefresh: {}, transactions: transactions)
    model.onModuleChanged(.keepAwake, true)
    model.onKeepAwakeMinutesChanged(9)
    model.onKeepAwakeStart()
    model.onKeepAwakeAddApp()
    expect(picks.count == 1 && model.keepAwakeRemaining == 540 && model.keepAwakeActive, "production awake Dashboard bindings reach the typed owner and injected chooser")
    var drain: ((Bool) -> Void)?
    var replies: [Bool] = []
    let quit = HostTransactions.QuitActions(isBusy: { false }, prepareMouse: { true }, quiesce: {}, prepareClipboard: { true },
        needsDisplayRecovery: { true }, restoreDisplays: { drain = $0 }, suspendSpaces: nil,
        resumeClipboard: {}, restoreSpacesChoice: {}, didReopen: {}, didVeto: { _ in })
    expect(transactions.requestQuit(quit, reply: { replies.append($0) }) == .later, "awake admission fixture closes admission through the real host coordinator")
    let beforeCalls = power.calls
    let beforeDefaults = defaults.dictionaryRepresentation()
    model.onKeepAwakeStart(); model.onKeepAwakeRetry(); model.onKeepAwakeStop(); model.onKeepAwakeExtend(); model.onKeepAwakeResume()
    model.onKeepAwakeMinutesChanged(22); model.onKeepDisplayAwakeChanged(true)
    model.onKeepAwakeRemoveApp("fixture.app"); model.onKeepAwakeAddApp()
    picks[0]([.init(id: "fixture.app", name: "Fixture app")])
    model.onModuleChanged(.keepAwake, false)
    let draft = SetupDraft(current: model, defaults: defaults)
    draft.controls.keepAwakeMinutes = 22
    var setupResults: [String] = []
    model.onFinishSetup(draft) { setupResults = $0 }
    expect(picks.count == 1 && power.calls == beforeCalls && NSDictionary(dictionary: beforeDefaults).isEqual(to: defaults.dictionaryRepresentation()),
           "closed host admission blocks all awake bindings, chooser results, disable and Setup Finish without writes")
    expect(model.keepAwakeMinutes == 9 && model.keepAwakeRemaining == 540 && model.keepAwakeActive && settings.enabled.contains(.keepAwake) && setupResults.contains { $0.contains("shutting down") },
           "rejected awake actions retain the projected session, enabled choice and setup refusal")
    drain?(false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    expect(replies == [false] && transactions.acceptsActions, "canceled quit reopens admission for the same awake feature")
    model.onKeepAwakeMinutesChanged(13)
    model.onKeepAwakeAddApp()
    picks[1]([.init(id: "fixture.app", name: "Fixture app")])
    expect(model.keepAwakeMinutes == 13 && model.keepAwakeApps == ["fixture.app": "Fixture app"] && model.keepAwakeRemaining == 540,
           "reopened production bindings apply duration and chooser results without replacing the active timed reason")
    // Actual host quit approval still has no Keep Awake preparation/veto.
    power.failRelease = true
    expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateNow && owner.active,
           "host quit approval remains independent of awake cleanup failure; no new awake veto")
    power.failRelease = false
    try? owner.deactivate()
    withExtendedLifetime(host) {}
}

private func runAwakeFeatureLifetimeTests() {
    let suite = "better-macos.awake-feature-lifetime.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let power = FeaturePower()
    weak var releasedFeature: KeepAwakeFeature?
    weak var releasedOwner: KeepAwakeModule?
    weak var releasedPresentation: KeepAwakePresentation?
    let model = DashboardModel()
    do {
        let presentation = KeepAwakePresentation(model: model, acceptsActions: { true }, chooseApps: { $0([]) })
        let feature = KeepAwakeFeature(makeOwner: {
            let owner = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
            releasedOwner = owner
            return owner
        }, acceptsActions: { true }, publish: { [weak presentation] in presentation?.publish($0) }, reportError: { _ in })
        presentation.bind(feature)
        releasedFeature = feature; releasedPresentation = presentation
        feature.reconcile(enabled: true)
        model.onKeepAwakeStart()
        expect(power.owned.count == 1, "awake lifetime fixture owns one injected assertion")
        feature.shutdown()
    }
    expect(releasedFeature == nil && releasedOwner == nil && releasedPresentation == nil && power.owned.isEmpty,
           "awake owner, presentation, model callbacks and factory do not form retention cycles")
    model.onKeepAwakeStart(); model.onKeepAwakeAddApp()
    expect(power.owned.isEmpty, "surviving Dashboard callbacks cannot resurrect a destroyed awake feature")
}
