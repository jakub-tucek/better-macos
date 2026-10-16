import Foundation

/// Screen-change callbacks must return without querying graphics state. Wait
/// for a quiet period, coalescing notification storms into one later refresh.
final class DisplayRefreshGate {
    private let delay: TimeInterval
    private let refresh: () -> Void
    private var work: DispatchWorkItem?
    private var generation = 0
    private var refreshing = false
    private(set) var isSettling = false
    var onSettlingChanged: ((Bool) -> Void)?

    init(delay: TimeInterval = 1.5, refresh: @escaping () -> Void) {
        self.delay = delay
        self.refresh = refresh
    }

    /// Showing existing UI is not a topology change. Retry missing/failed
    /// snapshots, but never extend a real quiet period or reenter discovery.
    func requestRefreshForPresentation(snapshotIsFresh: Bool) {
        guard !snapshotIsFresh, !isSettling, !refreshing else { return }
        requestRefresh()
    }

    func requestRefresh() {
        generation += 1
        let requestedGeneration = generation
        work?.cancel()
        if !isSettling {
            isSettling = true
            onSettlingChanged?(true)
        }
        let task = DispatchWorkItem { [weak self] in
            guard let self, requestedGeneration == self.generation else { return }
            self.work = nil
            self.refreshing = true
            defer { self.refreshing = false }
            self.isSettling = false
            self.onSettlingChanged?(false)
            self.refresh()
        }
        work = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func cancel() {
        generation += 1
        work?.cancel()
        work = nil
        isSettling = false
    }
}
