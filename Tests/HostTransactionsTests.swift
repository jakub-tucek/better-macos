import Foundation

private final class QuitFixture {
    let host = HostTransactions()
    var busy = false
    var mouseClean = true
    var clipboardClean = true
    var recovery = false
    var hasSpaces = true
    var events: [String] = []
    var drains: [(Bool) -> Void] = []
    var replies: [Bool] = []
    var vetoes: [HostTransactions.Veto] = []
    var readinessRefreshes = 0
    var onMouse: (() -> Void)?
    var onResume: (() -> Void)?
    var onVeto: (() -> Void)?
    var inlineDrain = false

    @discardableResult func request() -> HostTransactions.Decision {
        let actions = HostTransactions.QuitActions(
            isBusy: { self.events.append("busy"); return self.busy },
            prepareMouse: { self.events.append("mouse"); self.onMouse?(); return self.mouseClean },
            quiesce: { self.events.append("quiesce") },
            prepareClipboard: { self.events.append("clipboard"); return self.clipboardClean },
            needsDisplayRecovery: { self.recovery },
            restoreDisplays: { self.events.append("displays"); self.drains.append($0); if self.inlineDrain { $0(true) } },
            suspendSpaces: hasSpaces ? { done in
                self.events.append("spaces"); self.drains.append { _ in done() }
                if self.inlineDrain { done() }
            } : nil,
            resumeClipboard: { self.events.append("resume clipboard"); self.onResume?() },
            restoreSpacesChoice: { self.events.append("restore spaces choice") },
            didReopen: { self.readinessRefreshes += 1; self.onVeto?() },
            didVeto: { self.vetoes.append($0) })
        return host.requestQuit(actions) { self.replies.append($0) }
    }

    func deliver(_ approved: Bool = true, index: Int = 0) {
        drains[index](approved)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

func runHostTransactionsTests() {
    for veto in ["busy", "mouse", "clipboard"] {
        let fixture = QuitFixture()
        fixture.busy = veto == "busy"
        fixture.mouseClean = veto != "mouse"
        fixture.clipboardClean = veto != "clipboard"
        expect(fixture.request() == .cancel && fixture.host.acceptsActions && fixture.replies.isEmpty,
               "initial \(veto) veto cancels synchronously and reopens host admission")
        let expected = veto == "busy" ? ["busy"] : veto == "mouse" ? ["busy", "mouse"] :
            ["busy", "mouse", "quiesce", "clipboard", "resume clipboard"]
        expect(fixture.events == expected, "initial \(veto) veto preserves feature preparation ordering and untouched later features")
        expect(fixture.readinessRefreshes == (veto == "clipboard" ? 1 : 0),
               "initial \(veto) veto only reconciles readiness when cleanup actually quiesced features")
    }

    let immediate = QuitFixture()
    immediate.hasSpaces = false
    expect(immediate.request() == .now && !immediate.host.acceptsActions && immediate.replies.isEmpty,
           "host without asynchronous cleanup approves immediately and stays closed")
    let immediateEvents = immediate.events
    expect(immediate.request() == .later && immediate.events == immediateEvents,
           "repeated approved quit never runs feature preparation again")

    let inline = QuitFixture()
    inline.inlineDrain = true
    expect(inline.request() == .later && inline.replies.isEmpty && !inline.host.acceptsActions,
           "inline Spaces drain cannot reply before the host returns terminate-later")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    expect(inline.replies == [true] && !inline.host.acceptsActions,
           "inline drain receives exactly one deferred approval")

    for failure in ["mouse", "clipboard", "busy", "recovery", "none"] {
        let fixture = QuitFixture()
        fixture.recovery = true
        var reentrantDecisions: [HostTransactions.Decision] = []
        fixture.onMouse = {
            expect(!fixture.host.acceptsActions, "host admission is closed inside feature preparation")
            reentrantDecisions.append(fixture.request())
        }
        expect(fixture.request() == .later && fixture.events == ["busy", "mouse", "quiesce", "clipboard", "displays"],
               "display recovery takes precedence over a separate Spaces drain")
        let beforeRepeated = fixture.events
        expect(fixture.request() == .later && fixture.events == beforeRepeated && fixture.drains.count == 1,
               "repeated quit during blocked recovery neither drains twice nor registers another reply")
        var mutations = 0
        let lateAction = { if fixture.host.acceptsActions { mutations += 1 } }
        lateAction()
        expect(mutations == 0 && fixture.replies.isEmpty, "retained actions cannot mutate during blocked recovery")
        fixture.mouseClean = failure != "mouse"
        fixture.clipboardClean = failure != "clipboard"
        fixture.busy = failure == "busy"
        fixture.onResume = {
            lateAction()
            expect(!fixture.host.acceptsActions && fixture.request() == .later,
                   "cancellation keeps admission closed while feature monitoring is reopened")
        }
        fixture.onVeto = {
            expect(fixture.host.acceptsActions, "canceled quit reconciles host readiness only after reopening admission")
        }
        fixture.deliver(failure != "recovery")
        expect(fixture.events.contains("clipboard") && Array(fixture.events.dropFirst(5).prefix(3)) == ["mouse", "clipboard", "busy"],
               "final \(failure) result rechecks Mouse, Clipboard and host transactions after recovery")
        expect(reentrantDecisions == [.later, .later], "reentrant feature callbacks cannot initiate a competing quit attempt")
        expect(fixture.replies == [failure == "none"] && fixture.host.acceptsActions == (failure != "none"),
               "final \(failure) result approves closed or cancels reopened exactly once")
        lateAction()
        expect(mutations == (failure == "none" ? 0 : 1), "late actions follow final \(failure) admission decision")
        let finishedEvents = fixture.events
        fixture.deliver()
        expect(fixture.replies.count == 1 && fixture.events == finishedEvents,
               "duplicate recovery callback cannot recheck or reply after final \(failure) decision")
        if failure != "none" {
            fixture.mouseClean = true; fixture.clipboardClean = true; fixture.busy = false
            expect(fixture.request() == .later && fixture.drains.count == 2,
                   "canceled \(failure) attempt allows a fresh quit")
            fixture.deliver(index: 0)
            expect(fixture.replies.count == 1 && !fixture.host.acceptsActions,
                   "stale callback from canceled attempt cannot finish the fresh quit")
            fixture.deliver(index: 1)
            expect(fixture.replies == [false, true] && !fixture.host.acceptsActions,
                   "fresh quit after \(failure) cancellation approves independently")
        }
        // Fixture hooks intentionally capture it during adversarial reentrancy.
        fixture.onMouse = nil; fixture.onResume = nil; fixture.onVeto = nil
        fixture.drains = []
    }

    let clipboard = QuitFixture()
    clipboard.request()
    clipboard.clipboardClean = false
    clipboard.mouseClean = false
    clipboard.deliver()
    expect(clipboard.vetoes == [.clipboard] && clipboard.events.suffix(2) == ["resume clipboard", "restore spaces choice"],
           "late Clipboard veto takes presentation priority while canceled Spaces suspension restores saved choice")
    clipboard.clipboardClean = true; clipboard.mouseClean = true
    clipboard.request()
    clipboard.deliver(index: 1)
    expect(clipboard.replies == [false, true] && !clipboard.host.acceptsActions,
           "Spaces retry shares the same final checks and approved admission as display recovery")
    clipboard.drains = []
}
