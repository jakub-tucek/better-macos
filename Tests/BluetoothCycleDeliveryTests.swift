import Foundation

private final class CycleSteps {
    var workers: [() -> Void] = []
    var deliveries: [() -> Void] = []
    var scheduling: BluetoothCycleDelivery.Scheduling {
        .init(worker: { self.workers.append($0) }, delivery: { self.deliveries.append($0) })
    }
    func work() { workers.removeFirst()() }
    func drain() { while !deliveries.isEmpty { deliveries.removeFirst()() } }
}

private final class CycleFailure: LocalizedError {
    var errorDescription: String? { "exact cycle backend failure sentinel" }
}

private final class CycleRunner: CommandRunning {
    var connected = false
    var failure: Error?
    var calls: [[String]] = []
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        calls.append(arguments)
        if let failure { throw failure }
        switch arguments {
        case ["--power"], ["--power", "1"]: return "1"
        case ["--connect", "target"]: connected = true; return ""
        case ["--disconnect", "target"]: connected = false; return ""
        case ["--paired", "--format", "json"]:
            return "[{\"address\":\"target\",\"name\":\"Speaker\",\"connected\":\(connected)}]"
        default: preconditionFailure("Unexpected fixture command")
        }
    }
}

func runBluetoothCycleDeliveryTests() {
    let config = BluetoothConfiguration(enabled: true, autoAddresses: ["target"], protectOtherAudio: false, switchAudioOutput: true)
    for manual in [false, true] {
        for cancel in [false, true] {
            let steps = CycleSteps(), runner = CycleRunner()
            var backend = BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil,
                                           waitForConnection: {}, audioOutputs: { ["Speaker"] })
            var events: [String] = []
            var result: Result<[BluetoothDevice], Error>?
            backend.onDiscoveryRead = { _ in events.append("previous") }
            let cycle = BluetoothCycleDelivery(scheduling: steps.scheduling)
            let callbacks = BluetoothCycleDelivery.Callbacks(isStopped: { false }, discovery: { _ in events.append("discovery") },
                observation: { _ in events.append("observation") }, progress: { _ in events.append("progress") },
                route: { _ in events.append("route") }, completion: { result = $0; events.append("terminal") })
            let operation: BluetoothCycleDelivery.Operation = manual ? .manual(.connection("target", true)) : .automatic(config)
            cycle.start(backend: backend, operation: operation, callbacks: callbacks)
            cycle.start(backend: backend, operation: operation, callbacks: callbacks)
            expect(steps.workers.count == 1 && runner.calls.isEmpty, "Cycle admits one deferred worker")
            backend.onDiscoveryRead = { _ in events.append("wrong-copy") }
            steps.work()
            expect(result == nil && !steps.deliveries.isEmpty, "Worker return does not drain terminal lifetime")
            expect(events.allSatisfy { $0 == "previous" } && !events.isEmpty, "Prepared backend preserves previous worker discovery callback before delivery")
            let staleDeliveries = steps.deliveries
            let terminal = steps.deliveries.last!
            if cancel { cycle.cancel() }
            steps.drain()
            expect((try? result?.get().first?.connected) == true, "Canceled and uncanceled cycles retain actual backend success")
            expect(events.last == "terminal" && events.contains("discovery"), "Discovery ignores cancellation and precedes terminal")
            expect(!events.contains("wrong-copy"), "Worker uses callback-bound backend value copy")
            expect(events.contains("route") == (!manual && !cancel), "Only uncanceled automatic cycle delivers routing intent")
            expect(events.contains("progress") == (!manual && !cancel), "Automatic progress checks cancellation at delivery")
            if let route = events.firstIndex(of: "route"), let end = events.firstIndex(of: "terminal") {
                expect(route < end, "Route intent arrives before completion")
            }
            let before = events
            terminal()
            staleDeliveries.forEach { $0() }
            expect(events == before, "Duplicate terminal and stale nonterminal deliveries cannot republish")
        }
    }

    for manual in [false, true] {
        let steps = CycleSteps(), runner = CycleRunner(), failure = CycleFailure()
        runner.failure = failure
        let cycle = BluetoothCycleDelivery(scheduling: steps.scheduling)
        var stopped = false, terminals = 0, observations = 0, discoveries = 0
        var received: Error?
        let service = BluetoothObservationService(fetch: { _ in throw BluetoothReadIssue.unavailable })
        cycle.start(backend: BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil, observationService: service),
                    operation: manual ? .manual(.connection("target", true)) : .automatic(config), callbacks: .init(
                        isStopped: { stopped }, discovery: { _ in discoveries += 1 },
                        observation: { _ in observations += 1 }, progress: { _ in }, route: { _ in },
                        completion: { if case .failure(let error) = $0 { received = error }; terminals += 1 }))
        steps.work()
        expect(steps.deliveries.count == 3, "Discovery and observation callbacks bind before worker copy on both paths")
        cycle.cancel(); stopped = true
        steps.drain()
        expect(terminals == 1 && observations == 0 && discoveries == 0, "Stopped canceled cycle suppresses evidence but always drains")
        expect(received?.localizedDescription == "exact cycle backend failure sentinel",
               "Canceled failure retains backend error instead of success/cancellation")
    }

    for stopped in [false, true] {
        for canceled in [false, true] {
            let steps = CycleSteps(), runner = CycleRunner()
            runner.failure = CycleFailure()
            let service = BluetoothObservationService(fetch: { _ in throw BluetoothReadIssue.unavailable })
            var observations = 0, discoveries = 0, terminals = 0
            let cycle = BluetoothCycleDelivery(scheduling: steps.scheduling)
            cycle.start(backend: BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil, observationService: service),
                        operation: .automatic(config), callbacks: .init(isStopped: { stopped },
                            discovery: { _ in discoveries += 1 }, observation: { _ in observations += 1 },
                            progress: { _ in }, route: { _ in }, completion: { _ in terminals += 1 }))
            steps.work()
            if canceled { cycle.cancel() }
            steps.drain()
            expect(observations == (!stopped && !canceled ? 1 : 0), "Observation delivery checks both stopped state and cancellation")
            expect(discoveries == (!stopped ? 1 : 0) && terminals == 1, "Discovery ignores cancellation while terminal ignores both gates")
        }
    }

    do {
        let steps = CycleSteps(), runner = CycleRunner()
        var power = false, terminal = false
        let cycle = BluetoothCycleDelivery(scheduling: steps.scheduling)
        cycle.start(backend: BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil),
                    operation: .manual(.powerOn), callbacks: .init(isStopped: { true }, discovery: { _ in }, observation: { _ in },
                        progress: { if case .radio(true) = $0 { power = true } }, route: { _ in },
                        completion: { _ in expect(power, "Manual power progress precedes terminal even when stopped"); terminal = true }))
        steps.work(); cycle.cancel(); steps.drain()
        expect(power && terminal, "Manual power progress intentionally ignores stop and cancellation")
    }

    do {
        let steps = CycleSteps(), runner = CycleRunner()
        var terminals = 0
        var cycle: BluetoothCycleDelivery? = BluetoothCycleDelivery(scheduling: steps.scheduling)
        weak let retained = cycle
        cycle?.start(backend: BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil),
                     operation: .manual(.powerOn), callbacks: .init(isStopped: { true }, discovery: { _ in },
                         observation: { _ in }, progress: { _ in }, route: { _ in }, completion: { _ in terminals += 1 }))
        cycle?.cancel(); cycle = nil
        expect(retained != nil, "Queued worker retains canceled cycle without owner reference")
        steps.work()
        expect(retained != nil && terminals == 0, "Queued terminal retains cycle after worker returns")
        steps.drain()
        expect(retained == nil && terminals == 1, "Terminal drains once and releases delivery lifetime")
    }

    // Exercise the production owner boundary, including next-cycle admission and stop drain.
    let steps = CycleSteps(), runner = CycleRunner()
    let domain = "BluetoothCycleDeliveryTests.\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
    defer {
        defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
        defaults.removePersistentDomain(forName: domain)
    }
    defaults.set(false, forKey: "bluetooth.autoEnabled")
    let owner = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil, waitForConnection: {}),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, cycleScheduling: steps.scheduling)
    owner.poll()
    owner.requestConnection(true, address: "target")
    expect(owner.isBusy && owner.isManualBusy && steps.workers.count == 1, "Queued manual request waits for automatic terminal")
    steps.work()
    let oldDeliveries = steps.deliveries
    expect(owner.isBusy && steps.workers.isEmpty, "Owner remains busy after worker return before terminal")
    steps.drain()
    expect(owner.isBusy && steps.workers.count == 1, "Automatic terminal starts queued manual worker")
    let calls = runner.calls.count
    oldDeliveries.forEach { $0() }
    expect(owner.isBusy && runner.calls.count == calls && steps.workers.count == 1, "Old deliveries cannot release or alter next cycle")
    var drained = 0, reports = 0
    owner.onManualOperationCompleted = { _, _ in reports += 1 }
    owner.stop { drained += 1 }
    steps.work()
    expect(owner.isBusy && drained == 0, "Stop does not report worker drained before terminal delivery")
    steps.drain()
    expect(!owner.isBusy && drained == 1 && reports == 0 && steps.workers.isEmpty, "Stopped manual terminal drains once without publishing operation")
    oldDeliveries.forEach { $0() }
    expect(drained == 1, "Stale automatic terminal cannot duplicate stop drain")

    let reporting = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: runner, blueutil: "fixture", audioTool: nil, waitForConnection: {}),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, cycleScheduling: steps.scheduling)
    let failure = CycleFailure()
    runner.failure = failure
    var reportOrder: [String] = []
    reporting.onError = { error in
        expect(error as? CycleFailure === failure, "Owner error callback retains exact backend failure")
        reportOrder.append("error")
    }
    reporting.onManualOperationCompleted = { operation, result in
        expect(operation == .powerOn, "Manual completion retains operation identity")
        if case .failure(let error) = result {
            expect(error as? CycleFailure === failure, "Canceled manual operation reports original backend error object")
        } else { expect(false, "Canceled backend failure must not report success") }
        reportOrder.append("manual")
    }
    reporting.turnBluetoothOn()
    steps.work()
    reporting.switchAudioOutput = false // Cancels the active cycle before queued completion.
    expect(reporting.isBusy && reportOrder.isEmpty, "Manual reporting waits for delivery, not worker return")
    let replay = steps.deliveries
    steps.drain()
    expect(reportOrder == ["error", "manual"] && !reporting.isBusy, "Error precedes manual completion even after cancellation")
    replay.forEach { $0() }
    expect(reportOrder == ["error", "manual"], "Duplicate delivery cannot report manual operation twice")
}
