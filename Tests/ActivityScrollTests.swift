import AppKit

func runActivityScrollTests(journal: ActivityJournal, window: NSWindow) {
    for value in 1...80 { journal.record(.awakeStart(value), trigger: .user, result: .completed) }
    window.setContentSize(NSSize(width: 720, height: 560))
    let content = window.contentView!
    func settle() {
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        content.layoutSubtreeIfNeeded()
    }
    func histories(_ view: NSView) -> [ActivityHistoryNativeView] {
        (view as? ActivityHistoryNativeView).map { [$0] } ?? view.subviews.flatMap(histories)
    }
    settle()
    guard let history = histories(content).first else { expect(false, "activity native viewport is mounted"); return }
    let scroll = history.scrollView
    func read(_ index: Int, offset: CGFloat = 13) -> ActivityVisiblePosition {
        let id = history.orderedIDs[index]
        let frame = history.rowFrame(id)!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: frame.minY + offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        return history.visiblePosition!
    }
    func unchanged(_ before: ActivityVisiblePosition, _ message: String) {
        let after = history.visiblePosition
        expect(after?.id == before.id && abs((after?.offset ?? .infinity) - before.offset) < 0.5, message)
    }
    var anchor = read(15)
    for burst in [2, 7] {
        for _ in 0..<burst { journal.record(.awakeStart(30), trigger: .automatic, result: .completed) }
        settle()
        unchanged(anchor, "activity preserves visible row identity and within-row offset after \(burst) coalesced insertions")
    }
    let above = history.orderedIDs[2]
    let collapsedHeight = history.rowFrame(above)!.height
    let originalDisclosure = history.detailsButton(above)
    history.detailsButton(above)?.performClick(nil)
    unchanged(anchor, "activity expansion above the viewport preserves the visible row and offset")
    expect(history.rowFrame(above)!.height > collapsedHeight + 10, "scrolling fixture includes an actually taller expanded row")
    expect(history.detailsButton(above)?.state == .on, "activity native disclosure retains expanded state")
    for index in 0..<7 {
        let id = journal.begin(.windowRestore, trigger: .automatic)
        if index % 2 == 0 { journal.finish(id, result: .windowsRestored(ActivityWindowCounts(restored: 5, missing: 3, ambiguous: 1, unsupported: 2))) }
        settle()
        unchanged(anchor, "activity preserves the reader through rapid successive publications \(index)")
    }
    expect(history.detailsButton(above)?.state == .on, "activity publications do not reset existing disclosure state")
    expect(history.detailsButton(above) === originalDisclosure, "activity updates retain existing native row and disclosure identity")
    let wrapping = journal.begin(.windowRestore, trigger: .automatic)
    journal.finish(wrapping, result: .windowsRestored(ActivityWindowCounts(restored: 10, missing: 100, ambiguous: 20, unsupported: 30, excluded: 40, failed: 5)))
    settle(); history.detailsButton(wrapping)?.performClick(nil)
    anchor = read(20)
    let wideHeight = history.rowFrame(wrapping)!.height
    window.setContentSize(NSSize(width: 540, height: 420)); settle()
    unchanged(anchor, "activity width and wrapping changes preserve visible row identity and within-row offset")
    expect(history.rowFrame(wrapping)!.height > wideHeight, "native fixture actually rewraps expanded details to a different height")
    window.setContentSize(NSSize(width: 720, height: 560)); settle()
    unchanged(anchor, "activity restores wider layout without shifting the reader")
    let changing = journal.begin(.windowRestore, trigger: .automatic)
    settle()
    history.detailsButton(changing)?.performClick(nil)
    anchor = read(20)
    journal.finish(changing, result: .windowsRestored(ActivityWindowCounts(restored: 10, missing: 100, ambiguous: 20, unsupported: 30, excluded: 40, failed: 5)))
    settle()
    unchanged(anchor, "activity terminal detail-height changes above the viewport preserve the reader")
    anchor = read(20, offset: 21)
    for _ in 0..<7 {
        let id = journal.begin(.displayRecovery(.failedChange), trigger: .recovery)
        journal.finish(id, result: .uncertainDisplay)
    }
    history.update(journal.entries)
    unchanged(anchor, "activity single native publication preserves anchor across a seven-row batch")
    settle(); unchanged(anchor, "activity SwiftUI update after native layout does not shift its restored anchor")
    let current = history.visiblePosition!
    history.detailsButton(current.id)?.performClick(nil)
    unchanged(current, "expanding the visible row preserves its within-row offset")
    if let frame = history.rowFrame(current.id) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: frame.maxY - 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        history.detailsButton(current.id)?.performClick(nil)
        let collapsed = history.rowFrame(current.id)!
        expect(history.visiblePosition?.id == current.id && abs(scroll.contentView.bounds.minY - (collapsed.maxY - 1)) < 0.5, "collapsing an anchor clamps an obsolete within-row offset to that row's remaining bottom")
    }
    for _ in 0..<300 { journal.record(.awakeStop, trigger: .automatic, result: .completed) }
    settle()
    anchor = read(100)
    for _ in 0..<7 { journal.record(.awakeStart(10), trigger: .automatic, result: .completed) }
    settle(); unchanged(anchor, "activity cap eviction preserves a surviving visible row and offset")
    _ = read(297)
    let oldOrder = history.orderedIDs
    let oldAnchor = history.visiblePosition!
    for _ in 0..<10 { journal.record(.awakeStop, trigger: .automatic, result: .completed) }
    settle()
    let index = oldOrder.firstIndex(of: oldAnchor.id)!
    let remaining = Set(history.orderedIDs)
    let candidate = (Array(oldOrder.dropFirst(index + 1)) + Array(oldOrder.prefix(index).reversed())).first { remaining.contains($0) }
    if let candidate, let row = history.rowFrame(candidate) {
        let maxOffset = max(0, scroll.documentView!.frame.height - scroll.contentSize.height)
        expect(abs(scroll.contentView.bounds.minY - min(row.minY, maxOffset)) < 0.5, "activity evicted anchor uses nearest surviving row with defined viewport clamping")
    } else { expect(false, "eviction fixture must retain a neighboring old row") }
    history.latestButton.performClick(nil)
    expect(scroll.contentView.bounds.minY == 0, "explicit Show latest resets to the top")
    for _ in 0..<7 { journal.record(.awakeStart(5), trigger: .user, result: .completed) }
    settle()
    expect(scroll.contentView.bounds.minY == 0, "activity follows batched incoming rows only when already at the top")
    journal.clear(); settle()
    expect(history.orderedIDs.isEmpty && history.visiblePosition == nil && scroll.contentView.bounds.minY == 0, "activity Clear resets viewport and disclosures without retaining an obsolete anchor")
}
