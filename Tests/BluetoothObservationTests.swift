import Foundation
import CoreBluetooth

private final class ObservationSink: DiagnosticSink {
    private let lock = NSLock()
    private var bytes = Data()
    func write(_ line: Data) throws { lock.lock(); bytes.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

private final class ObservationRunner: CommandRunning {
    private let lock = NSLock()
    private var recorded = [[String]]()
    var power = "0"
    var paired = "[]"
    var fail = false
    var allowFixturePowerOn = false
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
        if fail { throw ToggleError(message: "fixture read failed") }
        switch arguments {
        case ["--power"]: return power
        case ["--power", "1"] where allowFixturePowerOn: power = "1"; return ""
        case ["--paired", "--format", "json"]: return paired
        default: throw ToggleError(message: "Mutation forbidden in observation fixture")
        }
    }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class ObservationProcessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, Error>?
    func finish(_ result: Result<Data, Error>) { lock.lock(); stored = result; lock.unlock() }
    var result: Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func profilerFixture(power: Any = "attrib_on", connected: [[String: Any]] = [], disconnected: [[String: Any]] = []) -> [String: Any] {
    ["SPBluetoothDataType": [["controller_properties": ["controller_state": power],
                               "device_connected": connected, "device_not_connected": disconnected]]]
}

private func fixtureDevice(_ index: Int) -> [String: Any] {
    ["SENSITIVE-NAME-\(index)": ["device_address": String(format: "AA:BB:CC:DD:EE:%02X", index), "private_metadata": "SENSITIVE-EXTRA"]]
}

func runBluetoothObservationTests() throws {
    func data(_ root: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: root) }
    func parse(_ root: [String: Any]) throws -> BluetoothNativeSnapshot { try BluetoothProfilerParser.parse(data(root), at: 10) }
    func issue(_ root: [String: Any], _ expected: BluetoothReadIssue) {
        do { _ = try parse(root); expect(false, "parser rejects \(expected)") }
        catch { expect(error as? BluetoothReadIssue == expected, "parser rejects \(expected)") }
    }
    let nativeData = try data(profilerFixture(connected: [fixtureDevice(1)], disconnected: (2...6).map(fixtureDevice)))
    let native = try BluetoothProfilerParser.parse(nativeData, at: 10)
    expect(native.controller == .on && native.complete && (try? native.inventory.get().count) == 6, "native fixture has one on controller and six devices")
    let empty = try parse(profilerFixture(power: "attrib_off"))
    expect(empty.controller == .off && (try? empty.inventory.get().isEmpty) == true, "explicit empty groups are valid, distinct from missing groups")
    for value: Any in [true, 1, "on", NSNull()] {
        let snapshot = try parse(profilerFixture(power: value))
        expect(snapshot.controller == .unknown(.unknownPower), "unknown power value never becomes off")
    }
    issue([:], .malformed)
    issue(["SPBluetoothDataType": []], .missingController)
    issue(["SPBluetoothDataType": [["_error": "SENSITIVE-ERROR"]]], .unavailable)
    issue(["SPBluetoothDataType": [["controller_properties": [:]]]], .missingController)
    issue(["SPBluetoothDataType": [[:], [:]]], .ambiguousController)
    let missing = try parse(["SPBluetoothDataType": [["controller_properties": ["controller_state": "attrib_on"]]]])
    expect(missing.controller == .on && !missing.complete, "partial successful report retains power but does not invent empty inventory")
    let mini = try parse(profilerFixture(connected: [["Name": ["device_minorType": "mouse"]]]))
    expect(!mini.complete, "mini report without addresses cannot match saved targets")
    issue(["SPBluetoothDataType": [["controller_properties": ["controller_state": "attrib_on", "controller_error": "SENSITIVE-ERROR"],
                                   "device_connected": [], "device_not_connected": []]]], .unavailable)
    let duplicate = try parse(profilerFixture(connected: [fixtureDevice(1)], disconnected: [fixtureDevice(1)]))
    if case .failure(.duplicateIdentity) = duplicate.inventory { expect(true, "duplicate conflicting identities rejected") }
    else { expect(false, "duplicate conflicting identities rejected") }
    for address in ["", "AA:BB:CC:DD:EE:GG", "AABBCCDDEEF", "AABBCCDDEEFF00", "AA::BB:CC:DD:EE:FF", "AA:BB-CC:DD:EE:FF"] {
        expect(BluetoothIdentity.canonical(address) == nil, "invalid identity rejected")
    }
    expect(BluetoothIdentity.matches("aa-bb-cc-dd-ee-01", "AA:BB:CC:DD:EE:01"), "canonical comparison accepts separator and case changes")
    let sink = ObservationSink(), logger = Diagnostics(sink: sink)
    var now: TimeInterval = 10, fetches = 0, failure: BluetoothReadIssue?
    let service = BluetoothObservationService(clock: { now }, diagnostics: logger) { _ in
        fetches += 1
        if let failure { throw failure }
        return nativeData
    }
    let first = service.observe(power: false, devices: [], shouldContinue: { true })
    expect(first.conflicting && first.controlsBlocked && first.displayedPower == true && first.displayedDevices?.count == 6,
           "off/empty versus native on/six displays native evidence and blocks controls")
    expect(first.summary == "macOS reports Bluetooth on; helper reports off. Device controls unavailable.", "conflict copy distinguishes both sources")
    _ = service.observe(power: false, devices: [], shouldContinue: { true })
    expect(fetches == 1, "cache reuses one snapshot within TTL")
    now = 41; failure = .timeout
    let stale = service.observe(power: false, devices: [], shouldContinue: { true })
    expect(stale.native?.observedAt == 10 && stale.nativeStale && stale.controlsBlocked && stale.displayedDevices?.count == 6,
           "timeout preserves cached devices and original timestamp without authorizing controls")
    _ = service.observe(power: false, devices: [], shouldContinue: { true })
    expect(fetches == 2, "failure backoff prevents poll hot-loop")
    now = 72; failure = nil
    let recovered = service.observe(power: false, devices: [], shouldContinue: { true })
    expect(recovered.native?.observedAt == 72 && !recovered.nativeStale, "cache expiry permits fresh successful snapshot")
    let coherent = service.observe(power: true, devices: [BluetoothDevice(address: "fixture", name: "Fixture", connected: true)], shouldContinue: { true })
    expect(!coherent.controlsBlocked && coherent.native == nil && fetches == 3, "normal nonempty helper observation does not invoke profiler")
    let emptyService = BluetoothObservationService(diagnostics: logger) { _ in try data(profilerFixture(power: "attrib_off")) }
    expect(!emptyService.observe(power: false, devices: [], shouldContinue: { true }).controlsBlocked, "coherent off/empty keeps existing power-on control")
    let failService = BluetoothObservationService(diagnostics: logger) { _ in throw BluetoothReadIssue.exitFailure }
    let unavailable = failService.observe(power: nil, devices: nil, shouldContinue: { true })
    expect(unavailable.controlsBlocked && unavailable.displayedPower == nil && unavailable.displayedDevices == nil, "failed sources remain unknown, not off/empty")
    var partialTime: TimeInterval = 10, returnPartial = false
    let partialService = BluetoothObservationService(clock: { partialTime }, diagnostics: logger) { _ in
        returnPartial ? try data(["SPBluetoothDataType": [["controller_properties": ["controller_state": "attrib_off"]]]]) : nativeData
    }
    _ = partialService.observe(power: false, devices: [], shouldContinue: { true })
    returnPartial = true; partialTime = 41
    let partial = partialService.observe(power: false, devices: [], shouldContinue: { true })
    expect(partial.native?.observedAt == 10 && partial.displayedDevices?.count == 6 && partial.nativeStale && partial.controlsBlocked,
           "partial report cannot erase cached inventory or advance good timestamp")
    let unknownService = BluetoothObservationService(diagnostics: logger) { _ in try data(profilerFixture(power: 1)) }
    let unknown = unknownService.observe(power: false, devices: [], shouldContinue: { true })
    expect(unknown.displayedPower == nil && unknown.controlsBlocked, "unknown native power does not collapse to helper off")
    service.invalidate()
    _ = service.observe(power: false, devices: [], shouldContinue: { true })
    expect(fetches == 4, "admitted explicit control invalidates earlier native evidence")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var coalescedFetches = 0
    let coalesced = BluetoothObservationService(diagnostics: logger) { _ in
        coalescedFetches += 1; entered.signal(); _ = release.wait(timeout: .now() + 2); return nativeData
    }
    DispatchQueue.global().async { _ = coalesced.observe(power: false, devices: [], shouldContinue: { true }); done.signal() }
    expect(entered.wait(timeout: .now() + 1) == .success, "first read reaches injected gate")
    let before = ProcessInfo.processInfo.systemUptime
    let waiting = coalesced.observe(power: false, devices: [], shouldContinue: { true })
    expect(waiting.controlsBlocked && ProcessInfo.processInfo.systemUptime - before < 0.1, "overlapping reads coalesce without blocking caller")
    release.signal(); expect(done.wait(timeout: .now() + 2) == .success && coalescedFetches == 1, "coalesced request launches once")
    try runBluetoothObservationModuleFixture(nativeData, logger: logger)
    try runBluetoothProfilerProcessFixtures()
    expect(logger.flushForTesting(timeout: 2), "observation diagnostics flush only in tests")
    expect(!sink.text.contains("SENSITIVE") && !sink.text.contains("AA:BB") && !sink.text.contains("aa-bb"), "structured observation logs omit names, IDs, raw reports and errors")
}

private func runBluetoothObservationModuleFixture(_ nativeData: Data, logger: Diagnostics) throws {
    let suite = "fix-mac-os.observation.\(UUID().uuidString)", runner = ObservationRunner()
    let defaults = UserDefaults(suiteName: suite)!
    let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
    defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain); defaults.removePersistentDomain(forName: suite) }
    let saved: Set<String> = ["aa-bb-cc-dd-ee-01", "aabbccddee02"]
    defaults.set(saved.sorted(), forKey: "bluetooth.autoAddresses")
    defaults.set(true, forKey: "bluetooth.autoEnabled")
    defaults.set(true, forKey: "bluetooth.legacyTakenOver")
    let service = BluetoothObservationService(diagnostics: logger) { _ in nativeData }
    let backend = BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, observationService: service)
    let module = BluetoothModule(defaults: defaults, backend: backend, importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    defer { module.stop() }
    func wait() {
        let deadline = Date().addingTimeInterval(2)
        while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(!module.isBusy, "injected observation completes")
    }
    module.requestConnection(true, address: saved.first!); module.turnBluetoothOn()
    expect(runner.calls.isEmpty && !module.controlsAvailable, "non-UI controls cannot bypass the initial production comparison")
    module.poll(); wait()
    expect(module.radioPoweredOn == false && module.displayedRadioPoweredOn == true && !module.controlsAvailable,
           "module separates original control evidence from native presentation")
    expect(module.devices.isEmpty && module.displayedDevices.count == 6, "native inventory never enters control or audio policy inventory")
    expect(saved.isSubset(of: Set(module.displayedDevices.map(\.address))) && module.autoAddresses == saved,
           "six native devices resolve both saved targets without rewriting persisted IDs")
    let count = runner.calls.count
    module.requestConnection(true, address: saved.first!); module.turnBluetoothOn(); wait()
    expect(runner.calls.count == count && runner.calls.allSatisfy { $0 == ["--power"] || $0 == ["--paired", "--format", "json"] },
           "manual and automatic conflict paths execute zero mutation commands")
    expect(!module.audioProtection.ready, "fallback never grants audio policy readiness")
    module.stop()
    let normalRunner = ObservationRunner(); normalRunner.allowFixturePowerOn = true
    let offReport = try JSONSerialization.data(withJSONObject: profilerFixture(power: "attrib_off"))
    let normal = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: normalRunner, blueutil: "/fixture/blueutil", audioTool: nil,
                                  observationService: BluetoothObservationService(diagnostics: logger) { _ in offReport }),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    normal.poll()
    let normalDeadline = Date().addingTimeInterval(2)
    while normal.isBusy && Date() < normalDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    expect(normal.controlsAvailable && normal.displayedRadioPoweredOn == false, "coherent off observation retains explicit power-on admission")
    normal.turnBluetoothOn()
    while normal.isBusy && Date() < normalDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    expect(!normal.isBusy && normal.controlsAvailable && normal.displayedRadioPoweredOn == true && normalRunner.calls.contains(["--power", "1"]),
           "original fake helper verification, not old native cache, completes an admitted manual operation")
    normal.stop()
    let entered = DispatchSemaphore(value: 0)
    let cancelService = BluetoothObservationService(diagnostics: logger) { shouldContinue in
        entered.signal()
        let deadline = Date().addingTimeInterval(2)
        while shouldContinue() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        return nativeData
    }
    let cancelModule = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, observationService: cancelService),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    cancelModule.poll()
    expect(entered.wait(timeout: .now() + 1) == .success, "cancel fixture reaches native read")
    var stopped = 0, heartbeat = false
    cancelModule.stop { stopped += 1 }
    DispatchQueue.main.async { heartbeat = true }
    let deadline = Date().addingTimeInterval(2)
    while stopped == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    expect(stopped == 1 && heartbeat && cancelModule.readback == nil, "stop cancels native work, drains once and rejects late presentation while main stays responsive")
}

private func runBluetoothProfilerProcessFixtures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiler-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("profiler")
    func run(_ body: String, timeout: TimeInterval = 2, limit: Int = 4096, continuing: @escaping () -> Bool = { true }) -> Result<Data, Error> {
        do {
            try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let box = ObservationProcessResult()
            let process = BluetoothProfilerProcess(executable: script.path, arguments: [], timeout: timeout, outputLimit: limit)
            DispatchQueue.global().async { box.finish(Result { try process.read(shouldContinue: continuing) }) }
            var heartbeat = false
            DispatchQueue.main.async { heartbeat = true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            let deadline = Date().addingTimeInterval(4)
            while box.result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(heartbeat && box.result != nil, "bounded process runs off main and completes once while main queue advances")
            return box.result ?? .failure(BluetoothReadIssue.timeout)
        } catch { return .failure(error) }
    }
    func failure(_ result: Result<Data, Error>, _ issue: BluetoothReadIssue) {
        if case .failure(let error) = result { expect(error as? BluetoothReadIssue == issue, "bounded process reports \(issue)") }
        else { expect(false, "bounded process reports \(issue)") }
    }
    let finite = run("printf '{}' ")
    expect((try? finite.get()) == Data("{}".utf8), "bounded subprocess captures finite fixture output")
    failure(run("echo SENSITIVE-ERROR >&2; exit 75"), .exitFailure)
    failure(run("while :; do echo SENSITIVE-OUTPUT; done", limit: 128), .outputLimit)
    let start = ProcessInfo.processInfo.systemUptime
    failure(run("trap '' TERM; while :; do /bin/sleep 0.01; done", timeout: 0.2), .timeout)
    expect(ProcessInfo.processInfo.systemUptime - start < 1.5, "TERM-resistant child is killed within bounded deadline")
    let pipeStart = ProcessInfo.processInfo.systemUptime
    failure(run("/bin/sleep 1 &\nprintf '{}'\nexit 0", timeout: 0.2), .timeout)
    expect(ProcessInfo.processInfo.systemUptime - pipeStart < 0.8, "descendant-held pipe cannot block read completion")
    var checks = 0
    failure(run("while :; do /bin/sleep 0.01; done", continuing: { checks += 1; return checks < 5 }), .canceled)
    do { _ = try BluetoothProfilerParser.parse(Data("broken".utf8), at: 0); expect(false, "malformed JSON rejected") }
    catch { expect(true, "malformed JSON rejected") }
}
