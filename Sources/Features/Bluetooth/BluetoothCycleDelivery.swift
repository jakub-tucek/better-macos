import Foundation

/// One helper cycle, from callback binding through terminal main delivery.
final class BluetoothCycleDelivery: @unchecked Sendable {
    struct Scheduling {
        // Both executors must be serial and FIFO. Production delivery runs on main.
        let worker: (@escaping () -> Void) -> Void
        let delivery: (@escaping () -> Void) -> Void

        static func live() -> Scheduling {
            let queue = DispatchQueue(label: "better-macos.bluetooth", qos: .utility)
            return Scheduling(worker: { queue.async(execute: DispatchWorkItem(block: $0)) },
                              delivery: { DispatchQueue.main.async(execute: $0) })
        }
    }

    enum Operation {
        case automatic(BluetoothConfiguration)
        case manual(BluetoothModule.ManualOperation)
    }

    struct Callbacks {
        var isStopped: () -> Bool
        var discovery: (BluetoothDiscoveryRead) -> Void
        var observation: (BluetoothReadback) -> Void
        var progress: (BluetoothProgress) -> Void
        var route: (String) -> Void
        var completion: (Result<[BluetoothDevice], Error>) -> Void
    }

    private let scheduling: Scheduling
    private let lock = NSLock()
    private var canceled = false
    private var started = false
    private var workerStarted = false
    // Delivery-executor confined, unlike worker entry and cancellation.
    private var terminalDelivered = false

    init(scheduling: Scheduling) { self.scheduling = scheduling }
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }

    private enum Gate { case discovery, observation, automatic, manualPower }

    private func deliver(_ gate: Gate, callbacks: Callbacks, action: @escaping () -> Void) {
        scheduling.delivery { [self] in
            guard !terminalDelivered else { return }
            switch gate {
            case .discovery: guard !callbacks.isStopped() else { return }
            case .observation: guard !isCanceled, !callbacks.isStopped() else { return }
            case .automatic: guard !isCanceled else { return }
            case .manualPower: break // Explicit power progress historically survives cancellation/stop.
            }
            action()
        }
    }

    func start(backend: BluetoothBackend, operation: Operation, callbacks: Callbacks) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        var bound = backend
        let previousDiscovery = backend.onDiscoveryRead
        bound.onDiscoveryRead = { [self] read in
            previousDiscovery?(read)
            deliver(.discovery, callbacks: callbacks) { callbacks.discovery(read) }
        }
        bound.onObservation = { [self] observation in
            deliver(.observation, callbacks: callbacks) { callbacks.observation(observation) }
        }
        if case .automatic = operation {
            bound.routeOutput = { [self] name in
                deliver(.automatic, callbacks: callbacks) { callbacks.route(name) }
            }
        }
        // All callbacks bind BEFORE the backend value-copy crosses the worker boundary.
        let prepared = bound
        scheduling.worker { [self] in
            lock.lock()
            guard !workerStarted else { lock.unlock(); return }
            workerStarted = true
            lock.unlock()
            let result = Result {
                switch operation {
                case .automatic(let configuration):
                    return try prepared.reconcile(configuration, progress: { progress in
                        self.deliver(.automatic, callbacks: callbacks) { callbacks.progress(progress) }
                    }, shouldContinue: { !self.isCanceled })
                case .manual(.connection(let address, let connected)):
                    return try prepared.setConnected(connected, address: address)
                case .manual(.powerOn):
                    try prepared.turnPowerOn()
                    self.deliver(.manualPower, callbacks: callbacks) { callbacks.progress(.radio(true)) }
                    return try prepared.devices()
                }
            }
            // Retain until terminal delivery, even after stop/cancel. Preserve the actual result.
            scheduling.delivery { [self] in
                guard !terminalDelivered else { return }
                terminalDelivered = true
                callbacks.completion(result)
            }
        }
    }
}
