import Foundation

/// Reconciles desired cursor behavior after every host state transition. Keeping
/// this outside AppKit lets tests exercise the same confirmation/recovery path.
final class SystemControlLifecycle {
    struct State {
        var watchdogReady = false
        var displaySettling = true
        var displayOperation = false
        var pendingConfirmation = false
        var layoutFresh = false
        var cursorRequested = false
        var arrangementEnabled = false
        var layout: [DisplayPosition] = []

        var inputReady: Bool {
            watchdogReady && !displaySettling && !displayOperation && !pendingConfirmation
        }
        // Recovery must remain usable even when supervision is unavailable.
        var recoveryReady: Bool { !displaySettling && !displayOperation }
    }
    private let startCursor: ([DisplayPosition]) throws -> Void
    private let stopCursor: () -> Void

    init(startCursor: @escaping ([DisplayPosition]) throws -> Void, stopCursor: @escaping () -> Void) {
        self.startCursor = startCursor
        self.stopCursor = stopCursor
    }

    func reconcile(_ state: State) throws {
        guard state.inputReady, state.layoutFresh, state.cursorRequested, state.arrangementEnabled,
              state.layout.count > 1, DisplayTopology.isValidArrangement(state.layout) else {
            stopCursor()
            return
        }
        try startCursor(state.layout)
    }
}
