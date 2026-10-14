import Foundation

private final class FakeMouseBackend: MouseSettingsBackend {
    let identifier = "test-mouse-only"
    var available = true
    var value = MouseOriginalSettings(acceleration: .absent, speed: .number(1.25))
    var writes = 0
    var failApply = false
    var failRestore = false
    var beforeWrite: () -> Void = {}
    func read() throws -> MouseOriginalSettings { value }
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
    let module = MouseModule(backend: backend, recovery: recovery)
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
    backend.failApply = false
    try module.apply(acceleration: true, speed: 2)
    recovery.failClear = true
    do { try module.stop(); expect(false, "Journal deletion failure must throw") } catch {}
    expect(recovery.pending != nil && backend.value == original, "Failed journal deletion remains retryable after successful restoration")
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
    try reopened.clear()
    expect(!FileManager.default.fileExists(atPath: url.path), "Successful recovery removes the disk journal")
}
