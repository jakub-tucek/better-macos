import ClipboardPolicy
import Foundation
import Testing

private final class Board: ClipboardAccess {
    var changeCount = 0
    var markedPrivate = false
    var value: String?
    var bytes: Data?
    var race = false
    var reads = 0
    func text() -> String? { reads += 1; if race { changeCount += 1 }; return value }
    func image() -> Data? { bytes }
    func write(_ entry: ClipboardEntry) -> Bool { put(entry.text, image: entry.image); return true }
    func put(_ text: String?, image: Data? = nil) { value = text; bytes = image; changeCount += 1 }
}

private final class Storage: ClipboardPersistence {
    var entries: [ClipboardEntry] = []
    var failLoad = false
    var failClear = false
    var commitThenThrow = false
    func load() throws -> [ClipboardEntry] {
        if failLoad { throw CocoaError(.fileReadNoPermission) }
        return entries
    }
    func save(_ entries: [ClipboardEntry]) throws {
        self.entries = entries
        if commitThenThrow { throw CocoaError(.fileWriteNoPermission) }
    }
    func clear() throws {
        if failClear { throw CocoaError(.fileWriteNoPermission) }
        entries = []
    }
}

private final class Fixture {
    let board = Board()
    let storage = Storage()
    var date = Date(timeIntervalSince1970: 1_000_000)
    var app: String? = "fixture.editor"
    lazy var history = ClipboardHistory(board: board, archive: storage, now: { [unowned self] in self.date }, source: { [unowned self] in self.app })
    func capture(_ text: String?, image: Data? = nil) { board.put(text, image: image); history.poll() }
}

@Suite("Clipboard capture and retention")
struct ClipboardPolicyTests {
    @Test("Startup and resume never capture the existing clipboard")
    func startupAndResume() {
        let f = Fixture()
        _ = f.history
        f.capture("paused")
        #expect(f.board.reads == 0)
        f.history.setRecording(true)
        f.history.poll()
        #expect(f.history.entries.isEmpty)
        f.capture("new")
        let id = f.history.entries[0].id
        #expect(f.history.copy(id))
        let reads = f.board.reads
        f.history.poll()
        #expect(f.board.reads == reads)
    }

    @Test("Private, excluded, unknown and raced captures are rejected")
    func privacy() {
        let f = Fixture()
        f.history.setRecording(true)
        f.board.markedPrivate = true; f.capture("private")
        f.board.markedPrivate = false
        f.history.setExclusions(["fixture.editor"]); f.capture("excluded")
        f.history.setExclusions([]); f.app = nil; f.capture("unknown")
        f.app = "fixture.editor"; f.board.race = true; f.capture("raced")
        #expect(f.history.entries.isEmpty)
        f.board.race = false; f.capture("allowed")
        #expect(f.history.entries.map(\.text) == ["allowed"])
    }

    @Test("Deduplication retains identity and pin; retention preserves pins")
    func identityAndRetention() {
        let f = Fixture()
        f.history.setRecording(true); f.capture("pinned")
        let id = f.history.entries[0].id
        f.history.pin(id)
        f.capture("other"); f.capture("pinned")
        #expect(f.history.entries.count == 2)
        #expect(f.history.entries[0].id == id)
        #expect(f.history.entries[0].pinned)
        f.date.addTimeInterval(8 * 86400); f.history.poll()
        #expect(f.history.entries.map(\.id) == [id])
        #expect(ClipboardSelection.index(previous: id, entries: f.history.entries, reset: false) == 0)
    }

    @Test("Text, entry and image budgets stay bounded")
    func limits() {
        let f = Fixture()
        f.history.setRecording(true)
        f.capture(String(repeating: "x", count: ClipboardHistory.textLimit + 1))
        #expect(f.history.entries.isEmpty)
        for index in 0..<110 { f.capture("entry \(index)") }
        #expect(f.history.entries.count == 100)
        for index in 0..<10 {
            f.capture(nil, image: Data(repeating: UInt8(index), count: ClipboardHistory.imageLimit))
        }
        #expect(f.history.entries.reduce(0) { $0 + ($1.image?.count ?? 0) } == ClipboardHistory.imageBudget)
        let ids = f.history.entries.map(\.id)
        f.capture(nil, image: Data(count: ClipboardHistory.imageLimit + 1))
        #expect(f.history.entries.map(\.id) == ids)
    }
}

@Suite("Clipboard storage recovery")
struct ClipboardStorageTests {
    @Test("A committed failed enable rolls back the old disk archive")
    func failedEnable() throws {
        let f = Fixture()
        let old = ClipboardEntry(id: UUID(), created: f.date, source: "fixture.editor", text: "old", image: nil, pinned: true)
        f.storage.entries = [old]
        f.history.setRecording(true); f.capture("new memory")
        f.storage.commitThenThrow = true
        #expect(throws: (any Error).self) { try f.history.configurePersistence(true, ageDays: 2) }
        #expect(!f.history.persistent)
        #expect(f.history.ageDays == 7)
        #expect(f.history.storagePending)
        #expect(f.storage.entries.count == 2)
        f.storage.commitThenThrow = false
        #expect(f.history.flushPendingStorage())
        #expect(f.storage.entries == [old])
    }

    @Test("Failed startup loading preserves disk ownership until recovery")
    func failedStartupLoad() throws {
        let f = Fixture()
        let old = ClipboardEntry(id: UUID(), created: f.date, source: "fixture.editor", text: "disk", image: nil, pinned: false)
        f.storage.entries = [old]; f.storage.failLoad = true
        #expect(throws: (any Error).self) { try f.history.configurePersistence(true, ageDays: 7, load: true) }
        #expect(f.history.storagePending)
        f.history.setRecording(true); f.capture("must not replace disk")
        #expect(f.history.entries.isEmpty)
        #expect(f.storage.entries == [old])
        f.storage.failLoad = false
        #expect(f.history.flushPendingStorage())
        #expect(f.history.entries == [old])
    }

    @Test("Clear supersedes pending rollback and startup recovery", arguments: [false, true])
    func clearIsAuthoritative(startup: Bool) throws {
        let f = Fixture()
        f.storage.entries = [ClipboardEntry(id: UUID(), created: f.date, source: "fixture.editor", text: "discarded", image: nil, pinned: true)]
        f.storage.commitThenThrow = true
        #expect(throws: (any Error).self) { try f.history.configurePersistence(true, ageDays: 7, load: startup) }
        f.storage.failClear = true
        #expect(throws: (any Error).self) { try f.history.clear() }
        f.storage.commitThenThrow = false; f.storage.failClear = false
        #expect(f.history.flushPendingStorage())
        try f.history.configurePersistence(true, ageDays: 7)
        #expect(f.history.entries.isEmpty)
        #expect(f.storage.entries.isEmpty)
    }

    @Test("Disable retries deletion without writing retained memory back")
    func disableDeletion() throws {
        let f = Fixture()
        f.history.setRecording(true); f.capture("memory")
        try f.history.configurePersistence(true, ageDays: 7)
        f.storage.failClear = true
        #expect(throws: (any Error).self) { try f.history.configurePersistence(false, ageDays: 7) }
        #expect(!f.history.persistent)
        #expect(f.history.entries.count == 1)
        f.storage.failClear = false
        #expect(f.history.flushPendingStorage())
        #expect(f.storage.entries.isEmpty)
        f.capture("more memory")
        #expect(f.storage.entries.isEmpty)
    }
}
