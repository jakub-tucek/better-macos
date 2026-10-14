import Foundation

private final class FakeMouseBackend: MouseSettingsBackend {
    let identifier = "test-mouse-only"
    var available = true
    var value = MouseOriginalSettings(acceleration: .absent, speed: .number(1.25))
    var writes = 0
    var failApply = false
    var failRead = false
    var failRestore = false
    var beforeWrite: () -> Void = {}
    func read() throws -> MouseOriginalSettings {
        if failRead { throw MouseModule.unavailable }
        return value
    }
    func apply(acceleration: Bool, speed: Double) throws {
        beforeWrite()
        writes += 1
        value.acceleration = .boolean(acceleration)
        if failApply { throw MouseModule.unavailable }
        value.speed = .number(speed)
    }
    func restore(_ original: MouseOriginalSettings) throws {
        writes += 1
        if failRestore { throw MouseModule.unavailable }
        value = original
    }
}

private final class FakeMouseRecovery: MouseRecoveryStore {
    var pending: MouseRecovery?
    var failSave = false
    var failClear = false
    func load() throws -> MouseRecovery? { pending }
    func save(_ recovery: MouseRecovery) throws {
        if failSave { throw MouseModule.unavailable }
        pending = recovery
    }
    func clear() throws {
        if failClear { throw MouseModule.unavailable }
        pending = nil
    }
}

func testMouseControls() throws {
    let backend = FakeMouseBackend()
    let recovery = FakeMouseRecovery()
    var module = MouseModule(backend: backend, recovery: recovery)
    let original = backend.value
    backend.beforeWrite = { expect(recovery.pending?.original == original, "Mouse original is journaled before any mutation") }
    try module.apply(acceleration: false, speed: 2)
    try module.apply(acceleration: true, speed: 3)
    expect(module.active && recovery.pending?.original == original, "Repeated mouse changes preserve the first baseline")
    try module.stop()
    expect(backend.value == original && recovery.pending == nil && !module.active, "Disable restores absent acceleration key and original tracking speed")
    let writes = backend.writes
    try module.stop()
    expect(backend.writes == writes, "Repeated mouse cleanup is a no-op")

    recovery.failSave = true
    do { try module.apply(acceleration: false, speed: 2); expect(false, "Journal failure must throw") } catch {}
    expect(backend.writes == writes, "Journal failure prevents pointer mutation")
    recovery.failSave = false
    backend.failApply = true
    do { try module.apply(acceleration: false, speed: 2); expect(false, "Partial apply must throw") } catch {}
    expect(backend.value == original && recovery.pending == nil, "Partial mouse change rolls back automatically")
    backend.failRestore = true
    do { try module.apply(acceleration: false, speed: 2); expect(false, "Rollback failure must throw") } catch {}
    expect(recovery.pending?.original == original, "Failed rollback retains original settings for retry")
    let relaunched = MouseModule(backend: backend, recovery: recovery)
    let failedWrites = backend.writes
    do { try relaunched.apply(acceleration: true, speed: 1); expect(false, "Recovery must precede new changes") } catch {}
    expect(backend.writes == failedWrites, "Relaunch cannot overwrite a pending recovery baseline")
    backend.failRestore = false
    try relaunched.stop()
    expect(backend.value == original && recovery.pending == nil, "Relaunch recovers original absent-key state")
    module = relaunched
    backend.failApply = false
    try module.apply(acceleration: true, speed: 2)
    recovery.failClear = true
    do { try module.stop(); expect(false, "Journal deletion failure must throw") } catch {}
    expect(recovery.pending != nil && backend.value == original, "Failed journal deletion remains retryable after successful restoration")
    let beforeRetry = backend.writes
    do { try module.apply(acceleration: false, speed: 1); expect(false, "Failed cleanup must block changes") } catch {}
    expect(backend.writes == beforeRetry && !module.active, "Same-instance journal cleanup failure enters recovery-only mode")
    recovery.failClear = false
    try module.stop()
    backend.available = false
    let beforeUnavailable = backend.writes
    do { try module.apply(acceleration: false, speed: 2); expect(false, "Unavailable backend must throw") } catch {}
    expect(backend.writes == beforeUnavailable && recovery.pending == nil, "Unqualified hardware cannot mutate or capture settings")
    backend.available = true
    for invalid in [Double.nan, .infinity, -1, 0, 3.1] {
        do { try module.apply(acceleration: false, speed: invalid); expect(false, "Invalid speed must throw") } catch {}
    }
    expect(backend.writes == beforeUnavailable, "Invalid tracking speeds cannot reach the backend")
    recovery.pending = MouseRecovery(backend: "different-device-backend", original: original)
    do { try module.stop(); expect(false, "Mismatched backend must throw") } catch {}
    expect(backend.writes == beforeUnavailable && recovery.pending != nil, "Recovery refuses a different backend and retains its journal")
    expect(!MouseModule().available, "Production mouse controls fail closed without hardware qualification")

    recovery.pending = nil
    try module.stop()
    backend.failRead = true
    do { try module.apply(acceleration: false, speed: 2); expect(false, "Snapshot failure must throw") } catch {}
    expect(backend.writes == beforeUnavailable && recovery.pending == nil, "Snapshot failure prevents journaling and mutation")
    backend.failRead = false
    backend.beforeWrite = {}
    for baseline in [MouseOriginalSettings(acceleration: .boolean(false), speed: .absent),
                     MouseOriginalSettings(acceleration: .absent, speed: .absent)] {
        backend.value = baseline
        try module.apply(acceleration: true, speed: 2)
        try module.stop()
        expect(backend.value == baseline, "Restoration preserves explicit false and absent tracking independently")
    }

    try module.apply(acceleration: true, speed: 2)
    backend.failApply = true
    backend.failRestore = true
    do { try module.apply(acceleration: false, speed: 3); expect(false, "Active update must fail") } catch {}
    let afterFailedUpdate = backend.writes
    do { try module.apply(acceleration: true, speed: 1); expect(false, "Failed active rollback must block changes") } catch {}
    expect(backend.writes == afterFailedUpdate && !module.active && module.hasSessionChanges,
           "Failed rollback of an active update blocks same-instance writes and retains ownership")
    backend.failApply = false
    backend.failRestore = false
    try module.stop()

    try module.apply(acceleration: true, speed: 2)
    let savedJournal = recovery.pending
    recovery.pending = nil
    let beforeMissing = backend.writes
    do { try module.apply(acceleration: false, speed: 1); expect(false, "Missing active baseline must throw") } catch {}
    expect(backend.writes == beforeMissing && recovery.pending == nil, "Missing active journal cannot recapture modified values as originals")
    recovery.pending = savedJournal
    try module.stop()

    let wheel = MouseScrollSample(vertical: 1.5, horizontal: 0)
    let reversed = MouseScrollPolicy.transform(wheel, source: .verifiedWheel, enabled: true, reverse: true, speed: 2)
    expect(reversed.vertical == -3, "Verified wheel policy supports fractional speed and reversed direction")
    for source in [MouseScrollSource.unknown, .trackpad] {
        expect(MouseScrollPolicy.transform(wheel, source: source, enabled: true, reverse: true, speed: 2) == wheel,
               "Unknown and trackpad sources pass through unmodified")
    }
    for protected in [MouseScrollSample(vertical: 3, horizontal: 0, momentum: true),
                      MouseScrollSample(vertical: 3, horizontal: 0, gesture: true),
                      MouseScrollSample(vertical: 3, horizontal: 0, modified: true),
                      MouseScrollSample(vertical: 3, horizontal: 2)] {
        expect(MouseScrollPolicy.transform(protected, source: .verifiedWheel, enabled: true, reverse: true, speed: 2) == protected,
               "Momentum, gesture, modified and horizontal scrolling pass through intact")
    }
    expect(MouseScrollPolicy.transform(wheel, source: .verifiedWheel, enabled: false, reverse: true, speed: 2) == wheel,
           "Disabled wheel policy leaves events untouched")
    expect(MouseScrollPolicy.transform(wheel, source: .verifiedWheel, enabled: true, reverse: false, speed: .nan) == wheel,
           "Invalid wheel speed passes through")
    let huge = MouseScrollSample(vertical: .greatestFiniteMagnitude, horizontal: 0)
    expect(MouseScrollPolicy.transform(huge, source: .verifiedWheel, enabled: true, reverse: false, speed: 3) == huge,
           "Wheel overflow passes through instead of emitting infinity")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouse-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("recovery.json")
    let disk = MouseFileRecoveryStore(url: url)
    try disk.save(MouseRecovery(backend: backend.identifier, original: original))
    let reopened = MouseFileRecoveryStore(url: url)
    let loaded = try reopened.load()
    expect(loaded?.original == original, "Disk journal round-trips absent keys and numeric values across instances")
    try Data("broken journal".utf8).write(to: url)
    do { _ = try reopened.load(); expect(false, "Corrupt journal must throw") } catch {}
    expect(FileManager.default.fileExists(atPath: url.path), "Corrupt recovery data is retained, never silently replaced")
    let corruptModule = MouseModule(backend: backend, recovery: reopened)
    let beforeCorrupt = backend.writes
    do { try corruptModule.apply(acceleration: false, speed: 2); expect(false, "Corrupt baseline must block apply") } catch {}
    expect(backend.writes == beforeCorrupt, "Corrupt recovery blocks new pointer mutations")
    try reopened.clear()
    expect(!FileManager.default.fileExists(atPath: url.path), "Successful recovery removes the disk journal")

    let domain = "mouse-lifecycle-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = ModuleSettings(defaults: defaults)
    settings.set(.mouse, enabled: false)
    let hostBackend = FakeMouseBackend()
    let hostRecovery = FakeMouseRecovery()
    let hostOriginal = hostBackend.value
    hostRecovery.pending = MouseRecovery(backend: hostBackend.identifier, original: hostOriginal)
    hostBackend.value.speed = .number(3)
    let lifecycle = MouseLifecycle(settings: settings, makeModule: {
        MouseModule(backend: hostBackend, recovery: hostRecovery)
    })
    let model = DashboardModel()
    lifecycle.onChange = { model.mouseRecoveryRequired = lifecycle.recoveryRequired }
    lifecycle.start()
    expect(hostBackend.value == hostOriginal && lifecycle.module == nil && !model.mouseRecoveryRequired,
           "Host startup restores a journal while Mouse is disabled and leaves the owner unloaded")
    expect(lifecycle.setEnabled(true) && settings.enabled.contains(.mouse), "Host enable persists the module choice")
    try lifecycle.module!.apply(acceleration: false, speed: 2)
    hostBackend.failRestore = true
    expect(!lifecycle.setEnabled(false) && settings.enabled.contains(.mouse) && lifecycle.module != nil && model.mouseRecoveryRequired,
           "Failed host disable retains the live owner and enabled choice and publishes retry state")
    expect(!lifecycle.prepareToQuit(), "Host defers quit while its own changes cannot be restored")
    hostBackend.failRestore = false
    lifecycle.restore()
    expect(!model.mouseRecoveryRequired && lifecycle.errorMessage == nil && hostBackend.value == hostOriginal,
           "Successful host retry restores originals and clears published recovery state")
    expect(lifecycle.prepareToQuit(), "Host permits quit after restoration succeeds")
    expect(lifecycle.setEnabled(false) && !settings.enabled.contains(.mouse) && lifecycle.module == nil,
           "Successful host disable persists Off and releases the owner")

    hostRecovery.pending = MouseRecovery(backend: "unsupported", original: hostOriginal)
    lifecycle.start()
    expect(model.mouseRecoveryRequired && lifecycle.module == nil, "Unsupported historical recovery is surfaced even while disabled")
    expect(lifecycle.prepareToQuit() && lifecycle.setEnabled(false) && hostRecovery.pending != nil,
           "Unsupported historical recovery preserves its journal without trapping quit or disable")
    try Data("broken journal".utf8).write(to: url)
    let corruptLifecycle = MouseLifecycle(settings: settings, makeModule: { MouseModule(backend: hostBackend, recovery: reopened) })
    corruptLifecycle.start()
    expect(corruptLifecycle.recoveryRequired && corruptLifecycle.prepareToQuit() && FileManager.default.fileExists(atPath: url.path),
           "Corrupt historical journal remains visible and retained while allowing normal host exit")
}
