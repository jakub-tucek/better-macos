import AppKit
import IOKit.pwr_mgt

func runActivityTests() throws {
    let journal = ActivityJournal(capacity: 3, now: { Date(timeIntervalSince1970: 123) })
    let presentation = ActivityPresentation(journal: journal)
    let first = journal.begin(.windowSave, trigger: .user)
    let second = journal.begin(.windowRestore, trigger: .automatic)
    journal.finish(first, result: .windowsSaved(7))
    journal.finish(first, result: .failed)
    expect(journal.entries.map(\.id) == [second, first] && journal.entries.last?.result == .windowsSaved(7), "activity completion preserves start ordering and immutable results")
    expect(presentation.entries == journal.entries && journal.entries[0].startedAt == Date(timeIntervalSince1970: 123), "activity dedicated presentation observes the injected session clock")
    _ = journal.begin(.awakeStart(10), trigger: .user)
    _ = journal.begin(.displayPower(false), trigger: .user)
    journal.finish(first, result: .completed)
    expect(journal.entries.count == 3 && !journal.entries.contains(where: { $0.id == first }), "activity bounds pending and finished rows and ignores evicted completions")
    journal.clear(); journal.finish(second, result: .completed)
    expect(journal.entries.isEmpty && presentation.entries.isEmpty, "activity clear invalidates late completions and presentation together")
    let bounded = ActivityJournal(capacity: 999)
    for _ in 0..<1000 { _ = bounded.begin(.bluetoothPower, trigger: .user) }
    expect(bounded.entries.count == 300, "activity hard cap cannot be enlarged by a caller")
    try runActivityWindowOwnerTests()
    try runActivityAwakeTests()
    runActivityBluetoothTests()
    runActivityDisplayTests()
    runActivityNativeWindowTests()
}

private func runActivityWindowOwnerTests() throws {
    let suite = "fix-mac-os.activity-windows.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let journal = ActivityJournal()
    let backend = FakeWindowBackend()
    backend.items = [PositionedWindow(token: "PRIVATE_TOKEN", app: "PRIVATE_APP", title: "PRIVATE_TITLE", frame: CGRect(x: 10, y: 30, width: 200, height: 200), supported: true)]
    var queued: [() -> Void] = []
    let owner = WindowPositions(backend: backend, defaults: defaults, schedule: { queued.append($0) })
    owner.activity = journal
    owner.reconcile(ready: true, settled: true)
    owner.save("PRIVATE_LAYOUT")
    expect(journal.entries.first?.result == .windowsSaved(1), "window owner records captured count without user labels")
    let selected = owner.selected
    owner.restore(selected)
    expect(journal.entries.first?.result == nil, "window owner leaves queued restoration Started, not successful")
    owner.invalidate()
    while !queued.isEmpty { queued.removeFirst()() }
    expect(journal.entries.first?.result == .windowsCanceled(0) && backend.moves.isEmpty, "window generation invalidation finalizes canceled activity before queued moves")
    owner.reconcile(ready: true, settled: true)
    owner.restore(selected, trigger: .automatic)
    while !queued.isEmpty { queued.removeFirst()() }
    expect(journal.entries.first?.result == .windowsRestored(ActivityWindowCounts(restored: 1)) && journal.entries.first?.trigger == .automatic, "window restore records confirmed non-parking moves and explicit automatic cause")
    backend.succeeds = false
    owner.restore(selected)
    while !queued.isEmpty { queued.removeFirst()() }
    expect(journal.entries.first?.result == .windowsRestored(ActivityWindowCounts(failed: 1)), "window failed readback contributes failure, not a restored count")
    backend.succeeds = true
    backend.items[0].supported = false
    owner.restore(selected)
    expect(journal.entries.first?.result == .windowsRestored(ActivityWindowCounts(unsupported: 1)), "unsupported window is reported separately")
    backend.items[0].supported = true
    backend.items.append(backend.items[0])
    owner.restore(selected)
    expect(journal.entries.first?.result == .windowsRestored(ActivityWindowCounts(ambiguous: 1)), "ambiguous window match is not claimed as moved")
    owner.exclusions = "PRIVATE_APP"
    owner.restore(selected)
    expect(journal.entries.first?.result == .windowsRestored(ActivityWindowCounts(excluded: 1)), "excluded windows stay distinct from failures and missing matches")
    owner.exclusions = ""
    backend.items = []
    owner.restore(selected)
    expect(journal.entries.first?.result == .windowsRestored(ActivityWindowCounts(missing: 1)), "missing saved window is partial, not a successful move")
    backend.permitted = false
    owner.restore(selected)
    expect(journal.entries.first?.result == .blocked, "window permission failure never claims restoration")
    let descriptions = journal.entries.map { "\($0.event.title) \($0.details)" }.joined()
    expect(!descriptions.contains("PRIVATE"), "window activity payloads exclude app identities, titles, tokens and layout names")
    let saved = defaults.data(forKey: "windows.layouts")
    journal.clear()
    expect(defaults.data(forKey: "windows.layouts") == saved && owner.layouts.count == 1, "clearing activity preserves saved feature data")
}

private func runActivityAwakeTests() throws {
    let suite = "fix-mac-os.activity-awake.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let backend = FakePowerAssertions()
    var clock: TimeInterval = 100
    let journal = ActivityJournal()
    let owner = KeepAwakeModule(defaults: defaults, backend: backend, now: { clock }, automaticUpdates: false,
        runningApps: { ["PRIVATE_APP": "PRIVATE_APP_NAME"] }, processInstances: { [:] })
    owner.onActivity = { journal.record($0, trigger: $1, result: $2) }
    owner.selectedMinutes = 1
    try owner.start()
    expect(journal.entries.first?.event == .awakeStart(1) && journal.entries.first?.result == .completed, "awake start records actual assertion success")
    let count = journal.entries.count
    for _ in 0..<20 { clock += 1; owner.tick() }
    expect(journal.entries.count == count, "awake countdown publication creates no journal spam")
    try owner.setApp("PRIVATE_APP", name: "PRIVATE_APP_NAME", selected: true)
    owner.activate()
    clock += 60; owner.tick()
    expect(journal.entries.contains(where: { $0.result == .expired(appRuleActive: true) }), "awake expiry distinguishes continuing app-rule protection")
    backend.failRelease = backend.entries.keys.first
    do { try owner.stop(); expect(false, "awake stop fixture must fail") } catch {}
    expect(journal.entries.first?.result == .cleanupNeeded && owner.active, "awake release failure records cleanup needed and preserves feature ownership")
    backend.failRelease = nil
    try owner.retry()
    expect(journal.entries.first?.event == .awakeRetry && journal.entries.first?.result == .completed, "awake retry records its actual result")
    try owner.stop()
    backend.failCreate = true
    do { try owner.start(); expect(false, "awake creation fixture must fail") } catch {}
    expect(journal.entries.first?.event == .awakeStart(1) && journal.entries.first?.result == .failed, "awake failed start is never shown as completed")
    expect(!journal.entries.map { "\($0.event.title) \($0.details)" }.joined().contains("PRIVATE"), "awake activity never retains app identities or labels")
    backend.failCreate = false
    try owner.deactivate()
}

private func runActivityNativeWindowTests() {
    _ = NSApplication.shared
    let suite = "fix-mac-os.activity-window.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let journal = ActivityJournal()
    let model = DashboardModel()
    var presented: [NSWindow] = []
    let host = AppDelegate(model: model, preferences: defaults, presentWindow: { presented.append($0) }, activity: journal)
    journal.record(.displayRecovery(.timeout), trigger: .recovery, result: .failed)
    model.onOpenActivity()
    expect(presented.count == 1 && presented[0].title == "Fix macOS — Activity" && presented[0].styleMask.contains(.resizable), "activity action creates a dedicated resizable native window through injected presentation")
    presented[0].close(); model.onOpenActivity()
    expect(presented.count == 2 && presented[0] === presented[1] && journal.entries.count == 1, "activity reopen reuses its native window and retains session history")
    for _ in 0..<60 { journal.record(.awakeStart(10), trigger: .user, result: .completed) }
    let content = presented[0].contentView!
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let scrolls = scrollViews(content)
    expect(!scrolls.isEmpty, "activity native hosting mounts its scrollable history")
    if let scroll = scrolls.first {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 250)); scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        journal.record(.awakeStop, trigger: .user, result: .completed)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(scroll.contentView.bounds.minY > 100, "activity native history reading is not reset to top when a new entry arrives")
    }
    presented[0].close()
    withExtendedLifetime(host) {}
}

private func activityWait(_ done: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    expect(done(), "activity fixture finishes without hardware")
}

private func runActivityBluetoothTests() {
    let suite = "fix-mac-os.activity-bluetooth.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
    defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain) }
    defer { defaults.removePersistentDomain(forName: suite) }
    let journal = ActivityJournal()
    let runner = FakeRunner()
    runner.current = [BluetoothDevice(address: "PRIVATE_ADDRESS_A", name: "PRIVATE_NAME_A", connected: false),
                      BluetoothDevice(address: "PRIVATE_ADDRESS_B", name: "PRIVATE_NAME_B", connected: false)]
    runner.failedAddresses = ["PRIVATE_ADDRESS_A"]
    defaults.set(true, forKey: "bluetooth.autoEnabled")
    defaults.set(["PRIVATE_ADDRESS_A", "PRIVATE_ADDRESS_B"], forKey: "bluetooth.autoAddresses")
    defaults.set(false, forKey: "bluetooth.protectAudio")
    defaults.set(false, forKey: "bluetooth.switchAudio")
    let owner = BluetoothModule(defaults: defaults, backend: backend(runner, audioTool: nil), importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    owner.activityJournal = journal
    owner.poll(); activityWait { !owner.isBusy }
    expect(journal.entries.count == 2 && journal.entries.contains(where: { $0.result == .retryScheduled }) && journal.entries.contains(where: { $0.result == .completed }), "Bluetooth mixed-target cycle records failure and verified success separately")
    let count = journal.entries.count
    for _ in 0..<4 { owner.poll(); activityWait { !owner.isBusy } }
    expect(journal.entries.count == count, "Bluetooth discovery and pending retry observations do not spam activity")
    let attempts = runner.connections.count
    owner.setAutoReconnect(true, for: "PRIVATE_ADDRESS_A")
    owner.poll(); activityWait { !owner.isBusy }
    expect(runner.connections.count > attempts && journal.entries.count == count, "Bluetooth repeated real connection failure is grouped within the retry episode")
    runner.failedAddresses.removeAll()
    owner.setAutoReconnect(true, for: "PRIVATE_ADDRESS_A")
    owner.poll(); activityWait { !owner.isBusy }
    expect(journal.entries.count == count + 1 && journal.entries.first?.result == .completed && journal.entries.first?.trigger == .automatic, "Bluetooth automatic retry recovery records verified success without rewriting its failure")
    runner.failedAddresses = ["PRIVATE_ADDRESS_A"]
    owner.requestConnection(true, address: "PRIVATE_ADDRESS_A"); activityWait { !owner.isBusy }
    expect(journal.entries.first?.trigger == .user && journal.entries.first?.result == .failed, "Bluetooth manual failure is not confused with automatic policy")
    runner.failedAddresses.removeAll()
    owner.requestConnection(true, address: "PRIVATE_ADDRESS_A"); activityWait { !owner.isBusy }
    expect(journal.entries.first?.result == .completed, "Bluetooth manual success follows backend connection readback")
    expect(!journal.entries.map { "\($0.event.title) \($0.details)" }.joined().contains("PRIVATE"), "Bluetooth activity excludes addresses, names and raw errors")
    owner.stop()

    let delayed = DelayedBluetoothRunner()
    let queued = BluetoothModule(defaults: defaults, backend: BluetoothBackend(runner: delayed, blueutil: "fixture", audioTool: nil, waitForConnection: {}), importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    queued.activityJournal = journal
    queued.poll()
    expect(delayed.entered.wait(timeout: .now() + 1) == .success, "Bluetooth activity queued fixture is gated")
    queued.requestConnection(true, address: "PRIVATE_ADDRESS_A")
    expect(journal.entries.first?.queued == true && journal.entries.first?.result == nil, "Bluetooth queued request is not presented as a completed device effect")
    queued.stop()
    expect(journal.entries.first?.result == .canceled, "Bluetooth stop finalizes queued manual activity without dispatch")
    delayed.resume.signal(); activityWait { !queued.isBusy }
}

private final class ActivityDisplayRunner: CommandRunning {
    var fail = false
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        if fail { throw ToggleError(message: "PRIVATE_BACKEND_ERROR") }
        return "PRIVATE_HELPER_OUTPUT"
    }
}

private func runActivityDisplayTests() {
    for failing in [false, true] {
        let suite = "fix-mac-os.activity-displays.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: module == .monitors) }
        defaults.set(true, forKey: "monitors.confirmDisable")
        let journal = ActivityJournal()
        let model = DashboardModel(); model.confirmMonitorDisable = true
        let runner = ActivityDisplayRunner(); runner.fail = failing
        let host = AppDelegate(commandRunner: runner, model: model, preferences: defaults,
            controlStateSnapshot: { SystemControlLifecycle.State(watchdogReady: true, displaySettling: false) },
            displayRecoveryPending: { false }, displaySnapshotRefresh: {}, activity: journal)
        model.onMonitorChanged("PRIVATE_DISPLAY", false)
        expect(journal.entries.first?.result == nil, "display activity remains Started before helper outcome")
        activityWait { !model.monitorBusy }
        expect(journal.entries.first?.result == (failing ? .uncertainDisplay : .awaitingConfirmation), "display helper outcome distinguishes unconfirmed failure from pending user confirmation")
        if !failing {
            model.onKeepDisabled("PRIVATE_DISPLAY")
            expect(journal.entries.first?.event == .displayKept && journal.entries.first?.result == .completed, "keeping display change records explicit user confirmation separately")
        } else {
            activityWait { journal.entries.contains(where: { $0.event == .displayRecovery(.failedChange) && $0.result == .failed }) }
            let failures = journal.entries.count
            RunLoop.main.run(until: Date().addingTimeInterval(2.1))
            expect(journal.entries.count == failures, "repeated failed automatic display recovery does not spam activity")
            runner.fail = false
            activityWait { journal.entries.contains(where: { $0.event == .displayRecovery(.failedChange) && $0.result == .completed }) }
        }
        runner.fail = false
        model.onRestoreAll(); activityWait { !model.monitorBusy }
        expect(journal.entries.first?.event == .displayRecovery(.user) && journal.entries.first?.result == .completed, "display restore records actual host recovery callback")
        expect(!journal.entries.map { "\($0.event.title) \($0.details)" }.joined().contains("PRIVATE"), "display activity excludes display identifiers and helper output/errors")
        withExtendedLifetime(host) {}
    }
}
