import Foundation

/// Main-thread host admission and quit ordering. Feature adapters retain ownership
/// of restoration; callers need not sequence cleanup or reopen after a veto.
final class HostTransactions {
    enum Decision { case cancel, now, later }
    enum Veto { case busy, mouse, clipboard, recovery }

    struct QuitActions {
        var isBusy: () -> Bool
        var prepareMouse: () -> Bool
        var quiesce: () -> Void
        var prepareClipboard: () -> Bool
        var needsDisplayRecovery: () -> Bool
        var restoreDisplays: (@escaping (Bool) -> Void) -> Void
        var suspendSpaces: ((@escaping () -> Void) -> Void)?
        var resumeClipboard: () -> Void
        var restoreSpacesChoice: () -> Void
        var didReopen: () -> Void
        var didVeto: (Veto) -> Void
    }

    private enum Phase: String { case open, preparing, draining, finishing, reopening, approved }
    private var phase = Phase.open
    private var attempt = 0
    private var operation = UUID().uuidString
    private let diagnostics: Diagnostics
    init(diagnostics: Diagnostics = .shared) { self.diagnostics = diagnostics }
    var diagnosticPhase: String { phase.rawValue }
    var acceptsActions: Bool { phase == .open }

    /// Deferred paths always complete on a later main-queue turn, even when a
    /// feature drains inline. Only the initiating request receives a reply.
    func requestQuit(_ actions: QuitActions, reply: @escaping (Bool) -> Void) -> Decision {
        guard acceptsActions else {
            diagnostics.emit("host", "quit_deferred", operation: operation, level: .debug, fields: ["phase": phase.rawValue])
            return .later
        }
        attempt += 1
        operation = UUID().uuidString
        diagnostics.emit("host", "quit_requested", operation: operation, level: .debug, fields: ["attempt": String(attempt)])
        let current = attempt
        phase = .preparing // Also closes admission during reentrant feature callbacks.
        guard !actions.isBusy() else {
            cancel(.busy, actions: actions, resume: false)
            return .cancel
        }
        guard actions.prepareMouse() else {
            cancel(.mouse, actions: actions, resume: false)
            return .cancel
        }
        actions.quiesce()
        guard actions.prepareClipboard() else {
            cancel(.clipboard, actions: actions, restoreSpaces: false)
            return .cancel
        }
        phase = .draining
        diagnostics.emit("host", "quit_draining", operation: operation, level: .debug)
        let complete: (Bool) -> Void = { [self] restored in
            DispatchQueue.main.async { [self] in
                guard attempt == current, phase == .draining else { return }
                reply(finish(restored: restored, actions: actions))
            }
        }
        if actions.needsDisplayRecovery() {
            actions.restoreDisplays(complete)
        } else if let suspend = actions.suspendSpaces {
            suspend { complete(true) }
        } else {
            // No asynchronous drain exists: initial preparation is sufficient.
            phase = .approved
            diagnostics.emit("host", "quit_approved", operation: operation)
            return .now
        }
        return .later
    }

    private func finish(restored: Bool, actions: QuitActions) -> Bool {
        phase = .finishing
        // Run both final checks even if recovery or the other feature vetoed.
        let mouseClean = actions.prepareMouse()
        let clipboardClean = actions.prepareClipboard()
        let busy = actions.isBusy()
        if restored && mouseClean && clipboardClean && !busy {
            phase = .approved
            diagnostics.emit("host", "quit_approved", operation: operation)
            return true
        }
        let veto: Veto = !clipboardClean ? .clipboard : !mouseClean ? .mouse : busy ? .busy : .recovery
        cancel(veto, actions: actions)
        return false
    }

    private func cancel(_ veto: Veto, actions: QuitActions, resume: Bool = true, restoreSpaces: Bool = true) {
        let reason: String
        switch veto {
        case .busy: reason = "busy"
        case .mouse: reason = "mouse"
        case .clipboard: reason = "clipboard"
        case .recovery: reason = "recovery"
        }
        diagnostics.emit("host", "quit_vetoed", outcome: "blocked", operation: operation, level: .warning,
                         fields: ["reason": reason, "phase": phase.rawValue])
        phase = .reopening
        if resume {
            actions.resumeClipboard()
            if restoreSpaces { actions.restoreSpacesChoice() }
        }
        phase = .open
        // Host readiness reconciliation must see reopened admission.
        if resume { actions.didReopen() }
        actions.didVeto(veto)
    }
}
