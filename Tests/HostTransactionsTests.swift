import Foundation
import AppKit

private final class JournalDisplayRunner: CommandRunning {
    let defaults: UserDefaults
    let restoreStarted = DispatchSemaphore(value: 0)
    let finishRestore = DispatchSemaphore(value: 0)
    var failRestore = false
    var failDisable = false
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        if arguments.first == "--set-display" {
            let record = DisplayRecord(uuid: "fixture", name: "Fixture", lastID: 1, bootSession: nil, disabledByApp: true)
            defaults.set(try JSONEncoder().encode([record]), forKey: "displayRecords")
            if failDisable { throw ToggleError(message: "Injected post-commit helper failure") }
        } else if arguments == ["--restore"] {
            restoreStarted.signal()
            finishRestore.wait()
            if failRestore { throw ToggleError(message: "Injected recovery failure") }
            defaults.removeObject(forKey: "displayRecords")
        } else { throw ToggleError(message: "Unexpected fixture command") }
        return ""
    }
}

private final class UnexpectedDisplayRunner: CommandRunning {
    let dispatched = DispatchSemaphore(value: 0)
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        dispatched.signal()
        return ""
    }
}

private func runDisplayWatchdogAdmissionTests() {
    runDelayedDisplayAuthorizationTests()
    for initiallyReady in [false, true] {
        let suite = "fix-mac-os.display-watchdog-admission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults)
        for module in AppModule.allCases { settings.set(module, enabled: module == .monitors) }
        let model = DashboardModel()
        let runner = UnexpectedDisplayRunner()
        var watchdogReady = initiallyReady
        let host = AppDelegate(commandRunner: runner, model: model, preferences: defaults,
            controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: watchdogReady, displaySettling: false) },
            displayRecoveryPending: { false }, displaySnapshotRefresh: {})
        watchdogReady = false // Covers both initial unavailability and supervision lost after host creation.
        model.onMonitorChanged("fixture", false)
        expect(runner.dispatched.wait(timeout: .now() + 0.1) == .timedOut && !model.monitorBusy && model.errorMessage != nil,
               "new display disable cannot dispatch with \(initiallyReady ? "lost" : "unavailable") watchdog supervision")
        withExtendedLifetime(host) {}
    }
}

private func runDelayedDisplayAuthorizationTests() {
    for action in ["off", "on", "restore"] {
        let suite = "fix-mac-os.delayed-display-authorization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults)
        for module in AppModule.allCases { settings.set(module, enabled: module == .monitors) }
        let original = Data("retained recovery journal".utf8)
        defaults.set(original, forKey: "displayRecords")
        let phases = RecordingPhases()
        defaults.set(TransitionSpeed.smooth.rawValue, forKey: "spaces.speed")
        let engine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: phases.post)
        let spaces = SpacesModule(defaults: defaults, engine: engine)
        let runner = UnexpectedDisplayRunner()
        let model = DashboardModel()
        var ready = true
        let host = AppDelegate(commandRunner: runner, spaces: spaces, model: model, preferences: defaults,
            controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: ready, displaySettling: false) },
            displayRecoveryPending: { true }, displaySnapshotRefresh: {})
        do { try engine.switchSpace(.right) } catch { expect(false, "fake gesture starts") }
        expect(phases.began.wait(timeout: .now() + 1) == .success, "\(action): fake gesture is blocked before display action")
        if action == "restore" { model.onRestoreAll() }
        else { model.onMonitorChanged("fixture", action == "on") }
        expect(model.monitorBusy && spaces.isDraining && runner.dispatched.wait(timeout: .now()) == .timedOut,
               "\(action): real host waits for terminal gesture phase before helper dispatch")
        ready = false
        phases.release.signal()
        let deadline = Date().addingTimeInterval(2)
        while model.monitorBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(!model.monitorBusy && !spaces.isDraining, "\(action): delayed helper outcome unwinds busy and drain state")
        expect((runner.dispatched.wait(timeout: .now()) == .success) == (action != "off"),
               "\(action): dispatch-time watchdog loss blocks only new disables, never On/Restore recovery")
        expect(defaults.data(forKey: "displayRecords") == original, "\(action): dispatch authorization never modifies journal ownership")
        if action == "off" {
            expect(model.errorMessage != nil && model.countdowns.isEmpty, "rejected disable surfaces failure without creating rollback ownership")
            ready = true
            model.onMonitorChanged("fixture", false)
            let retryDeadline = Date().addingTimeInterval(1)
            while model.monitorBusy && Date() < retryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(runner.dispatched.wait(timeout: .now()) == .success && !model.monitorBusy,
                   "rejected disable permits immediate supervised retry without stale barrier or rollback state")
        }
        spaces.stop()
        withExtendedLifetime(host) {}
    }
}

private final class JournalLoadingRestoreRunner: CommandRunning {
    let defaults: UserDefaults
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let discovered = DispatchSemaphore(value: 0)
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        guard arguments == ["--restore"] else { throw ToggleError(message: "Unexpected journal test command") }
        started.signal()
        finish.wait()
        try restoreFromCLI(try DisplayController(defaults: defaults, legacyDefaults: nil, discoverDisplays: { _ in self.discovered.signal() }))
        return ""
    }
}

private func runUnreadableDisplayJournalTests() {
    // Exercise production initialization plus the exact CLI restore routine, not
    // just the cheap host predicate. Inject discovery so even the buggy loader
    // cannot query graphics state during the red run.
    for legacy in [false, true] {
        for invalid: Any in [Data("broken journal".utf8), Data("{}".utf8), "wrong preference type"] {
            let suite = "fix-mac-os.unreadable-display-journal.\(UUID().uuidString)"
            let legacySuite = "fix-mac-os.unreadable-legacy-display-journal.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let legacyDefaults = UserDefaults(suiteName: legacySuite)!
            defer {
                defaults.removePersistentDomain(forName: suite)
                legacyDefaults.removePersistentDomain(forName: legacySuite)
            }
            let source = legacy ? legacyDefaults : defaults
            source.set(invalid, forKey: "displayRecords")
            // Legacy ownership and other metadata must survive as well.
            source.set(false, forKey: "disabledByApp")
            source.set("fixture", forKey: "targetUUID")
            source.set(1, forKey: "lastDisplayID")
            let original = source.persistentDomain(forName: legacy ? legacySuite : suite)!
            expect(DisplayController.hasPendingRecovery(defaults: source),
                   "unreadable journal types remain authoritative pending recovery")
            var discoveries = 0
            var failed = false
            do {
                try restoreFromCLI(try DisplayController(defaults: defaults, legacyDefaults: legacyDefaults,
                    discoverDisplays: { _ in discoveries += 1 }))
            } catch { failed = true }
            expect(failed && discoveries == 0,
                   "unreadable \(legacy ? "legacy" : "current") journal fails production helper initialization before discovery")
            expect(NSDictionary(dictionary: source.persistentDomain(forName: legacy ? legacySuite : suite)!).isEqual(to: original),
                   "production loader preserves unreadable journal bytes, type, and legacy ownership metadata")
            if legacy {
                expect(defaults.object(forKey: "displayRecords") == nil && defaults.object(forKey: "disabledByApp") == nil,
                       "unreadable legacy data is validated before any migration writes")
            }
        }
    }

    for legacy in [false, true] {
        let suite = "fix-mac-os.valid-display-loader.\(UUID().uuidString)"
        let legacySuite = "fix-mac-os.valid-legacy-display-loader.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            legacyDefaults.removePersistentDomain(forName: legacySuite)
        }
        let source = legacy ? legacyDefaults : defaults
        let record = DisplayRecord(uuid: "fixture", name: "Fixture", lastID: 1, bootSession: nil, disabledByApp: true)
        do {
            source.set(try JSONEncoder().encode([record]), forKey: "displayRecords")
            var discoveries = 0
            let controller = try DisplayController(defaults: defaults, legacyDefaults: legacyDefaults, discoverDisplays: { _ in discoveries += 1 })
            expect(controller.disabledUUIDs == ["fixture"] && discoveries == 1,
                   "valid \(legacy ? "legacy" : "current") production loader retains ownership and reaches injected discovery")
            let loaded = try DisplayController.loadRecords(defaults: defaults)
            expect(loaded.map(\.uuid) == ["fixture"],
                   "valid records remain persisted after initialization/migration")
        } catch { expect(false, "valid journal must still initialize and migrate: \(error)") }
    }

    for action in ["quit", "module"] {
        let suite = "fix-mac-os.unreadable-journal-host.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("unreadable display records".utf8)
        defaults.set(bytes, forKey: "displayRecords")
        let settings = ModuleSettings(defaults: defaults)
        for module in AppModule.allCases { settings.set(module, enabled: module == .monitors) }
        let mouse = MouseLifecycle(settings: settings, makeModule: { MouseModule(backend: FakeMouseBackend(), recovery: FakeMouseRecovery()) })
        let runner = JournalLoadingRestoreRunner(defaults)
        let model = DashboardModel()
        var replies: [Bool] = []
        let host = AppDelegate(commandRunner: runner, mouseLifecycle: mouse, model: model, preferences: defaults,
            controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: false, displaySettling: false) },
            displayRecoveryPending: { DisplayController.hasPendingRecovery(defaults: defaults) },
            displaySnapshotRefresh: {}, terminationReply: { _, approved in replies.append(approved) })
        if action == "quit" {
            expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateLater && replies.isEmpty,
                   "corrupt-journal quit waits for production helper initialization result")
        } else {
            model.onModuleChanged(.monitors, false)
            expect(model.stoppingModules.contains(.monitors) && settings.enabled.contains(.monitors),
                   "corrupt-journal module unload waits for production helper initialization result")
        }
        expect(runner.started.wait(timeout: .now() + 1) == .success, "corrupt-journal host requests recovery even without watchdog")
        runner.finish.signal()
        let deadline = Date().addingTimeInterval(1)
        while model.monitorBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(!model.monitorBusy && model.errorMessage != nil && settings.enabled.contains(.monitors),
               "production journal loading error refuses \(action) approval/unload and retains display module ownership")
        if action == "quit" { expect(replies == [false], "journal initialization error cancels quit rather than reporting false recovery success") }
        else { expect(model.stoppingModules.isEmpty, "journal initialization error leaves module available for retry") }
        expect(defaults.data(forKey: "displayRecords") == bytes && DisplayController.hasPendingRecovery(defaults: defaults),
               "host recovery failure retains exact corrupt bytes and durable pending ownership")
        expect(runner.discovered.wait(timeout: .now()) == .timedOut,
               "host helper rejects unreadable journal before graphics discovery")
        withExtendedLifetime(host) {}
    }
}

private func runDisplayOwnershipTests() {
    for scenario in ["quit", "quit-failure", "module", "module-failure", "keep", "helper-failure", "quit-watchdog-lost", "module-watchdog-lost"] {
        let suite = "fix-mac-os.display-ownership.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ModuleSettings(defaults: defaults)
        for module in AppModule.allCases { settings.set(module, enabled: module == .monitors) }
        let mouse = MouseLifecycle(settings: settings, makeModule: { MouseModule(backend: FakeMouseBackend(), recovery: FakeMouseRecovery()) })
        let runner = JournalDisplayRunner(defaults)
        runner.failRestore = scenario.hasSuffix("-failure") && scenario != "helper-failure"
        runner.failDisable = scenario == "helper-failure"
        let model = DashboardModel()
        model.confirmMonitorDisable = scenario == "keep"
        var replies: [Bool] = []
        var snapshots = 0
        var watchdogReady = true
        let host = AppDelegate(commandRunner: runner, mouseLifecycle: mouse, model: model, preferences: defaults,
            controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: watchdogReady, displaySettling: false) },
            displayRecoveryPending: { DisplayController.hasPendingRecovery(defaults: defaults) },
            displaySnapshotRefresh: { snapshots += 1 }, terminationReply: { _, approved in replies.append(approved) })
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(condition(), "\(scenario): fake helper completes without waiting for a display snapshot")
        }
        model.onMonitorChanged("fixture", false)
        wait { !model.monitorBusy }
        if scenario.hasSuffix("watchdog-lost") { watchdogReady = false }
        expect(DisplayController.hasPendingRecovery(defaults: defaults) && model.disabledMonitorCount == 0 && snapshots == 0,
               "\(scenario): successful helper journal precedes the deliberately stale dashboard snapshot")
        if scenario == "keep" { model.onKeepDisabled("fixture") }
        if scenario.hasPrefix("module") {
            model.onModuleChanged(.monitors, false)
            expect(settings.enabled.contains(.monitors) && model.stoppingModules.contains(.monitors),
                   "\(scenario): last display owner is not disabled before recovery finishes")
        } else {
            expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateLater && replies.isEmpty,
                   "\(scenario): immediate quit must wait for durable display ownership, including manual Keep")
        }
        expect(runner.restoreStarted.wait(timeout: .now() + 1) == .success,
               "\(scenario): recovery helper is requested before the deferred snapshot")
        // Let the centralized gate fire while recovery is blocked; it must not be canceled by module shutdown.
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        expect(snapshots == 1 && replies.isEmpty && settings.enabled.contains(.monitors),
               "\(scenario): discovery gate and owning module remain alive until recovery outcome")
        runner.finishRestore.signal()
        wait { !model.monitorBusy }
        if scenario.hasPrefix("module") {
            expect(settings.enabled.contains(.monitors) == runner.failRestore && model.stoppingModules.isEmpty,
                   "\(scenario): module shutdown follows recovery success, retaining failed ownership for retry")
        } else {
            wait { !replies.isEmpty }
            expect(replies == [!runner.failRestore], "\(scenario): quit approval follows recovery outcome exactly once")
        }
        expect(DisplayController.hasPendingRecovery(defaults: defaults) == runner.failRestore,
               "\(scenario): only successful restoration clears durable recovery ownership")
        if runner.failRestore {
            runner.failRestore = false
            if scenario.hasPrefix("module") { model.onModuleChanged(.monitors, false) }
            else {
                expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateLater,
                       "\(scenario): canceled quit can retry retained journal ownership")
            }
            expect(runner.restoreStarted.wait(timeout: .now() + 1) == .success,
                   "\(scenario): failed recovery remains retriable without deadlocking the helper queue")
            runner.finishRestore.signal()
            wait { !model.monitorBusy }
            if scenario.hasPrefix("module") {
                expect(!settings.enabled.contains(.monitors), "\(scenario): successful retry finally releases module ownership")
            } else {
                wait { replies.count == 2 }
                expect(replies == [false, true], "\(scenario): fresh quit approves only after successful retry")
            }
        }
        withExtendedLifetime(host) {}
    }

    let suite = "fix-mac-os.display-journal.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    expect(!DisplayController.hasPendingRecovery(defaults: defaults), "empty isolated journal owns no recovery")
    defaults.set(Data("corrupt".utf8), forKey: "displayRecords")
    expect(DisplayController.hasPendingRecovery(defaults: defaults), "malformed display records fail closed for recovery ownership")
    defaults.removeObject(forKey: "displayRecords")
    defaults.set(Data(), forKey: "pendingArrangement")
    expect(DisplayController.hasPendingRecovery(defaults: defaults), "pending arrangement journal owns recovery without a UI snapshot")
    defaults.removeObject(forKey: "pendingArrangement")
    defaults.set(true, forKey: "disabledByApp")
    expect(DisplayController.hasPendingRecovery(defaults: defaults), "legacy disable journal still owns recovery")
    defaults.removeObject(forKey: "disabledByApp")
    let settings = ModuleSettings(defaults: defaults)
    for module in AppModule.allCases { settings.set(module, enabled: false) }
    let model = DashboardModel(); model.disabledMonitorCount = 1; model.pendingArrangement = true
    let mouse = MouseLifecycle(settings: settings, makeModule: { MouseModule(backend: FakeMouseBackend(), recovery: FakeMouseRecovery()) })
    let host = AppDelegate(mouseLifecycle: mouse, model: model, preferences: defaults,
        displayRecoveryPending: { DisplayController.hasPendingRecovery(defaults: defaults) })
    expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
           "stale UI recovery indicators cannot invent ownership after the durable journal is clear")
}

private final class QuitFixture {
    let host = HostTransactions()
    var busy = false
    var mouseClean = true
    var clipboardClean = true
    var recovery = false
    var hasSpaces = true
    var events: [String] = []
    var drains: [(Bool) -> Void] = []
    var replies: [Bool] = []
    var vetoes: [HostTransactions.Veto] = []
    var readinessRefreshes = 0
    var onMouse: (() -> Void)?
    var onResume: (() -> Void)?
    var onVeto: (() -> Void)?
    var inlineDrain = false

    @discardableResult func request() -> HostTransactions.Decision {
        let actions = HostTransactions.QuitActions(
            isBusy: { self.events.append("busy"); return self.busy },
            prepareMouse: { self.events.append("mouse"); self.onMouse?(); return self.mouseClean },
            quiesce: { self.events.append("quiesce") },
            prepareClipboard: { self.events.append("clipboard"); return self.clipboardClean },
            needsDisplayRecovery: { self.recovery },
            restoreDisplays: { self.events.append("displays"); self.drains.append($0); if self.inlineDrain { $0(true) } },
            suspendSpaces: hasSpaces ? { done in
                self.events.append("spaces"); self.drains.append { _ in done() }
                if self.inlineDrain { done() }
            } : nil,
            resumeClipboard: { self.events.append("resume clipboard"); self.onResume?() },
            restoreSpacesChoice: { self.events.append("restore spaces choice") },
            didReopen: { self.readinessRefreshes += 1; self.onVeto?() },
            didVeto: { self.vetoes.append($0) })
        return host.requestQuit(actions) { self.replies.append($0) }
    }

    func deliver(_ approved: Bool = true, index: Int = 0) {
        drains[index](approved)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

func runHostTransactionsTests() {
    runDisplayWatchdogAdmissionTests()
    runUnreadableDisplayJournalTests()
    runDisplayOwnershipTests()
    for veto in ["busy", "mouse", "clipboard"] {
        let fixture = QuitFixture()
        fixture.busy = veto == "busy"
        fixture.mouseClean = veto != "mouse"
        fixture.clipboardClean = veto != "clipboard"
        expect(fixture.request() == .cancel && fixture.host.acceptsActions && fixture.replies.isEmpty,
               "initial \(veto) veto cancels synchronously and reopens host admission")
        let expected = veto == "busy" ? ["busy"] : veto == "mouse" ? ["busy", "mouse"] :
            ["busy", "mouse", "quiesce", "clipboard", "resume clipboard"]
        expect(fixture.events == expected, "initial \(veto) veto preserves feature preparation ordering and untouched later features")
        expect(fixture.readinessRefreshes == (veto == "clipboard" ? 1 : 0),
               "initial \(veto) veto only reconciles readiness when cleanup actually quiesced features")
    }

    let immediate = QuitFixture()
    immediate.hasSpaces = false
    expect(immediate.request() == .now && !immediate.host.acceptsActions && immediate.replies.isEmpty,
           "host without asynchronous cleanup approves immediately and stays closed")
    let immediateEvents = immediate.events
    expect(immediate.request() == .later && immediate.events == immediateEvents,
           "repeated approved quit never runs feature preparation again")

    let inline = QuitFixture()
    inline.inlineDrain = true
    expect(inline.request() == .later && inline.replies.isEmpty && !inline.host.acceptsActions,
           "inline Spaces drain cannot reply before the host returns terminate-later")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    expect(inline.replies == [true] && !inline.host.acceptsActions,
           "inline drain receives exactly one deferred approval")

    for failure in ["mouse", "clipboard", "busy", "recovery", "none"] {
        let fixture = QuitFixture()
        fixture.recovery = true
        var reentrantDecisions: [HostTransactions.Decision] = []
        fixture.onMouse = {
            expect(!fixture.host.acceptsActions, "host admission is closed inside feature preparation")
            reentrantDecisions.append(fixture.request())
        }
        expect(fixture.request() == .later && fixture.events == ["busy", "mouse", "quiesce", "clipboard", "displays"],
               "display recovery takes precedence over a separate Spaces drain")
        let beforeRepeated = fixture.events
        expect(fixture.request() == .later && fixture.events == beforeRepeated && fixture.drains.count == 1,
               "repeated quit during blocked recovery neither drains twice nor registers another reply")
        var mutations = 0
        let lateAction = { if fixture.host.acceptsActions { mutations += 1 } }
        lateAction()
        expect(mutations == 0 && fixture.replies.isEmpty, "retained actions cannot mutate during blocked recovery")
        fixture.mouseClean = failure != "mouse"
        fixture.clipboardClean = failure != "clipboard"
        fixture.busy = failure == "busy"
        fixture.onResume = {
            lateAction()
            expect(!fixture.host.acceptsActions && fixture.request() == .later,
                   "cancellation keeps admission closed while feature monitoring is reopened")
        }
        fixture.onVeto = {
            expect(fixture.host.acceptsActions, "canceled quit reconciles host readiness only after reopening admission")
        }
        fixture.deliver(failure != "recovery")
        expect(fixture.events.contains("clipboard") && Array(fixture.events.dropFirst(5).prefix(3)) == ["mouse", "clipboard", "busy"],
               "final \(failure) result rechecks Mouse, Clipboard and host transactions after recovery")
        expect(reentrantDecisions == [.later, .later], "reentrant feature callbacks cannot initiate a competing quit attempt")
        expect(fixture.replies == [failure == "none"] && fixture.host.acceptsActions == (failure != "none"),
               "final \(failure) result approves closed or cancels reopened exactly once")
        lateAction()
        expect(mutations == (failure == "none" ? 0 : 1), "late actions follow final \(failure) admission decision")
        let finishedEvents = fixture.events
        fixture.deliver()
        expect(fixture.replies.count == 1 && fixture.events == finishedEvents,
               "duplicate recovery callback cannot recheck or reply after final \(failure) decision")
        if failure != "none" {
            fixture.mouseClean = true; fixture.clipboardClean = true; fixture.busy = false
            expect(fixture.request() == .later && fixture.drains.count == 2,
                   "canceled \(failure) attempt allows a fresh quit")
            fixture.deliver(index: 0)
            expect(fixture.replies.count == 1 && !fixture.host.acceptsActions,
                   "stale callback from canceled attempt cannot finish the fresh quit")
            fixture.deliver(index: 1)
            expect(fixture.replies == [false, true] && !fixture.host.acceptsActions,
                   "fresh quit after \(failure) cancellation approves independently")
        }
        // Fixture hooks intentionally capture it during adversarial reentrancy.
        fixture.onMouse = nil; fixture.onResume = nil; fixture.onVeto = nil
        fixture.drains = []
    }

    let clipboard = QuitFixture()
    clipboard.request()
    clipboard.clipboardClean = false
    clipboard.mouseClean = false
    clipboard.deliver()
    expect(clipboard.vetoes == [.clipboard] && clipboard.events.suffix(2) == ["resume clipboard", "restore spaces choice"],
           "late Clipboard veto takes presentation priority while canceled Spaces suspension restores saved choice")
    clipboard.clipboardClean = true; clipboard.mouseClean = true
    clipboard.request()
    clipboard.deliver(index: 1)
    expect(clipboard.replies == [false, true] && !clipboard.host.acceptsActions,
           "Spaces retry shares the same final checks and approved admission as display recovery")
    clipboard.drains = []
}
