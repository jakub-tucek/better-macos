import Foundation

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

func runClipboardTests() throws {
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
    try restarted.clear()
    stored = try archive.load()
    expect(restarted.entries.isEmpty && stored.isEmpty, "Clear removes memory and disk including images")
    board.put("disk off"); restarted.poll()
    try restarted.configurePersistence(false, ageDays: 7)
    stored = try archive.load()
    expect(stored.isEmpty, "disabling persistence deletes archive")
    restarted.stop()
    expect(!restarted.recording && restarted.entries.isEmpty, "module stop releases history and recording")
}
