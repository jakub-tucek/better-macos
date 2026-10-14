import AppKit

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
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        self.entries = entries
    }
    func clear() throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        entries = []
    }
}

func runClipboardTests() throws {
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
