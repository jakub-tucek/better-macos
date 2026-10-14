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

private final class FakeMouseHIDAccess: MouseHIDAccess {
    var linear = 0.0
    var tracking = 0.6875
    var writes: [String] = []
    var ignoreTracking = false
    var failRead = false
    var failLinearWrite = false
    var failTrackingWrite = false
    func readLinear() throws -> Double { if failRead { throw MouseModule.unavailable }; return linear }
    func readTracking() throws -> Double { tracking }
    func setLinear(_ value: Double) throws {
        if failLinearWrite { throw MouseModule.unavailable }
        writes.append("mouse-linear"); linear = value
    }
    func setTracking(_ value: Double) throws {
        writes.append("mouse-tracking")
        if failTrackingWrite { throw MouseModule.unavailable }
        if !ignoreTracking { tracking = floor(value * 65536) / 65536 }
    }
}

func testMouseControls() throws {
    let hid = FakeMouseHIDAccess()
    let system = SystemMouseBackend(access: hid)
    let systemOriginal = try system.read()
    expect(system.available && hid.writes.isEmpty, "Real backend capability boundary only reads parameters")
    try system.apply(acceleration: false, speed: 1.2)
    expect(hid.linear == 1 && abs(hid.tracking - 1.2) < 1.0 / 65536 && hid.writes == ["mouse-linear", "mouse-tracking"],
           "Backend disables acceleration through mouse linear mode and applies fixed-point tracking")
    try system.restore(systemOriginal)
    expect(hid.linear == 0 && hid.tracking == 0.6875, "Runtime backend restores captured linear mode and tracking")
    let beforeInvalid = hid.writes.count
    do { try system.restore(MouseOriginalSettings(acceleration: .absent, speed: .number(1))); expect(false, "Absent runtime restoration must fail") } catch {}
    do { try system.apply(acceleration: true, speed: .nan); expect(false, "Invalid runtime write must fail") } catch {}
    expect(hid.writes.count == beforeInvalid, "Absent runtime originals and invalid speed are rejected before any HID write")
    hid.ignoreTracking = true
    do { try system.apply(acceleration: true, speed: 2); expect(false, "Ignored runtime write must fail readback") } catch {}
    expect(hid.tracking == 0.6875, "Runtime write readback detects an ignored setting")
    hid.ignoreTracking = false
    hid.linear = 2
    expect(!system.available, "Malformed linear runtime values fail capability validation")
    hid.linear = 0
    hid.failLinearWrite = true
    do { try system.apply(acceleration: false, speed: 1); expect(false, "Throwing linear setter must fail") } catch {}
    expect(hid.linear == 0, "Throwing linear setter does not claim a successful override")
    hid.failLinearWrite = false
    hid.failTrackingWrite = true
    do { try system.restore(systemOriginal); expect(false, "Throwing restore setter must fail") } catch {}
    expect(hid.tracking == 0.6875, "Runtime restore surfaces setter failures")
    hid.failTrackingWrite = false
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let shim = try String(contentsOf: sourceRoot.appendingPathComponent("MouseHID/MouseHID.c"), encoding: .utf8)
    expect(shim.components(separatedBy: "CFSTR(kIOHIDMouseAccelerationTypeKey)").count == 3 &&
           !shim.contains("CFSTR(kIOHIDPointerAccelerationKey)"),
           "C compatibility shim uses the SDK mouse-specific key for both getter and setter")
    hid.failRead = true
    expect(!system.available, "Runtime read failure reports unsupported capability without writes")
    hid.failRead = false
    let runtimeRecovery = FakeMouseRecovery()
    let runtimeModule = MouseModule(backend: system, recovery: runtimeRecovery)
    hid.ignoreTracking = true
    do { try runtimeModule.apply(acceleration: false, speed: 2); expect(false, "Readback mismatch must rollback") } catch {}
    expect(hid.linear == 0 && runtimeRecovery.pending == nil, "Transaction rolls back partial real-backend boundary failure")
    hid.ignoreTracking = false
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
    try module.stop()
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
    for invalid in [Double.nan, .infinity, -1, 3.1] {
        do { try module.apply(acceleration: false, speed: invalid); expect(false, "Invalid speed must throw") } catch {}
    }
    expect(backend.writes == beforeUnavailable, "Invalid tracking speeds cannot reach the backend")
    recovery.pending = MouseRecovery(backend: "different-device-backend", original: original)
    do { try module.stop(); expect(false, "Mismatched backend must throw") } catch {}
    expect(backend.writes == beforeUnavailable && recovery.pending != nil, "Recovery refuses a different backend and retains its journal")
    do {
        let real = try SystemMouseBackend().read()
        print("READ-ONLY mouse runtime capability: \(real)")
    } catch { print("READ-ONLY mouse runtime capability unavailable: \(error.localizedDescription)") }

    recovery.pending = nil
    try module.stop()
    backend.failRead = true
    do { try module.apply(acceleration: false, speed: 2); expect(false, "Snapshot failure must throw") } catch {}
    expect(backend.writes == beforeUnavailable && recovery.pending == nil, "Snapshot failure prevents journaling and mutation")
    backend.failRead = false
    try module.stop()
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
    hostBackend.value.acceleration = .number(0)
    let hostRecovery = FakeMouseRecovery()
    let hostOriginal = hostBackend.value
    hostRecovery.pending = MouseRecovery(backend: hostBackend.identifier, original: hostOriginal)
    hostBackend.value.speed = .number(3)
    let lifecycle = MouseLifecycle(settings: settings, makeModule: {
        MouseModule(backend: hostBackend, recovery: hostRecovery)
    })
    let model = DashboardModel()
    lifecycle.onChange = { model.updateMouseRecovery(required: lifecycle.recoveryRequired, message: lifecycle.errorMessage) }
    lifecycle.start()
    let hostSnapshot = try lifecycle.snapshot()
    expect(hostSnapshot == hostOriginal, "Lifecycle capability reads use the injected owner's backend")
    model.initializeMouseDraft(hostSnapshot)
    expect(model.mouseTracking == 1.25 && model.mouseAcceleration, "Untouched draft initializes from actual current runtime settings")
    model.mouseTracking = 2.5
    model.initializeMouseDraft(hostSnapshot)
    expect(model.mouseTracking == 2.5, "Routine capability notifications preserve unsaved proposed tracking")
    model.initializeMouseDraft(hostSnapshot, force: true)
    expect(model.mouseTracking == 1.25, "Explicit read or successful Restore refreshes the proposed controls")
    expect(hostBackend.value == hostOriginal && lifecycle.module == nil && !model.mouseRecoveryRequired,
           "Host startup restores a journal while Mouse is disabled and leaves the owner unloaded")
    expect(lifecycle.setEnabled(true) && settings.enabled.contains(.mouse), "Host enable persists the module choice")
    hostBackend.failApply = true
    hostBackend.failRestore = true
    lifecycle.apply(acceleration: false, speed: 2)
    expect(lifecycle.recoveryRequired && model.mouseRecoveryRequired && lifecycle.module?.hasSessionChanges == true && hostRecovery.pending != nil,
           "UI-facing failed Apply rollback publishes recovery and exposes global Restore while retaining ownership")
    hostBackend.failRestore = false
    hostBackend.failApply = false
    lifecycle.restore()
    hostBackend.failApply = true
    lifecycle.apply(acceleration: false, speed: 2)
    expect(!lifecycle.recoveryRequired && lifecycle.module?.hasSessionChanges == false && hostRecovery.pending == nil,
           "UI-facing Apply with successful rollback remains idle without false recovery")
    hostBackend.failApply = false
    try lifecycle.module!.apply(acceleration: false, speed: 2)
    hostBackend.failRestore = true
    expect(!lifecycle.setEnabled(false) && settings.enabled.contains(.mouse) && lifecycle.module != nil && model.mouseRecoveryRequired,
           "Failed host disable retains the live owner and enabled choice and publishes retry state")
    expect(!lifecycle.prepareToQuit(), "Host defers quit while its own changes cannot be restored")
    expect(model.errorMessage != nil, "Failed host cleanup publishes its error banner")
    hostBackend.failRestore = false
    lifecycle.restore()
    expect(!model.mouseRecoveryRequired && lifecycle.errorMessage == nil && model.errorMessage == nil && hostBackend.value == hostOriginal,
           "Successful host retry restores originals and clears published recovery state")
    expect(lifecycle.prepareToQuit(), "Host permits quit after restoration succeeds")
    model.updateMouseRecovery(required: true, message: "mouse failure")
    model.errorMessage = "unrelated display failure"
    model.updateMouseRecovery(required: false, message: nil)
    expect(model.errorMessage == "unrelated display failure", "Successful mouse recovery preserves unrelated error banners")
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
