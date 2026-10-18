import Foundation
import CoreBluetooth
import AppKit

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
    var powerGate: DispatchSemaphore?
    var powerEntered: DispatchSemaphore?
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
        if fail { throw ToggleError(message: "fixture read failed") }
        switch arguments {
        case ["--power"]:
            powerEntered?.signal()
            if let powerGate { _ = powerGate.wait(timeout: .now() + 2) }
            return power
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
    private var storedTrace: BluetoothProfilerTrace?
    func finish(_ result: Result<Data, Error>) { lock.lock(); stored = result; lock.unlock() }
    var result: Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
    func capture(_ trace: BluetoothProfilerTrace) { lock.lock(); storedTrace = trace; lock.unlock() }
    var trace: BluetoothProfilerTrace? { lock.lock(); defer { lock.unlock() }; return storedTrace }
}

private func profilerFixture(power: Any = "attrib_on", connected: [[String: Any]] = [], disconnected: [[String: Any]] = []) -> [String: Any] {
    ["SPBluetoothDataType": [["controller_properties": ["controller_state": power],
                               "device_connected": connected, "device_not_connected": disconnected]]]
}

private func fixtureDevice(_ index: Int) -> [String: Any] {
    ["SENSITIVE-NAME-\(index)": ["device_address": String(format: "AA:BB:CC:DD:EE:%02X", index), "private_metadata": "SENSITIVE-EXTRA"]]
}

func runBluetoothObservationTests() throws {
    try runBluetoothControlProbeTests()
    try runBluetoothReadOnlyLaunchTests()
    try runBluetoothMergedAdmissionTests()
    try runBluetoothMergedManualTests()
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
    let sink = ObservationSink(), logger = Diagnostics(sink: sink, minimumLevel: .trace)
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
    let coherent = service.observe(power: true, devices: [BluetoothDevice(address: "aa-bb-cc-dd-ee-01", name: "Fixture", connected: true)], shouldContinue: { true })
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
    try runBluetoothAutomaticPresentationTests()
    try runBluetoothIdentityTests()
    try runBluetoothProfilerProcessFixtures()
    expect(logger.flushForTesting(timeout: 2), "observation diagnostics flush only in tests")
    expect(!sink.text.contains("SENSITIVE") && !sink.text.contains("AA:BB") && !sink.text.contains("aa-bb"), "structured observation logs omit names, IDs, raw reports and errors")
    let records = sink.text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    expect(records.contains { $0["event"] as? String == "observation_cache" && $0["severity"] as? String == "trace" }, "all verbosity records cache/backoff trace context")
    let queued = records.first { $0["event"] as? String == "manual_queued" }
    let operation = queued?["operation"] as? String
    expect(operation != nil && records.contains { $0["event"] as? String == "cycle_finish" && $0["operation"] as? String == operation },
           "manual queue, cycle and verified completion share one private operation token")
    expect(records.contains { $0["event"] as? String == "manual_rejected" && ($0["fields"] as? [String: String])?["reason"] == "control_evidence_unavailable" },
           "non-UI admission rejection records only closed reason")
    expect(records.contains { $0["event"] as? String == "cycle_finish" && $0["outcome"] as? String == "canceled" }, "stopped cycle records cancellation without claiming verified success")
    expect(records.contains { $0["event"] as? String == "observation" && $0["severity"] as? String == "warning" &&
        ($0["fields"] as? [String: String])?["fetch_result"] == "timeout" }, "failed observation uses warning severity and current fetch result")
    expect(records.contains { $0["event"] as? String == "observation" && $0["outcome"] as? String == "canceled" &&
        ($0["fields"] as? [String: String])?["timed_out"] == "false" }, "canceled observation does not invent a current timeout")
}

private func runBluetoothControlProbeTests() throws {
    let sink = ObservationSink(), logger = Diagnostics(sink: sink, minimumLevel: .trace)
    var allowed = true, power: Bool? = true, now: TimeInterval = 0
    var controllerReads = 0, lookups = 0, paired = true, wrongIdentity = false
    let probe = BluetoothControlProbe(authorized: { allowed }, controllerOn: {
        controllerReads += 1; return power
    }, lookup: { identity in
        lookups += 1
        return .init(address: wrongIdentity ? "AA:BB:CC:DD:EE:FF" : identity, paired: paired, connected: false)
    }, clock: { now }, diagnostics: logger)
    let saved: Set<String> = ["aa-bb-cc-dd-ee-01", "AABBCCDDEE02"]
    let inventory = (1...6).map { BluetoothDevice(address: String(format: "AA:BB:CC:DD:EE:%02X", $0), name: "SENSITIVE-PROBE", connected: false) }
    let first = probe.inspect(saved: saved, protected: ["AABBCCDDEE03"], inventory: inventory, shouldContinue: { true })
    expect(first?["saved_paired_true_count"] == "2" && first?["protected_paired_true_count"] == "1" && lookups == 6,
           "direct lookup proves saved and protected pairing separately without enumerating pairedDevices")
    expect(first?["documented_controller_state"] == "on" && first?["control_capability"] == "unverified",
           "documented on and true pairing remain read-only evidence, not mutation qualification")
    expect(probe.inspect(saved: saved, protected: [], inventory: inventory, shouldContinue: { true }) == nil && lookups == 6,
           "probe repeats no faster than 30 seconds")
    now = 30; allowed = false
    let denied = probe.inspect(saved: saved, protected: [], inventory: inventory, shouldContinue: { true })
    expect(denied?["probe_stage"] == "parent_access_required" && controllerReads == 1 && lookups == 6,
           "denied parent causes no native getters or permission request")
    now = 60; allowed = true; power = nil
    expect(probe.inspect(saved: saved, protected: [], inventory: inventory, shouldContinue: { true })?["documented_controller_state"] == "unknown" && lookups == 6,
           "unknown documented controller cannot proceed to device lookup")
    now = 90; power = false
    expect(probe.inspect(saved: saved, protected: [], inventory: inventory, shouldContinue: { true })?["probe_stage"] == "controller_not_on" && lookups == 6,
           "off documented controller cannot imply a power-on request")
    now = 120; power = true
    expect(probe.inspect(saved: ["invalid"], protected: [], inventory: inventory, shouldContinue: { true })?["probe_stage"] == "invalid_saved_identity" && lookups == 6,
           "invalid saved identity fails before lookup")
    now = 150
    expect(probe.inspect(saved: ["AABBCCDDEE01", "aa:bb:cc:dd:ee:01"], protected: [], inventory: inventory, shouldContinue: { true })?["probe_stage"] == "invalid_saved_identity",
           "canonical saved collisions are not silently merged")
    now = 180
    expect(probe.inspect(saved: saved, protected: [], inventory: inventory + [inventory[0]], shouldContinue: { true })?["probe_stage"] == "invalid_inventory_identity",
           "duplicate native display identities cannot seed qualification reads")
    now = 210; wrongIdentity = true
    expect(probe.inspect(saved: saved, protected: [], inventory: inventory, shouldContinue: { true })?["matched_count"] == "0",
           "lookup object must match the requested canonical identity")
    now = 240; wrongIdentity = false; paired = false
    expect(probe.inspect(saved: saved, protected: [], inventory: nil, shouldContinue: { true })?["saved_paired_true_count"] == "0",
           "false contextual pairing getters never become positive pairing proof")
    now = 270
    let beforeCanceled = lookups
    expect(probe.inspect(saved: saved, protected: [], inventory: inventory, shouldContinue: { false }) == nil && lookups == beforeCanceled,
           "canceled cycle cannot begin qualification reads")

    let nativeData = try JSONSerialization.data(withJSONObject: profilerFixture(disconnected: (1...6).map(fixtureDevice)))
    let runner = ObservationRunner()
    let backend = BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil,
                                   observationService: BluetoothObservationService(diagnostics: logger) { _ in nativeData }, controlProbe: probe)
    var attempts = 0
    let config = BluetoothConfiguration(enabled: true, autoAddresses: saved, protectOtherAudio: true, switchAudioOutput: true,
                                        protectedAudioAddresses: ["AABBCCDDEE03"])
    do {
        _ = try backend.reconcile(config, progress: { if case .connecting = $0 { attempts += 1 } })
        expect(false, "contradictory production backend remains blocked")
    } catch {
        expect(attempts == 0 && runner.calls == [["--power"], ["--paired", "--format", "json"]],
               "production off-empty versus on-six with two saved targets reproduces zero reconnect attempts")
    }
    expect(lookups == beforeCanceled + 6, "blocked production reconciliation invokes injected app-context probe")
    expect(logger.flushForTesting(timeout: 2), "read-only probe fixture drains isolated diagnostics")
    expect(sink.text.contains("native_control_probe") && !sink.text.contains("SENSITIVE") && !sink.text.contains("AABB") && !sink.text.contains("aa-bb"),
           "native qualification diagnostics retain stages and counts, never names or addresses")
}

private final class ProbeLaunchDelegateFixture: NSObject, NSApplicationDelegate {}

private func runBluetoothReadOnlyLaunchTests() throws {
    let sink = ObservationSink(), logger = Diagnostics(sink: sink, minimumLevel: .info)
    var preferenceReads = [String](), controllerReads = 0, lookupIDs = [String]()
    let values: [String: Any] = ["bluetooth.autoAddresses": ["AA:BB:CC:DD:EE:01", "aa-bb-cc-dd-ee-02"],
                               "bluetooth.protectedAudioAddresses": ["AABBCCDDEE03"]]
    let run = BluetoothReadOnlyProbeRun(readValue: { key in preferenceReads.append(key); return values[key] }, makeProbe: {
        BluetoothControlProbe(authorized: { true }, controllerOn: { controllerReads += 1; return true }, lookup: { id in
            lookupIDs.append(id); return .init(address: id, paired: true, connected: false)
        }, diagnostics: logger)
    }, diagnostics: logger)
    var scheduled: (() -> Void)?, presentations = [String](), normalConstructions = 0
    let probe = BluetoothReadOnlyProbeDelegate(run: run, work: { scheduled = $0 }, present: { presentations.append($0) })
    let mode = ApplicationLaunchMode(arguments: ["fix-mac-os", "--bluetooth-readonly-probe", "--test-connect-in-gui", "--enable-login", "--watchdog"])
    let selected = mode.delegate(normal: { normalConstructions += 1; return ProbeLaunchDelegateFixture() }, probe: { probe })
    expect(mode == .bluetoothReadOnlyProbe && selected === probe && normalConstructions == 0,
           "typed read-only GUI route bypasses normal host construction even with mutating command flags")
    expect(Diagnostics.processRole(arguments: ["app", "--bluetooth-readonly-probe"]) == "gui" &&
           Diagnostics.processRole(arguments: ["app", "--watchdog"]) == "watchdog" &&
           Diagnostics.processRole(arguments: ["app", "--bluetooth-status"]) == "command_or_helper",
           "explicit probe startup retains GUI role without relabeling ordinary helper commands")
    let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
    probe.applicationDidFinishLaunching(notification)
    expect(preferenceReads.isEmpty && controllerReads == 0 && lookupIDs.isEmpty && scheduled != nil,
           "probe launch schedules getters off main before reading any preferences or native state")
    probe.applicationDidFinishLaunching(notification)
    scheduled?()
    let deadline = Date().addingTimeInterval(2)
    while probe.resultText == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    expect(preferenceReads == ["bluetooth.autoAddresses", "bluetooth.protectedAudioAddresses"],
           "probe reads exactly the two target preference keys and never writes preferences")
    expect(controllerReads == 1 && lookupIDs == ["aabbccddee01", "aabbccddee02", "aabbccddee03"],
           "probe-only GUI executes only documented controller and registered-target getters")
    expect(presentations.count == 2 && probe.resultText?.contains("saved_paired_true_count: 2") == true && probe.resultText?.contains("control_capability: unverified") == true,
           "visible probe completion persists with run token and public counts, without claiming qualification")
    expect(normalConstructions == 0,
           "probe lifecycle constructs zero normal modules, watchdog, login, input, audio or mutation capabilities")
    expect(probe.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
           "probe quit returns immediately without normal host restoration or preference writes")
    probe.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    expect(ApplicationLaunchMode(arguments: ["app"]) == .normal && ApplicationLaunchMode(arguments: ["app", "--bluetooth-app-status"]) == .normal,
           "ordinary GUI and legacy status routing remain unchanged")
    var normalFactoryCalls = 0, probeFactoryCalls = 0
    _ = ApplicationLaunchMode.normal.delegate(normal: { normalFactoryCalls += 1; return ProbeLaunchDelegateFixture() },
                                              probe: { probeFactoryCalls += 1; return ProbeLaunchDelegateFixture() })
    expect(normalFactoryCalls == 1 && probeFactoryCalls == 0, "normal launch still constructs only the normal delegate")

    for invalid: Any in ["not-an-array", ["bad"], ["AABBCCDDEE01", "aa:bb:cc:dd:ee:01"], [7], ["AABBCCDDEE01", "AABBCCDDEE01"]] {
        var nativeFactories = 0
        let malformed = BluetoothReadOnlyProbeRun(readValue: { _ in invalid }, makeProbe: {
            nativeFactories += 1
            return BluetoothControlProbe(authorized: { true }, controllerOn: { true }, lookup: { _ in nil }, diagnostics: logger)
        }, diagnostics: logger)
        let fields = malformed.run(operation: UUID().uuidString, shouldContinue: { true })
        expect(fields["probe_stage"] == "invalid_saved_identity" && fields["saved_count"] == "unknown" && fields["protected_count"] == "unknown" && nativeFactories == 0,
               "malformed saved values report unknown counts and cannot construct native getter capabilities")
    }
    var canceledWork: (() -> Void)?, canceledReads = 0
    let invalidProtected = BluetoothReadOnlyProbeRun(readValue: { key in key == "bluetooth.autoAddresses" ? ["AABBCCDDEE01"] : "invalid" },
        makeProbe: { fatalError("invalid protected identity must not construct native getters") }, diagnostics: logger)
    let protectedResult = invalidProtected.run(operation: UUID().uuidString, shouldContinue: { true })
    expect(protectedResult["probe_stage"] == "invalid_saved_identity" && protectedResult["saved_count"] == "unknown",
           "malformed protected preferences fail before any native getter and do not imply empty protection")
    var unbundled = run
    unbundled.isAppBundle = { false }
    let readsBeforeUnbundled = preferenceReads.count
    expect(unbundled.run(operation: UUID().uuidString, shouldContinue: { true })["probe_stage"] == "not_app_bundle" && preferenceReads.count == readsBeforeUnbundled,
           "unbundled command context cannot run preference or native qualification reads")
    let canceled = BluetoothReadOnlyProbeDelegate(run: .init(readValue: { _ in canceledReads += 1; return nil }, makeProbe: { fatalError("canceled probe must not construct native getters") }, diagnostics: logger), work: { canceledWork = $0 }, present: { _ in })
    canceled.applicationDidFinishLaunching(notification)
    expect(canceled.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "quit before probe work needs no cleanup drain")
    canceledWork?()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    expect(canceledReads == 0 && canceled.resultText == nil, "canceled probe does not read settings or publish a late completion")
    expect(logger.flushForTesting(timeout: 2), "probe-launch fixture flushes injected diagnostics only in tests")
    let records = sink.text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    let begin = records.first { $0["event"] as? String == "readonly_probe_begin" }
    let token = begin?["operation"] as? String
    expect(token != nil && records.contains { $0["event"] as? String == "readonly_probe_result" && $0["operation"] as? String == token } && records.contains { $0["event"] as? String == "native_control_probe" && $0["operation"] as? String == token },
           "probe begin, getter result and completion share one run UUID at default info threshold")
    expect(!sink.text.contains("AA:BB") && !sink.text.contains("aabbccddee") && !sink.text.contains("not-an-array"),
           "probe launch diagnostics exclude raw preferences and all target identities")
}

private final class ObservationMutationRunner: CommandRunning {
    private let lock = NSLock()
    private var recorded = [[String]]()
    var inventory: [BluetoothDevice]
    var failing = Set<String>()
    var failReadAfterMutation = false
    var alternateAddressAfterMutation: [String: String] = [:]
    private var mutated = false
    init(_ inventory: [BluetoothDevice]) { self.inventory = inventory }
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
        if arguments == ["--power"] { return "1" }
        if arguments == ["--paired", "--format", "json"] {
            if mutated && failReadAfterMutation { throw ToggleError(message: "Injected read failure") }
            let rows = inventory.map { ["address": $0.address, "name": $0.name, "connected": $0.connected] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        }
        if arguments.count == 2, ["--connect", "--disconnect"].contains(arguments[0]) {
            mutated = true
            let address = arguments[1]
            inventory = inventory.map { device in
                BluetoothDevice(address: device.address == address ? alternateAddressAfterMutation[device.address] ?? device.address : device.address,
                                name: device.name, connected: device.address == address ? arguments[0] == "--connect" : device.connected)
            }
            if failing.contains(address) { throw ToggleError(message: "Injected control failure") }
            return ""
        }
        throw ToggleError(message: "Unexpected fixture command")
    }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
}

func runBluetoothAutomaticPresentationTests() throws {
    let first = BluetoothDevice(address: "aa-bb-cc-dd-ee-01", name: "First", connected: false)
    let second = BluetoothDevice(address: "aa-bb-cc-dd-ee-02", name: "Second", connected: false)
    for mode in ["success", "known-failure", "unknown-failure"] {
        let suite = "fix-mac-os.observation-auto.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain); defaults.removePersistentDomain(forName: suite) }
        defaults.set([first.address, second.address], forKey: "bluetooth.autoAddresses")
        defaults.set(true, forKey: "bluetooth.autoEnabled")
        defaults.set(true, forKey: "bluetooth.legacyTakenOver")
        defaults.set(false, forKey: "bluetooth.protectAudio")
        defaults.set(false, forKey: "bluetooth.switchAudio")
        let runner = ObservationMutationRunner([first, second])
        if mode != "success" { runner.failing = [second.address] }
        if mode == "unknown-failure" { runner.failReadAfterMutation = true }
        let module = BluetoothModule(defaults: defaults,
            backend: BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, waitForConnection: {},
                                      observationService: BluetoothObservationService { _ in throw BluetoothReadIssue.unavailable }),
            importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
        defer { module.stop() }
        func wait() {
            let deadline = Date().addingTimeInterval(2)
            while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(!module.isBusy, "automatic presentation fixture drains")
        }
        module.poll(); wait()
        if mode == "unknown-failure" {
            expect(!module.controlsAvailable && module.readback?.helperDevices == nil,
                   "failed post-mutation read marks primary state unknown and blocks controls")
        } else {
            expect(module.displayedDevices == module.devices && module.displayedDevices.allSatisfy(\.connected),
                   "\(mode): presentation reflects latest helper read after automatic mutations")
            expect(module.readback?.native == nil && module.readback?.helperDevices == module.devices,
                   "\(mode): fresh primary evidence replaces pre-mutation presentation")
            let shown = module.displayedDevices.first!
            expect(shown.connected, "connected presentation offers Disconnect, never Connect")
            module.autoEnabled = false; wait()
            module.toggleConnection(shown.address); wait()
            expect(runner.calls.last(where: { ["--connect", "--disconnect"].contains($0.first ?? "") }) == ["--disconnect", shown.address],
                   "Disconnect presentation dispatches actual disconnect")
        }
    }
}

func runBluetoothIdentityTests() throws {
    let raw = "aa-bb-cc-dd-ee-01", saved = "AA:BB:CC:DD:EE:01"
    for mode in ["automatic", "manual", "duplicate", "invalid"] {
        let suite = "fix-mac-os.observation-identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain); defaults.removePersistentDomain(forName: suite) }
        let target = mode == "invalid" ? "not-a-device" : saved
        defaults.set([target], forKey: "bluetooth.autoAddresses")
        defaults.set(mode == "automatic", forKey: "bluetooth.autoEnabled")
        defaults.set(true, forKey: "bluetooth.legacyTakenOver")
        defaults.set(false, forKey: "bluetooth.protectAudio")
        defaults.set(false, forKey: "bluetooth.switchAudio")
        var inventory = [BluetoothDevice(address: raw, name: "Identity fixture", connected: mode == "manual")]
        if mode == "duplicate" { inventory.append(BluetoothDevice(address: saved, name: "Duplicate fixture", connected: true)) }
        let runner = ObservationMutationRunner(inventory)
        if mode == "automatic" || mode == "manual" { runner.alternateAddressAfterMutation[raw] = "AABBCCDDEE01" }
        let module = BluetoothModule(defaults: defaults,
            backend: BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, waitForConnection: {},
                                      observationService: BluetoothObservationService { _ in throw BluetoothReadIssue.unavailable }),
            importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
        defer { module.stop() }
        func wait() {
            let deadline = Date().addingTimeInterval(2)
            while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(!module.isBusy, "canonical identity fixture drains")
        }
        module.poll(); wait()
        if mode == "automatic" {
            expect(module.devices.first?.connected == true && runner.calls.contains(["--connect", raw]),
                   "saved colon-uppercase target reconnects using current helper hyphen-lowercase identity")
        } else if mode == "manual" {
            let shown = module.displayedDevices.first!
            expect(shown.address == saved && shown.connected, "presentation preserves saved target spelling")
            module.toggleConnection(shown.address); wait()
            expect(runner.calls.contains(["--disconnect", raw]) && module.devices.first?.connected == false,
                   "presentation toggle resolves current helper raw identity and verifies disconnect canonically")
            module.requestConnection(true, address: "AABBCCDDEE01"); wait()
            expect(runner.calls.contains(["--connect", "AABBCCDDEE01"]) && module.displayedDevices.first?.connected == true,
                   "manual compact identity resolves helper raw address and verifies connect")
        } else {
            let before = runner.calls.count
            module.requestConnection(true, address: target); module.toggleConnection(target); wait()
            expect(!runner.calls.dropFirst(before).contains(where: { ["--connect", "--disconnect"].contains($0.first ?? "") }),
                   "\(mode): ambiguous or invalid identity cannot authorize a mutation")
            if mode == "duplicate" { expect(!module.controlsAvailable, "duplicate canonical helper identity fails closed") }
            else { expect(!module.displayedDevices.contains { BluetoothIdentity.matches(target, $0.address) }, "invalid saved identity remains unavailable") }
        }
        expect(module.autoAddresses == [target] && defaults.stringArray(forKey: "bluetooth.autoAddresses") == [target],
               "\(mode): canonical resolution does not migrate stored target IDs")
    }
}

func runBluetoothMergedAdmissionTests() throws {
    let off = try JSONSerialization.data(withJSONObject: profilerFixture(power: "attrib_off"))
    for revoke in [false, true] {
        let suite = "fix-mac-os.merged-admission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "bluetooth.autoEnabled")
        defaults.set(true, forKey: "bluetooth.legacyTakenOver")
        let runner = ObservationRunner(); runner.allowFixturePowerOn = true
        var now: TimeInterval = 0, fetches = 0
        var authorization = CBManagerAuthorization.allowedAlways
        let entered = DispatchSemaphore(value: 0)
        let service = BluetoothObservationService(clock: { now }) { continuing in
            fetches += 1
            if fetches != 2 { return off }
            entered.signal()
            let deadline = Date().addingTimeInterval(2)
            while continuing() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            throw BluetoothReadIssue.unavailable
        }
        let module = BluetoothModule(defaults: defaults,
            backend: BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, observationService: service),
            importLegacyConfiguration: false, authorizationProvider: { authorization })
        defer { module.stop() }
        func wait() {
            let deadline = Date().addingTimeInterval(3)
            while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(!module.isBusy, "merged queued-admission fixture drains")
        }
        module.poll(); wait()
        expect(module.controlsAvailable, "coherent off comparison initially permits explicit power request")
        service.invalidate(); module.poll()
        expect(entered.wait(timeout: .now() + 1) == .success, "replacement native comparison reaches deterministic gate")
        module.turnBluetoothOn()
        if revoke { authorization = .denied }
        wait()
        expect(!runner.calls.contains(["--power", "1"]) && !module.controlsAvailable,
               "canceled unknown comparison or revoked access cannot drain queued power using old admission")
        authorization = .allowedAlways
        now = 31; module.poll(); wait()
        expect(module.controlsAvailable, "fresh uncanceled verification restores admission after canceled comparison")
        module.turnBluetoothOn(); wait()
        expect(runner.calls.contains(["--power", "1"]) && module.controlsAvailable,
               "successful explicit retry uses original helper verification after recovery")
    }
    try runBluetoothIdleExpiryAndAuthorizationTests(off)
}

private func runBluetoothIdleExpiryAndAuthorizationTests(_ off: Data) throws {
    let suite = "fix-mac-os.merged-expiry.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "bluetooth.autoEnabled")
    defaults.set(true, forKey: "bluetooth.legacyTakenOver")
    let runner = ObservationRunner(); runner.allowFixturePowerOn = true
    var now: TimeInterval = 0
    let service = BluetoothObservationService(clock: { now }) { _ in off }
    let module = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, observationService: service),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    defer { module.stop() }
    func wait(_ module: BluetoothModule) {
        let deadline = Date().addingTimeInterval(3)
        while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(!module.isBusy, "idle expiry/authorization fixture drains")
    }
    module.poll(); wait(module)
    now = 31
    module.turnBluetoothOn(); wait(module)
    expect(!module.controlsAvailable && !runner.calls.contains(["--power", "1"]) && module.reconnectSummary.contains("out of date"),
           "idle expired native evidence cannot authorize power before the next poll")
    module.poll(); wait(module)
    expect(module.controlsAvailable, "new complete comparison renews idle-expired admission")
    module.turnBluetoothOn(); wait(module)
    expect(runner.calls.contains(["--power", "1"]), "renewed comparison allows only an explicit helper power retry")

    let queuedRunner = ObservationRunner(); queuedRunner.allowFixturePowerOn = true
    var authorization = CBManagerAuthorization.allowedAlways
    let queued = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: queuedRunner, blueutil: "/fixture/blueutil", audioTool: nil),
        importLegacyConfiguration: false, authorizationProvider: { authorization })
    defer { queued.stop() }
    queued.poll(); wait(queued)
    let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    queuedRunner.powerGate = gate; queuedRunner.powerEntered = entered
    queued.poll()
    expect(entered.wait(timeout: .now() + 1) == .success, "authorization-only queued request reaches helper gate without native comparison")
    queued.turnBluetoothOn(); authorization = .denied
    gate.signal(); wait(queued)
    expect(!queuedRunner.calls.contains(["--power", "1"]), "permission-only drain guard rejects queued power without relying on canceled native verification")
}

func runBluetoothMergedManualTests() throws {
    let first = BluetoothDevice(address: "aa-bb-cc-dd-ee-01", name: "Manual fixture", connected: false)
    for unknown in [false, true] {
        let suite = "fix-mac-os.merged-manual.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "bluetooth.autoEnabled")
        defaults.set(true, forKey: "bluetooth.legacyTakenOver")
        let runner = ObservationMutationRunner([first]); runner.failing = [first.address]
        runner.failReadAfterMutation = unknown
        let module = BluetoothModule(defaults: defaults,
            backend: BluetoothBackend(runner: runner, blueutil: "/fixture/blueutil", audioTool: nil, waitForConnection: {},
                                      observationService: BluetoothObservationService { _ in throw BluetoothReadIssue.unavailable }),
            importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
        defer { module.stop() }
        func wait() {
            let deadline = Date().addingTimeInterval(2)
            while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(!module.isBusy, "merged manual readback fixture drains")
        }
        module.poll(); wait(); module.requestConnection(true, address: first.address); wait()
        if unknown {
            expect(!module.controlsAvailable && module.readback?.helperDevices == nil,
                   "unknown manual post-command state blocks control without inventing a readback")
        } else {
            expect(module.controlsAvailable && module.displayedDevices.first?.connected == true && module.lastError != nil,
                   "failed manual command with known changed state publishes fresh helper presentation and retains failure")
        }
    }
    expect(BluetoothModule.ManualOperation.connection("AA:BB:CC:DD:EE:01", true) == .connection("aa-bb-cc-dd-ee-01", true),
           "manual operation retry identity is canonical across helper spelling changes")
    expect(BluetoothModule.ManualOperation.connection("AA:BB:CC:DD:EE:01", true) != .connection("aa-bb-cc-dd-ee-01", false),
           "canonical retry identity retains the requested direction")
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
    let module = BluetoothModule(defaults: defaults, backend: backend, importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, diagnostics: logger)
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
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, diagnostics: logger)
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
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, diagnostics: logger)
    cancelModule.poll()
    expect(entered.wait(timeout: .now() + 1) == .success, "cancel fixture reaches native read")
    var stopped = 0, heartbeat = false
    cancelModule.stop { stopped += 1 }
    DispatchQueue.main.async { heartbeat = true }
    let deadline = Date().addingTimeInterval(2)
    while stopped == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    expect(stopped == 1 && heartbeat && cancelModule.readback == nil, "stop cancels native work, drains once and rejects late presentation while main stays responsive")
}

func runBluetoothProfilerProcessFixtures(repetitions: Int = 1) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiler-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var lastTrace: BluetoothProfilerTrace?
    func run(_ body: String, timeout: TimeInterval = 2, limit: Int = 4096, continuing: @escaping () -> Bool = { true }) -> Result<Data, Error> {
        lastTrace = nil
        do {
            // Never overwrite a path previously handed to an interpreter.
            let script = root.appendingPathComponent("profiler-\(UUID().uuidString)")
            try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let box = ObservationProcessResult()
            let process = BluetoothProfilerProcess(executable: script.path, arguments: [], timeout: timeout, outputLimit: limit,
                                                   trace: { box.capture($0) })
            DispatchQueue.global().async { box.finish(Result { try process.read(shouldContinue: continuing) }) }
            var heartbeat = false
            DispatchQueue.main.async { heartbeat = true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            let deadline = Date().addingTimeInterval(4)
            while box.result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            expect(heartbeat && box.result != nil, "bounded process runs off main and completes once while main queue advances")
            lastTrace = box.trace
            return box.result ?? .failure(BluetoothReadIssue.timeout)
        } catch { return .failure(error) }
    }
    func failure(_ result: Result<Data, Error>, _ issue: BluetoothReadIssue) {
        let actual: BluetoothReadIssue?
        if case .failure(let error) = result { actual = error as? BluetoothReadIssue }
        else { actual = nil }
        if actual != issue {
            print("PROCESS expected=\(issue.rawValue) actual=\(actual?.rawValue ?? "success_or_unclassified") wait_status=\(lastTrace?.waitStatus ?? -1) stdout_eof=\(lastTrace?.stdoutEOF ?? false) stderr_eof=\(lastTrace?.stderrEOF ?? false) bytes=\(lastTrace?.outputBytes ?? -1) elapsed_ms=\(lastTrace?.elapsedMS ?? -1)")
        }
        expect(actual == issue, "bounded process reports \(issue)")
    }
    for iteration in 1...repetitions {
        let finite = run("printf '{}' ")
        expect((try? finite.get()) == Data("{}".utf8), "bounded subprocess captures finite fixture output")
        for body in ["echo SENSITIVE-ERROR >&2; exit 75", "exec 1>&- 2>&-; /bin/sleep 0.02; exit 75", "/bin/sleep 0.03 &\nprintf '{}'; exit 75"] {
            failure(run(body), .exitFailure)
            expect(lastTrace?.waitStatus == 75 << 8 && lastTrace?.stdoutEOF == true && lastTrace?.stderrEOF == true,
                   "exit-75 protocol collects both pipe EOFs and actual child status, round \(iteration)")
        }
    }
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
