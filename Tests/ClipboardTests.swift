import AppKit
import ClipboardPolicy

private final class FakeClipboard: ClipboardAccess {
    var changeCount = 0
    var markedPrivate = false
    var value: String?
    var bytes: Data?
    var reads = 0
    var race = false
    func text() -> String? { reads += 1; if race { changeCount += 1 }; return value }
    func image() -> Data? { reads += 1; return bytes }
    func write(_ entry: ClipboardEntry) -> Bool { value = entry.text; bytes = entry.image; changeCount += 1; return true }
    func put(_ text: String?, image: Data? = nil) { value = text; bytes = image; changeCount += 1 }
}

private final class FailingClipboardArchive: ClipboardPersistence {
    var entries: [ClipboardEntry] = []
    var failing = false
    var failLoad = false
    var commitThenThrow = false
    var failClear = false
    var clearThenThrow = false
    var loads = 0
    var saves = 0
    var clears = 0
    func load() throws -> [ClipboardEntry] {
        loads += 1
        if failLoad { throw CocoaError(.fileReadNoPermission) }
        return entries
    }
    func save(_ entries: [ClipboardEntry]) throws {
        saves += 1
        if failing { throw CocoaError(.fileWriteNoPermission) }
        self.entries = entries
        if commitThenThrow { throw CocoaError(.fileWriteNoPermission) }
    }
    func clear() throws {
        clears += 1
        if failing || failClear { throw CocoaError(.fileWriteNoPermission) }
        entries = []
        if clearThenThrow { throw CocoaError(.fileWriteNoPermission) }
    }
}

/// This fixture owns only synthetic in-memory clipboard/image data. Never starts
/// the module's timer, reads a disk archive, or touches NSPasteboard.general.
private func runClipboardPanelTests() throws {
    _ = NSApplication.shared
    let suite = "fix-mac-os.clipboard-panel-fixture.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var date = Date()
    let board = FakeClipboard(), archive = FailingClipboardArchive()
    let history = ClipboardHistory(board: board, archive: archive, now: { date }, source: { "com.example.Fixture" })
    let module = ClipboardModule(defaults: defaults, history: history)
    let panel = module.makePanel()
    defer { panel.orderOut(nil) }
    expect(!history.recording && board.reads == 0 && archive.loads == 0 && archive.saves == 0,
           "building history panel neither captures nor reads storage or enables recording")
    expect(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeMain, "history stays a nonactivating non-main panel")
    func findButton(_ title: String) -> NSButton {
        panel.contentView!.subviews.compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
    func labels() -> [String] { panel.contentView!.subviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    func search(_ query: String) {
        module.search.stringValue = query
        module.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: module.search))
    }
    func key(_ code: UInt16, _ characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: panel.windowNumber, context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        panel.sendEvent(event)
    }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    func render(_ name: String) throws {
        guard ProcessInfo.processInfo.environment["CLIPBOARD_FIXTURE_RENDER"] == "1" else { return }
        // Let AppKit finish native control drawing before caching this view only.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        panel.contentView!.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let view = panel.contentView!
        // Native controls are layer-backed. Capture their retained layers too,
        // not just the dirty views redrawn by cacheDisplay after a search edit.
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.layer!.render(in: NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/clipboard-\(name).png"))
    }
    expect(labels().contains { $0.contains("Recording is paused") }, "empty paused panel explains explicit recording opt-in")
    try render("paused")
    history.setRecording(true)
    expect(labels().contains { $0.contains("No clipboard history yet") }, "recording empty state explains new copies")
    board.put("A pinned release note\n\twith readable spacing"); history.poll()
    let pinned = history.entries[0].id
    history.pin(pinned)
    board.put("Design review — an intentionally long line of synthetic text to check native truncation and a clean, readable preview without wrapping the whole clipboard into the list row."); history.poll()
    let textID = history.entries[0].id
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<160 { for y in 0..<100 {
        let pixel = bitmap.bitmapData! + y * bitmap.bytesPerRow + x * 4
        pixel[0] = x < 80 ? 40 : 65; pixel[1] = x < 80 ? 120 : 190; pixel[2] = 220; pixel[3] = 255
    } }
    board.put(nil, image: bitmap.representation(using: .png, properties: [:])!); history.poll()
    let imageID = history.entries[0].id
    expect(module.rows.map(\.id) == [pinned, imageID, textID], "panel presents pins once, before recency-ordered entries")
    expect(ClipboardPresentation.preview(module.rows[0]) == "A pinned release note with readable spacing", "preview normalizes newlines and tabs")
    expect(ClipboardPresentation.age(date.addingTimeInterval(-125), now: date) == "2m ago", "relative ages use compact readable units")
    let imageEntry = module.rows[1]
    let cache = ClipboardThumbnails()
    _ = cache.image(for: imageEntry)
    let deadline = Date().addingTimeInterval(3)
    while cache.inFlightCount > 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    let image = cache.image(for: imageEntry)
    _ = cache.image(for: imageEntry)
    expect(image != nil && max(image!.size.width, image!.size.height) <= 96 && cache.decodes == 1, "PNG thumbnails downsample to 96 pixels and cache repeat renders")
    let thumbnailPixels = NSBitmapImageRep(data: image!.tiffRepresentation!)!
    expect(thumbnailPixels.colorAt(x: 0, y: 0)!.alphaComponent > 0.9, "synthetic thumbnail retains its opaque image pixels")
    if ProcessInfo.processInfo.environment["CLIPBOARD_FIXTURE_RENDER"] == "1" {
        try thumbnailPixels.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/clipboard-thumbnail.png"))
    }
    let broken = ClipboardEntry(id: UUID(), created: date, source: "fixture", text: nil, image: Data([1, 2, 3]), pinned: false)
    _ = cache.image(for: broken); _ = cache.image(for: broken)
    expect(cache.decodes == 1, "invalid images use a cached icon fallback without decoding")
    cache.retain([]); _ = cache.image(for: imageEntry)
    expect(cache.decodes == 2, "removed entry releases its thumbnail cache")
    module.show() // Synthetic panel only, no system clipboard/archive dependencies.
    expect(!history.persistent && module.search.currentEditor() != nil, "opening synthetic history autofocuses search without persistence changes")
    try render("history")
    key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
    expect(module.rows[module.table.selectedRow].id == imageID, "Down from search changes visible selection without surrendering search focus")
    key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
    expect(module.rows[module.table.selectedRow].id == pinned, "Up from search moves to the pinned entry")
    panel.makeFirstResponder(module.table)
    key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
    expect(module.rows[module.table.selectedRow].id == imageID, "window-dispatched Down traverses the actual table responder")
    key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
    panel.makeFirstResponder(module.search)
    search("design")
    expect(module.rows.map(\.id) == [textID] && module.table.selectedRow == 0, "search selects its first matching entry")
    try render("search")
    search("unmatched fixture")
    expect(module.rows.isEmpty && module.table.selectedRow == -1 && !findButton("Copy").isEnabled && labels().contains { $0.contains("No matching entries") }, "no-results state disables copy and clears selection")
    try render("no-results")
    search("")
    module.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    let pinItem = module.table.menu!.items[1]
    expect(module.validateMenuItem(pinItem) && pinItem.title == "Pin", "context menu reflects selected entry pin state")
    _ = module.perform(pinItem.action)
    expect(module.rows[module.table.selectedRow].id == textID && module.validateMenuItem(pinItem) && pinItem.title == "Unpin", "pin reorder preserves identity and updates context action")
    let deleteItem = module.table.menu!.items[2]
    _ = module.perform(deleteItem.action)
    expect(module.table.selectedRow == -1 && !findButton("Copy").isEnabled, "deleting selected row cannot redirect the next Copy")
    history.setRecording(false)
    date = date.addingTimeInterval(8 * 86400); history.poll()
    expect(module.rows.map(\.id) == [pinned] && module.table.selectedRow == -1, "expiry preserves pins and does not revive stale selection")
    search("")
    var admitted = false
    module.acceptsActions = { admitted }
    let count = board.changeCount
    key(36, "\r")
    _ = module.perform(pinItem.action); _ = module.perform(deleteItem.action); module.clear()
    expect(board.changeCount == count && history.entries.count == 1 && history.entries[0].pinned && !module.validateMenuItem(pinItem), "copy, pin, delete, Clear and context menu respect closed host admission")
    admitted = true
    module.show()
    key(36, "\r")
    expect(board.changeCount == count + 1 && board.value?.hasPrefix("A pinned") == true && !panel.isVisible, "Return copies only to fake clipboard and dismisses history")
    module.show(); key(53, "\u{1b}")
    expect(!panel.isVisible && board.changeCount == count + 1, "Escape closes without copying")
    module.show()
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    panel.makeFirstResponder(module.table)
    panel.sendEvent(escape)
    expect(!panel.isVisible && board.changeCount == count + 1, "native table Escape event dismisses without writing")
    module.show(); panel.makeFirstResponder(module.table); key(36, "\r")
    expect(!panel.isVisible && board.changeCount == count + 2, "window-dispatched table Return copies only to fake clipboard and dismisses")

    module.show(); findButton("Clear history…").performClick(nil)
    expect(panel.attachedSheet != nil, "native Clear button opens confirmation before deleting history")
    panel.endSheet(panel.attachedSheet!, returnCode: .alertSecondButtonReturn); settle()
    expect(history.entries.count == 1, "Canceling native Clear confirmation preserves pinned history")
    findButton("Clear history…").performClick(nil)
    expect(panel.attachedSheet != nil, "Clear confirmation can be reopened after Cancel")
    admitted = false
    panel.endSheet(panel.attachedSheet!, returnCode: .alertFirstButtonReturn); settle()
    expect(history.entries.count == 1, "Clear completion rechecks admission after confirmation was opened")
    admitted = true; module.show()
    findButton("Clear history…").performClick(nil)
    expect(panel.attachedSheet != nil, "admitted Clear displays its native confirmation")
    panel.endSheet(panel.attachedSheet!, returnCode: .alertFirstButtonReturn); settle()
    expect(history.entries.isEmpty && board.changeCount == count + 2 && !history.recording && !history.persistent, "confirmed Clear removes pins without touching clipboard, recording or persistence policy")
}

// Exhaustive short sequences plus a recovery/enable suffix expose latent
// restore intents, not just the immediate state after a deletion attempt.
private func runClipboardStorageTransitionTests(date: Date) throws {
    let actions = ["enable", "load", "disable", "clear", "capture", "pin", "metadata", "blocked", "commit failure", "recover"]
    for seed in ["rollback", "startup", "active"] {
        for first in actions { for second in actions { for third in actions {
            let board = FakeClipboard()
            let archive = FailingClipboardArchive()
            let old = ClipboardEntry(id: UUID(), created: date, source: "fixture", text: "disk-only pinned work", image: nil, pinned: true)
            archive.entries = [old]
            let history = ClipboardHistory(board: board, archive: archive, now: { date }, source: { "fixture" })
            archive.commitThenThrow = seed != "active"
            do { try history.configurePersistence(true, ageDays: 7, load: seed != "rollback") } catch {}
            archive.commitThenThrow = true; archive.failClear = true
            var forbidden = Set<UUID>()
            var deletionRequested = false
            var valid = true
            let sequence = [first, second, third, "recover", "enable", "recover"]
            for (step, action) in sequence.enumerated() {
                let memoryBefore = history.entries
                do {
                    switch action {
                    case "enable", "load":
                        try history.configurePersistence(true, ageDays: 7, load: action == "load")
                    case "disable":
                        // Disable retains memory: only disk-only history is
                        // forbidden from resurfacing via obsolete restore work.
                        forbidden.formUnion(Set(archive.entries.map(\.id)).subtracting(history.entries.map(\.id)))
                        deletionRequested = true
                        try history.configurePersistence(false, ageDays: 7)
                    case "clear":
                        forbidden.formUnion(archive.entries.map(\.id))
                        forbidden.formUnion(history.entries.map(\.id))
                        deletionRequested = true
                        try history.clear()
                    case "capture":
                        history.setRecording(true)
                        board.put("post-deletion new work \(step)"); history.poll()
                    case "pin":
                        if let entry = history.entries.first { history.pin(entry.id) }
                    case "metadata": history.setExclusions(["unrelated"])
                    case "blocked":
                        archive.failing = true; archive.failClear = true
                        archive.commitThenThrow = false; archive.clearThenThrow = false
                    case "commit failure":
                        archive.failing = false; archive.failClear = false
                        archive.commitThenThrow = true; archive.clearThenThrow = true
                    case "recover":
                        archive.failing = false; archive.failClear = false
                        archive.commitThenThrow = false; archive.clearThenThrow = false
                        valid = history.flushPendingStorage() && valid
                    default: fatalError("Unknown transition")
                    }
                } catch {
                    if action == "disable" { valid = valid && history.storagePending && !history.persistent }
                    if action == "clear" { valid = valid && history.storagePending && history.entries.isEmpty }
                }
                if action == "disable" { valid = valid && history.entries == memoryBefore && !history.requestedPersistence }
                if action == "clear" { valid = valid && history.entries.isEmpty }
                valid = valid && history.entries.allSatisfy { !forbidden.contains($0.id) }
                if !history.storagePending {
                    valid = valid && archive.entries.allSatisfy { !forbidden.contains($0.id) }
                    if deletionRequested && !history.persistent { valid = valid && archive.entries.isEmpty }
                }
                valid = valid && history.entries.count <= 100 &&
                    history.entries.reduce(0, { $0 + ($1.image?.count ?? 0) }) <= ClipboardHistory.imageBudget
            }
            if !deletionRequested {
                valid = valid && history.entries.contains(where: { $0.id == old.id }) && archive.entries.contains(where: { $0.id == old.id })
            }
            expect(valid && !history.storagePending,
                   "storage intent sequence \(seed): \(first) → \(second) → \(third) preserves deletion and recovery invariants")
        } } }
    }
}

func runClipboardTests() throws {
    try runClipboardClearConfirmationTests()
    runClipboardPresentationTests()
    runClipboardThumbnailTests()
    try runClipboardPanelTests()
    let table = ClipboardTable()
    var copies = 0
    var closes = 0
    table.onCopy = { copies += 1 }; table.onClose = { closes += 1 }
    for key: UInt16 in [36, 76, 53] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: key)!
        table.keyDown(with: event)
    }
    expect(copies == 2 && closes == 1, "history table handles Return, keypad Enter, and Escape without posting input")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = ClipboardArchive(directory: directory)
    let board = FakeClipboard()
    var date = Date(timeIntervalSince1970: 1000000)
    var app: String? = "test.editor"
    let history = ClipboardHistory(board: board, archive: archive, now: { date }, source: { app })
    board.put("preexisting"); history.poll()
    expect(board.reads == 0 && history.entries.isEmpty, "clipboard starts paused without content reads")
    history.setRecording(true); history.poll()
    expect(history.entries.isEmpty, "resume never snapshots existing clipboard")
    board.put("one"); history.poll(); board.put("one"); history.poll()
    expect(history.entries.count == 1, "repeated clipboard text deduplicates")
    let first = history.entries[0].id
    var draft = ClipboardExclusionsDraft()
    draft.edited = "test.passwords"
    expect(draft.text(applied: "refreshed.saved.value") == "test.passwords", "history refresh cannot overwrite exclusion draft")
    var applied = ""
    draft.apply(current: "refreshed.saved.value") { applied = $0 }
    expect(applied == "test.passwords" && draft.edited == nil, "Apply submits the draft and returns to applied state")
    expect(history.copy(first), "history selection writes fake clipboard")
    let reads = board.reads; history.poll()
    expect(board.reads == reads, "history writes are not recaptured")
    board.put(String(repeating: "x", count: ClipboardHistory.textLimit + 1)); history.poll()
    expect(history.entries.count == 1, "oversize text rejected")
    board.markedPrivate = true; board.put("secret"); history.poll()
    expect(history.entries.count == 1, "marked clipboard content rejected")
    board.markedPrivate = false
    history.setExclusions(["test.passwords"]); app = "test.passwords"
    board.put("excluded"); history.poll(); app = nil
    board.put("unknown"); history.poll()
    expect(history.entries.count == 1, "excluded and unknown foreground apps skipped")
    app = "test.editor"; board.race = true; board.put("raced"); history.poll(); board.race = false
    expect(history.entries.count == 1, "clipboard changes during read discarded")
    history.setRecording(false); board.put("paused"); history.poll(); history.setRecording(true); history.poll()
    expect(history.entries.count == 1, "pause and resume do not capture paused content")
    for i in 0..<110 { board.put("item \(i)"); history.poll() }
    expect(history.entries.count == 100 && history.entries[0].text == "item 109", "history bounded to 100 most recent distinct entries")
    let selection = history.entries[10].id
    board.put("interleaved capture"); history.poll()
    let selectionIndex = ClipboardSelection.index(previous: selection, entries: history.entries, reset: false)
    expect(selectionIndex == 11, "capture preserves selected action target by identity")
    history.pin(selection)
    expect(ClipboardSelection.index(previous: selection, entries: history.entries, reset: false) == 11, "pin refresh preserves selected action target")
    history.delete(selection)
    expect(ClipboardSelection.index(previous: selection, entries: history.entries, reset: false) == nil, "removed target clears selection rather than redirecting actions")
    expect(ClipboardSelection.index(previous: nil, entries: history.entries, reset: false) == nil, "later history refresh leaves cleared selection empty")
    expect(!FileManager.default.fileExists(atPath: directory.path), "memory history creates no disk archive")
    history.pin(history.entries[0].id)
    try history.configurePersistence(true, ageDays: 1)
    date.addTimeInterval(86401)
    let restarted = ClipboardHistory(board: board, archive: archive, now: { date }, source: { app })
    try restarted.configurePersistence(true, ageDays: 1, load: true)
    expect(restarted.entries.count == 1 && restarted.entries[0].pinned, "restart expires old entries and retains pins")
    var stored = try archive.load()
    expect(stored.count == 1, "startup expiry removes disk content")
    restarted.setRecording(true)
    for i in 0..<10 { board.put(nil, image: Data(repeating: UInt8(i), count: ClipboardHistory.imageLimit)); restarted.poll() }
    expect(restarted.entries.compactMap(\.image).reduce(0, { $0 + $1.count }) == ClipboardHistory.imageBudget, "images obey separate total storage cap")
    board.put(nil, image: Data(count: ClipboardHistory.imageLimit + 1)); restarted.poll()
    expect(restarted.entries.count == 9, "oversize image rejected")
    let imageID = restarted.entries[0].id
    restarted.delete(imageID)
    stored = try archive.load()
    expect(stored.allSatisfy { $0.id != imageID }, "delete removes image bytes from disk archive")
    restarted.setExclusions(["test.editor"])
    stored = try archive.load()
    expect(restarted.entries.isEmpty && stored.isEmpty, "new exclusions purge persisted history")
    restarted.setExclusions([]); board.put("clear me"); restarted.poll()
    board.put(nil, image: Data([1, 2, 3])); restarted.poll()
    try restarted.clear()
    stored = try archive.load()
    expect(restarted.entries.isEmpty && stored.isEmpty, "Clear removes memory and disk including images")
    expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path), "Clear unlinks the entire image archive")
    board.put("expire during use"); restarted.poll()
    date.addTimeInterval(86401); restarted.poll()
    stored = try archive.load()
    expect(restarted.entries.isEmpty && stored.isEmpty, "idle polling expires memory and disk without new clipboard changes")
    board.put("disk off"); restarted.poll()
    try restarted.configurePersistence(false, ageDays: 7)
    stored = try archive.load()
    expect(stored.isEmpty, "disabling persistence deletes archive")
    restarted.stop()
    expect(!restarted.recording && restarted.entries.isEmpty, "module stop releases history and recording")

    let failing = FailingClipboardArchive()
    let recoverable = ClipboardHistory(board: board, archive: failing, now: { date }, source: { app })
    failing.failing = true
    do { try recoverable.configurePersistence(true, ageDays: 2); expect(false, "configuration must throw") }
    catch {}
    expect(!recoverable.persistent && recoverable.ageDays == 7, "failed enable rolls back persistence and retention")
    failing.failing = false
    try recoverable.configurePersistence(true, ageDays: 1)
    recoverable.setRecording(true); board.put("delete after failure"); recoverable.poll()
    failing.failing = true
    recoverable.delete(recoverable.entries[0].id)
    expect(recoverable.storagePending && !recoverable.flushPendingStorage(), "failed deletion retains retry state and blocks orderly unload")
    failing.failing = false; recoverable.poll()
    expect(!recoverable.storagePending && failing.entries.isEmpty, "idle polling retries deletion without another copy")
    board.put("clear after failure"); recoverable.poll(); failing.failing = true
    do { try recoverable.clear(); expect(false, "Clear failure must throw") } catch {}
    expect(recoverable.storagePending, "failed Clear remains visibly pending")
    failing.failing = false; recoverable.poll()
    expect(!recoverable.storagePending && failing.entries.isEmpty, "idle polling retries failed Clear")
    board.put("expiry after failure"); recoverable.poll(); failing.failing = true
    date.addTimeInterval(86401); recoverable.poll()
    expect(recoverable.storagePending && recoverable.entries.isEmpty, "failed expiry is pending without exposing expired entries")
    failing.failing = false; recoverable.poll()
    expect(failing.entries.isEmpty, "expiry retries remove stale disk entries")
    board.put("excluded after failure"); recoverable.poll(); failing.failing = true
    recoverable.setExclusions(["test.editor"])
    failing.failing = false; recoverable.poll()
    expect(failing.entries.isEmpty && !recoverable.storagePending, "exclusion purge retries without a new capture")

    let savedEntry = ClipboardEntry(id: UUID(), created: date, source: "fixture", text: "preserved startup", image: nil, pinned: true)
    let disabledArchive = FailingClipboardArchive()
    disabledArchive.entries = [savedEntry]
    let disabledHistory = ClipboardHistory(board: FakeClipboard(), archive: disabledArchive, now: { date }, source: { "fixture" })
    disabledArchive.commitThenThrow = true
    do { try disabledHistory.configurePersistence(true, ageDays: 2) } catch {}
    disabledArchive.failClear = true
    do { try disabledHistory.configurePersistence(false, ageDays: 2) } catch {}
    expect(disabledHistory.storagePending && disabledHistory.entries.isEmpty,
           "failed Disable after uncertain enable keeps disk deletion pending")
    disabledArchive.commitThenThrow = false; disabledArchive.failClear = false
    expect(disabledHistory.flushPendingStorage() && disabledArchive.entries.isEmpty && !disabledHistory.persistent,
           "recovered Disable deletes disk history before reporting clean")
    try disabledHistory.configurePersistence(true, ageDays: 2)
    expect(disabledHistory.entries.isEmpty && disabledArchive.entries.isEmpty && !disabledHistory.storagePending,
           "enable after reconciled Disable cannot resurrect superseded pinned archive rollback")
    try runClipboardStorageTransitionTests(date: date)
    let disabledDomain = "clipboard-disabled-intent.\(UUID())"
    let disabledDefaults = UserDefaults(suiteName: disabledDomain)!
    defer { disabledDefaults.removePersistentDomain(forName: disabledDomain) }
    let disabledBoard = FakeClipboard()
    let moduleArchive = FailingClipboardArchive()
    moduleArchive.entries = [savedEntry]
    let moduleHistory = ClipboardHistory(board: disabledBoard, archive: moduleArchive, now: { date }, source: { "fixture" })
    try moduleHistory.configurePersistence(true, ageDays: 7, load: true)
    moduleHistory.setRecording(true); disabledBoard.put("retained user memory"); moduleHistory.poll()
    let retainedMemory = moduleHistory.entries
    disabledDefaults.set(true, forKey: "clipboard.persistence")
    let disabledModule = ClipboardModule(defaults: disabledDefaults, history: moduleHistory)
    moduleArchive.failClear = true
    disabledModule.setPersistence(false)
    expect(!disabledModule.persistence && !disabledDefaults.bool(forKey: "clipboard.persistence") && moduleHistory.storagePending && moduleHistory.entries == retainedMemory,
           "failed native Disable preserves memory, revokes persistence and saves disabled startup intent")
    disabledBoard.put("new work while disabled"); moduleHistory.poll()
    let memoryAfterDisable = moduleHistory.entries
    moduleArchive.failClear = false
    expect(moduleHistory.flushPendingStorage() && moduleArchive.entries.isEmpty && moduleHistory.entries == memoryAfterDisable,
           "Disable reconciliation deletes disk without rewriting retained or newly captured memory")
    let reloaded = ClipboardHistory(board: FakeClipboard(), archive: moduleArchive, now: { date }, source: { "fixture" })
    try reloaded.configurePersistence(disabledDefaults.bool(forKey: "clipboard.persistence"), ageDays: 7, load: true)
    expect(!reloaded.persistent && reloaded.entries.isEmpty && moduleArchive.entries.isEmpty,
           "configuration reload cannot revive explicitly disabled disk persistence")
    try moduleHistory.configurePersistence(true, ageDays: 7)
    expect(moduleArchive.entries == memoryAfterDisable,
           "later explicit enable may persist intentionally retained memory after Disable completes")
    disabledModule.stop()
    for kind in ["text", "pinned text", "pinned image"] {
        for loadOnEnable in [false, true] {
            let clearBoard = FakeClipboard()
            let clearArchive = FailingClipboardArchive()
            let cleared = ClipboardHistory(board: clearBoard, archive: clearArchive, now: { date }, source: { "fixture" })
            cleared.setRecording(true)
            if kind == "pinned image" { clearBoard.put(nil, image: Data(repeating: 7, count: ClipboardHistory.imageLimit)) }
            else { clearBoard.put("discarded secret") }
            cleared.poll()
            if kind != "text" { cleared.pin(cleared.entries[0].id) }
            clearArchive.commitThenThrow = true
            do { try cleared.configurePersistence(true, ageDays: 2) } catch {}
            clearArchive.failClear = true
            do { try cleared.clear() } catch {}
            expect(cleared.entries.isEmpty && clearArchive.entries.count == 1 && cleared.storagePending,
                   "failed Clear after uncertain enable discards \(kind) from memory")
            clearArchive.commitThenThrow = false
            let initialLoads = clearArchive.loads
            let initialSaves = clearArchive.saves
            do {
                try cleared.configurePersistence(true, ageDays: 3, load: loadOnEnable)
                expect(false, "initial enable must throw while Clear still fails")
            } catch {}
            expect(!cleared.persistent && cleared.entries.isEmpty && cleared.storagePending &&
                   clearArchive.loads == initialLoads && clearArchive.saves == initialSaves && !cleared.flushPendingStorage(),
                   "failed initial deletion blocks enable and keeps discarded \(kind) absent")
            // No idle cleanup after storage recovers: enable must perform it.
            clearArchive.failClear = false
            try cleared.configurePersistence(true, ageDays: 2, load: loadOnEnable)
            expect(cleared.entries.isEmpty && clearArchive.entries.isEmpty && !cleared.storagePending && cleared.flushPendingStorage(),
                   "enable reconciles pending Clear before loading discarded \(kind), load=\(loadOnEnable)")

            clearBoard.put("discard again"); cleared.poll()
            clearArchive.failClear = true
            do { try cleared.clear() } catch {}
            let loadsBefore = clearArchive.loads
            let savesBefore = clearArchive.saves
            do {
                try cleared.configurePersistence(true, ageDays: 3, load: loadOnEnable)
                expect(false, "enable must throw while authoritative Clear still fails")
            } catch {}
            expect(cleared.entries.isEmpty && cleared.storagePending && cleared.ageDays == 2 &&
                   clearArchive.loads == loadsBefore && clearArchive.saves == savesBefore && !cleared.flushPendingStorage(),
                   "failed deletion blocks enable without loading or saving discarded history")
            cleared.setExclusions(["unrelated"])
            expect(cleared.storagePending && clearArchive.saves == savesBefore,
                   "persistent metadata mutation cannot supersede failed Clear")
            do { try cleared.configurePersistence(false, ageDays: 2) } catch {}
            expect(!cleared.flushPendingStorage() && cleared.storagePending && clearArchive.saves == savesBefore,
                   "failed disable cannot replace pending Clear with a save retry")
            clearArchive.failClear = false
            expect(cleared.flushPendingStorage() && clearArchive.entries.isEmpty,
                   "Clear remains authoritative through later mutation and storage recovery")
        }
    }
    let newWorkBoard = FakeClipboard()
    let newWorkArchive = FailingClipboardArchive()
    let newWork = ClipboardHistory(board: newWorkBoard, archive: newWorkArchive, now: { date }, source: { "fixture" })
    try newWork.configurePersistence(true, ageDays: 7)
    newWork.setRecording(true); newWorkBoard.put("discard old work"); newWork.poll()
    newWorkArchive.failClear = true
    do { try newWork.clear() } catch {}
    let savesBeforeNewWork = newWorkArchive.saves
    newWorkBoard.put(nil, image: Data(repeating: 8, count: ClipboardHistory.imageLimit)); newWork.poll()
    newWork.pin(newWork.entries[0].id)
    expect(newWork.storagePending && newWorkArchive.saves == savesBeforeNewWork && !newWork.flushPendingStorage(),
           "new bounded pinned image capture cannot bypass failed Clear")
    newWorkArchive.failClear = false
    expect(newWork.flushPendingStorage() && newWorkArchive.entries == newWork.entries &&
           newWorkArchive.entries.count == 1 && newWorkArchive.entries[0].text == nil && newWorkArchive.entries[0].pinned,
           "successful Clear reconciliation persists only newly captured image work")
    expect(newWorkArchive.entries[0].image?.count == ClipboardHistory.imageLimit,
           "Clear reconciliation retains the bounded image bytes without restoring old text")
    let uncertainArchive = FailingClipboardArchive()
    let uncertain = ClipboardHistory(board: board, archive: uncertainArchive, now: { date }, source: { app })
    uncertain.setRecording(true); board.put("uncertain disk secret"); uncertain.poll()
    let memoryBeforeEnable = uncertain.entries
    uncertainArchive.commitThenThrow = true; uncertainArchive.failClear = true
    do { try uncertain.configurePersistence(true, ageDays: 2); expect(false, "commit-then-throw enable must report failure") } catch {}
    expect(uncertainArchive.entries == memoryBeforeEnable && !uncertain.persistent && uncertain.ageDays == 7 && uncertain.entries == memoryBeforeEnable,
           "commit-then-throw fixture commits disk content but restores configuration and memory")
    expect(uncertain.storagePending && !uncertain.flushPendingStorage(),
           "failed initial enable tracks uncertain disk commit and blocks unload while cleanup fails")
    let uncertainDomain = "clipboard-uncertain-tests.\(UUID())"
    let uncertainDefaults = UserDefaults(suiteName: uncertainDomain)!
    defer { uncertainDefaults.removePersistentDomain(forName: uncertainDomain) }
    let uncertainModule = ClipboardModule(defaults: uncertainDefaults, history: uncertain)
    let uncertainMouse = MouseLifecycle(settings: ModuleSettings(defaults: uncertainDefaults), makeModule: {
        MouseModule(backend: FakeMouseBackend(), recovery: FakeMouseRecovery())
    })
    let uncertainModel = DashboardModel()
    let uncertainHost = AppDelegate(clipboard: uncertainModule, mouseLifecycle: uncertainMouse, model: uncertainModel)
    expect(uncertainHost.applicationShouldTerminate(NSApplication.shared) == .terminateCancel,
           "actual host quit vetoes failed initial-enable archive cleanup")
    uncertainModel.errorMessage = nil
    uncertainModel.onModuleChanged(.clipboard, false)
    expect(uncertainModel.errorMessage?.contains("cleanup is pending") == true && uncertain.entries == memoryBeforeEnable,
           "actual module unload action refuses uncertain archive cleanup without dropping memory work")
    uncertainArchive.failClear = false
    expect(uncertain.flushPendingStorage() && uncertainArchive.entries.isEmpty && uncertain.entries == memoryBeforeEnable && !uncertain.persistent,
           "initial enable rollback clears newly committed disk history without deleting memory work")
    expect(uncertainHost.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
           "actual host quit approves only after uncertain initial archive cleanup completes")
    uncertainArchive.entries = [savedEntry]
    do { try uncertain.configurePersistence(true, ageDays: 2) } catch {}
    expect(uncertain.storagePending && !uncertain.flushPendingStorage(),
           "uncertain overwrite of an existing archive blocks unload until restoration succeeds")
    uncertainArchive.commitThenThrow = false
    expect(uncertain.flushPendingStorage() && uncertainArchive.entries == [savedEntry] && uncertain.entries == memoryBeforeEnable,
           "failed enable restores preexisting disk work rather than silently deleting it")
    let committedStartup = ClipboardHistory(board: board, archive: uncertainArchive, now: { date }, source: { app })
    uncertainArchive.commitThenThrow = true
    do { try committedStartup.configurePersistence(true, ageDays: 1, load: true) } catch {}
    committedStartup.setRecording(true)
    expect(committedStartup.storagePending && !committedStartup.recording && !committedStartup.flushPendingStorage(),
           "commit-then-throw startup preserves requested recovery and blocks unload")
    uncertainArchive.commitThenThrow = false
    expect(committedStartup.flushPendingStorage() && committedStartup.entries == [savedEntry] && committedStartup.persistent,
           "startup reconciliation retains saved user work and completes requested persistence")
    uncertainArchive.commitThenThrow = true
    do { try committedStartup.configurePersistence(true, ageDays: 3) } catch {}
    expect(committedStartup.ageDays == 1 && committedStartup.storagePending && !committedStartup.flushPendingStorage(),
           "commit-then-throw retention change restores configuration and tracks reconciliation")
    uncertainArchive.commitThenThrow = false
    expect(committedStartup.flushPendingStorage() && uncertainArchive.entries == [savedEntry],
           "retention rollback preserves existing archive content")
    uncertainArchive.commitThenThrow = true
    do { try uncertain.configurePersistence(true, ageDays: 2) } catch {}
    uncertainArchive.failClear = true
    do { try uncertain.clear() } catch {}
    expect(uncertain.storagePending && !uncertain.flushPendingStorage() && uncertain.entries.isEmpty,
           "explicit Clear supersedes archive rollback but blocks unload until deletion succeeds")
    uncertainArchive.failClear = false
    expect(uncertain.flushPendingStorage() && uncertainArchive.entries.isEmpty,
           "explicit Clear removes uncertain disk commits instead of restoring discarded work")
    uncertainModule.stop()
    failing.entries = [savedEntry]; failing.failing = true
    let startup = ClipboardHistory(board: board, archive: failing, now: { date }, source: { app })
    do { try startup.configurePersistence(true, ageDays: 1, load: true); expect(false, "startup save must throw") } catch {}
    startup.setRecording(true)
    expect(startup.storagePending && !startup.recording, "failed startup remains pending and prevents recording before recovery")
    do { try startup.configurePersistence(true, ageDays: 1); expect(false, "enable must not bypass failed startup") } catch {}
    expect(failing.entries == [savedEntry], "enable cannot overwrite an unrecovered archive")
    failing.failing = false
    try startup.configurePersistence(true, ageDays: 1)
    expect(startup.entries == [savedEntry] && failing.entries == [savedEntry], "enable recovers startup archive before saving")
    failing.failing = true
    let idleStartup = ClipboardHistory(board: board, archive: failing, now: { date }, source: { app })
    do { try idleStartup.configurePersistence(true, ageDays: 1, load: true) } catch {}
    failing.failing = false; idleStartup.poll()
    expect(idleStartup.entries == [savedEntry] && !idleStartup.storagePending, "idle poll retries startup load and cleanup")
    failing.failLoad = true
    let failedLoad = ClipboardHistory(board: board, archive: failing, now: { date }, source: { app })
    do { try failedLoad.configurePersistence(true, ageDays: 1, load: true) } catch {}
    expect(failedLoad.requestedPersistence && !failedLoad.persistent, "failed load preserves requested disk persistence")
    do { try failedLoad.configurePersistence(failedLoad.requestedPersistence, ageDays: 2) } catch {}
    expect(failing.entries == [savedEntry] && failedLoad.storagePending, "retention change cannot discard an archive after load failure")
    let domain = "clipboard-tests.\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let module = ClipboardModule(defaults: defaults, history: failedLoad)
    expect(module.persistence, "native persistence switch shows requested On during failed startup")
    module.setRetentionDays(3)
    expect(failing.entries == [savedEntry] && failedLoad.storagePending, "native module retention action preserves archive during failed startup")
    failing.failLoad = false; failedLoad.poll()
    expect(failedLoad.entries == [savedEntry], "actual load failure recovers on idle retry")
    let mouseBackend = FakeMouseBackend()
    let mouseLifecycle = MouseLifecycle(settings: ModuleSettings(defaults: defaults), makeModule: {
        MouseModule(backend: mouseBackend, recovery: FakeMouseRecovery())
    })
    mouseLifecycle.reconcile()
    let finalCheckSpaces = SpacesModule(defaults: defaults, engine: GestureSwitchEngine(spaceInfo: { nil }, postPhase: { _, _, _ in true }))
    var finalCheckReply: Bool?
    let host = AppDelegate(spaces: finalCheckSpaces, clipboard: module, mouseLifecycle: mouseLifecycle,
                           terminationReply: { _, approved in finalCheckReply = approved })
    func awaitFinalCheck() -> Bool? {
        let deadline = Date().addingTimeInterval(2)
        while finalCheckReply == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return finalCheckReply
    }
    failedLoad.setRecording(true)
    expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateLater && !failedLoad.recording,
           "host quit preparation quiesces clipboard recording")
    failing.failing = true; failedLoad.delete(savedEntry.id)
    expect(awaitFinalCheck() == false, "host async quit completion rechecks cleanup and refuses pending deletion")
    failing.failing = false
    // Retry through the full host seam, then simulate a non-dashboard Mouse
    // mutation after admission has closed but before the final asynchronous check.
    finalCheckReply = nil
    expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateLater && failing.entries.isEmpty,
           "host quit retries only after late clipboard cleanup succeeds")
    mouseLifecycle.apply(acceleration: false, speed: 2)
    mouseBackend.failRestore = true
    expect(awaitFinalCheck() == false && mouseLifecycle.recoveryRequired,
            "final host quit rechecks late Mouse Apply and vetoes failed restoration even with clean Clipboard")
    mouseBackend.failRestore = false
    finalCheckReply = nil
    expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateLater && awaitFinalCheck() == true && !mouseLifecycle.recoveryRequired && mouseBackend.value.speed == .number(1.25),
            "final host quit retries late Mouse cleanup before approving termination")
    module.stop(); finalCheckSpaces.stop()

    let switchArchive = FailingClipboardArchive()
    switchArchive.entries = [savedEntry]; switchArchive.failLoad = true
    let switchHistory = ClipboardHistory(board: board, archive: switchArchive, now: { date }, source: { app })
    do { try switchHistory.configurePersistence(true, ageDays: 1, load: true) } catch {}
    let switchModule = ClipboardModule(defaults: defaults, history: switchHistory)
    defaults.set(true, forKey: "clipboard.persistence")
    switchModule.setPersistence(!switchModule.persistence)
    expect(!switchModule.persistence && !defaults.bool(forKey: "clipboard.persistence") && switchArchive.entries.isEmpty && !switchHistory.storagePending,
           "switch Off after failed startup explicitly deletes archive and saves disabled preference")
    switchModule.stop()

    failing.entries = [savedEntry]
    let quitHistory = ClipboardHistory(board: board, archive: failing, now: { date }, source: { app })
    try quitHistory.configurePersistence(true, ageDays: 1, load: true)
    let quitModule = ClipboardModule(defaults: defaults, history: quitHistory)
    let quitPhases = RecordingPhases()
    let quitEngine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: quitPhases.post)
    defaults.set(TransitionSpeed.smooth.rawValue, forKey: "spaces.speed")
    let quitSpaces = SpacesModule(defaults: defaults, engine: quitEngine)
    defaults.set(true, forKey: "spaces.enabled")
    var spaceNotifications = 0
    quitSpaces.onChange = { spaceNotifications += 1 }
    var quitReply: Bool?
    let quitModel = DashboardModel()
    let quitHost = AppDelegate(spaces: quitSpaces, clipboard: quitModule, mouseLifecycle: mouseLifecycle, model: quitModel, preferences: defaults, terminationReply: { _, approved in quitReply = approved })
    mouseLifecycle.apply(acceleration: false, speed: 2)
    mouseBackend.failRestore = true
    quitHistory.setRecording(true)
    expect(quitHost.applicationShouldTerminate(NSApplication.shared) == .terminateCancel && quitHistory.recording && !quitSpaces.isDraining,
           "mouse restoration veto leaves Clipboard monitoring and Spaces lifecycle untouched")
    mouseBackend.failRestore = false
    try quitEngine.switchSpace(.right)
    expect(quitPhases.began.wait(timeout: .now() + 1) == .success, "host quit fixture has an in-flight fake gesture")
    expect(quitHost.applicationShouldTerminate(NSApplication.shared) == .terminateLater && quitSpaces.isDraining,
           "actual host quit path waits for reversible gesture drain")
    expect(!mouseLifecycle.recoveryRequired && mouseBackend.value.speed == .number(1.25),
            "combined quit restores Mouse before quiescing Clipboard and draining Spaces")
    let enabledBeforeQuit = quitModel.enabledModules
    quitModel.onAnimationsChanged(true)
    quitModel.onModuleChanged(.clipboard, false)
    quitModel.onApplyMouse()
    quitModel.onClipboardRecording(true)
    let widgetBeforeQuit = quitModel.widgetLayout
    let lateWidgets = WidgetLayout(entries: [WidgetEntry(.clipboard)])
    quitModel.settingsWidgetEditor.begin(lateWidgets)
    let quitDoneAccepted = quitModel.settingsWidgetEditor.done(save: quitModel.onSaveWidgets)
    quitModel.onOpenSettings(.clipboard)
    quitModel.onRunSetup()
    quitModel.onSkipSetup()
    var blockedSetup: [String] = []
    quitModel.onFinishSetup(SetupDraft(current: quitModel, defaults: defaults)) { blockedSetup = $0 }
    expect(!quitDoneAccepted && quitModel.settingsWidgetEditor.draft != nil && quitModel.widgetLayout == widgetBeforeQuit && blockedSetup.contains { $0.contains("shutting down") },
           "actual widget Done and wizard Finish callbacks reject mutation during asynchronous quit")
    expect(quitModel.settingsGroup == .general, "actual Settings, setup-open, and Skip callbacks are inert during asynchronous quit")
    expect(!quitModel.animationsBusy && quitModel.enabledModules == enabledBeforeQuit && !quitHistory.recording && !mouseLifecycle.recoveryRequired,
           "real host actions reject new animation, module, Mouse and recording work during blocked quit drain")
    failing.failing = true; quitHistory.delete(savedEntry.id)
    quitPhases.release.signal()
    let quitDeadline = Date().addingTimeInterval(2)
    while quitReply == nil && Date() < quitDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(quitReply == false && quitSpaces.observesSpaceChanges && quitSpaces.onChange != nil && spaceNotifications > 0,
           "late clipboard failure vetoes actual host quit without unloading Spaces observer or callback")
    expect(quitSpaces.needsStartupRestore && quitSpaces.savedEnabled, "canceled quit requests restoration of saved gesture choice")
    expect(!mouseLifecycle.recoveryRequired && !quitHistory.recording,
            "late Clipboard veto keeps restored Mouse idle and recording safely paused")
    quitModel.onClipboardRecording(true)
    expect(quitHistory.recording, "canceled quit reopens the host mutation barrier")
    let reopenedDoneAccepted = quitModel.settingsWidgetEditor.done(save: quitModel.onSaveWidgets)
    expect(reopenedDoneAccepted && quitModel.settingsWidgetEditor.draft == nil && quitModel.widgetLayout == lateWidgets && quitHistory.recording,
           "canceled quit reopens widget persistence without stopping a recording session")
    failing.failing = false; quitHistory.poll()
    quitReply = nil
    expect(quitHost.applicationShouldTerminate(NSApplication.shared) == .terminateLater,
           "retry quit drains Spaces again after canceled quit")
    quitModel.onRestoreAnimations()
    quitModel.onSpacesChanged(true)
    quitModel.onClipboardPersistence(false)
    let retryDeadline = Date().addingTimeInterval(2)
    while quitReply == nil && Date() < retryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(quitReply == true && !quitModel.animationsBusy && quitHistory.persistent,
           "final approval has no late animation transaction and retains the barrier through shutdown")
    quitModel.onClipboardRecording(true)
    expect(!quitHistory.recording, "approved quit keeps rejecting host mutations until shutdown")
    quitModule.stop(); quitSpaces.stop()

    var worstCase: [ClipboardEntry] = (0..<8).map { index in
        ClipboardEntry(id: UUID(), created: date, source: "fixture", text: nil,
                       image: Data(repeating: UInt8(index), count: ClipboardHistory.imageLimit), pinned: true)
    }
    worstCase += (0..<92).map { index in
        ClipboardEntry(id: UUID(), created: date, source: "fixture",
                       text: String(repeating: "\u{0}", count: 65520) + String(index), image: nil, pinned: true)
    }
    try archive.save(worstCase)
    let encodedSize = try directory.appendingPathComponent("history.json").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    expect(encodedSize > 64 * 1024 * 1024, "worst-case valid history exercises encoded archive expansion")
    let expandedRestart = ClipboardHistory(board: board, archive: archive, now: { date }, source: { app })
    try expandedRestart.configurePersistence(true, ageDays: 1, load: true)
    expect(expandedRestart.entries.count == 100, "worst-case valid text and image archive survives restart")
    try expandedRestart.clear()
}

private func runClipboardClearConfirmationTests() throws {
    let suite = "fix-mac-os.clear-confirmation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let board = FakeClipboard(), archive = FailingClipboardArchive()
    let history = ClipboardHistory(board: board, archive: archive, source: { "fixture" })
    let module = ClipboardModule(defaults: defaults, history: history)
    let model = DashboardModel(), admission = HostTransactions()
    let host = AppDelegate(clipboard: module, model: model, preferences: defaults, transactions: admission)
    history.setRecording(true)
    board.put("Pinned fixture"); history.poll(); history.pin(history.entries[0].id)
    board.put("Unpinned fixture"); history.poll()
    try history.configurePersistence(true, ageDays: 7)
    let entries = history.entries, saved = archive.entries, clipboard = board.value, reads = board.reads
    let saves = archive.saves, clears = archive.clears
    var response: ((Bool) -> Void)?
    var prompts = 0, changes = 0, errors = 0
    module.confirmHistoryClear = { _, completion in prompts += 1; response = completion }
    module.onChange = { changes += 1 }; module.onError = { _ in errors += 1 }
    model.onClipboardClear()
    expect(prompts == 1 && history.entries == entries && archive.entries == saved, "Settings Clear asks before changing memory, pins or fake disk")
    response?(false)
    expect(history.entries == entries && archive.entries == saved && archive.saves == saves && archive.clears == clears && changes == 0 && errors == 0 && board.value == clipboard && board.reads == reads,
           "Settings Clear Cancel has zero history, pin, disk, clipboard or publication effects")
    let panel = module.makePanel()
    defer { panel.orderOut(nil) }
    let clearButton = panel.contentView!.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Clear history…" }!
    clearButton.performClick(nil)
    expect(prompts == 2, "native history Clear uses the same confirmation policy as Settings")
    response?(false)
    expect(history.entries == entries && archive.entries == saved && archive.clears == clears && changes == 0, "native history Clear Cancel also preserves pins and fake disk")
    model.onClipboardClear(); response?(true)
    expect(history.entries.isEmpty && archive.entries.isEmpty && changes > 0 && board.value == clipboard && board.reads == reads,
           "Settings Clear confirmation removes history including pins and fake disk without touching clipboard")
    board.put("Retained pin"); history.poll(); history.pin(history.entries[0].id)
    let retained = history.entries, retainedDisk = archive.entries
    model.onClipboardClear()
    _ = admission.requestQuit(.init(isBusy: { false }, prepareMouse: { true }, quiesce: {}, prepareClipboard: { true }, needsDisplayRecovery: { false }, restoreDisplays: { _ in }, suspendSpaces: nil, resumeClipboard: {}, restoreSpacesChoice: {}, didReopen: {}, didVeto: { _ in }), reply: { _ in })
    let before = changes
    response?(true)
    expect(!admission.acceptsActions && history.entries == retained && archive.entries == retainedDisk && changes == before,
           "Settings Clear rechecks HostTransactions admission after confirmation and preserves memory, pins and fake disk")
    let beforePrompts = prompts
    model.onClipboardClear(); module.clear()
    expect(prompts == beforePrompts && history.entries == retained && archive.entries == retainedDisk, "closed admission blocks Settings and native Clear before prompting")
    withExtendedLifetime(host) {}
}
