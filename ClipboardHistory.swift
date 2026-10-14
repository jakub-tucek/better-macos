import Foundation

struct ClipboardExclusionsDraft {
    var edited: String?
    func text(applied: String) -> String { edited ?? applied }
    mutating func apply(current: String, save: (String) -> Void) {
        save(text(applied: current)); edited = nil
    }
}

enum ClipboardSelection {
    static func index(previous: UUID?, entries: [ClipboardEntry], reset: Bool) -> Int? {
        if reset { return entries.isEmpty ? nil : 0 }
        guard let previous else { return nil }
        return entries.firstIndex { $0.id == previous }
    }
}

struct ClipboardEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let created: Date
    let source: String
    let text: String?
    let image: Data?
    var pinned: Bool
    var label: String { text ?? "Image (\((image?.count ?? 0) / 1024) KB)" }
}

protocol ClipboardAccess: AnyObject {
    var changeCount: Int { get }
    var markedPrivate: Bool { get }
    func text() -> String?
    func image() -> Data?
    func write(_ entry: ClipboardEntry) -> Bool
}

protocol ClipboardPersistence {
    // Mutating operations may commit and then throw. Callers must reconcile
    // uncertain results before considering disk ownership/cleanup complete.
    func load() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
    func clear() throws
}

/// A single bounded archive owns image bytes too: delete/expiry/Clear cannot orphan images.
struct ClipboardArchive: ClipboardPersistence {
    // Raw caps can expand to ~81 MiB with base64 and worst-case JSON text escaping.
    static let encodedLimit = 96 * 1024 * 1024
    enum ArchiveError: Error { case oversized }
    let directory: URL
    private var file: URL { directory.appendingPathComponent("history.json") }
    func load() throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.encodedLimit else { throw ArchiveError.oversized }
        return try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: file))
    }
    func save(_ entries: [ClipboardEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(entries)
        guard data.count <= Self.encodedLimit else { throw ArchiveError.oversized }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

final class ClipboardHistory {
    static let textLimit = 64 * 1024
    static let imageLimit = 4 * 1024 * 1024
    static let imageBudget = 32 * 1024 * 1024
    private let board: ClipboardAccess
    private let archive: ClipboardPersistence
    private let now: () -> Date
    private let source: () -> String?
    private var lastChange: Int
    private(set) var entries: [ClipboardEntry] = []
    private(set) var recording = false
    private(set) var persistent = false
    private(set) var ageDays = 7
    private(set) var exclusions: Set<String> = []
    // Exactly one disk intent can be pending. Deliberate deletion supersedes
    // recovery/rollback, so a completed delete cannot leave hidden restore work.
    private enum StorageIntent {
        case idle
        case save
        case rollback([ClipboardEntry])
        case startup(days: Int)
        case delete
    }
    private var storageIntent: StorageIntent = .idle
    var storagePending: Bool {
        if case .idle = storageIntent { return false }
        return true
    }
    private var startupDays: Int? {
        if case .startup(let days) = storageIntent { return days }
        return nil
    }
    var requestedPersistence: Bool { startupDays != nil || persistent }
    var onChange: () -> Void = {}
    var onError: () -> Void = {}

    init(board: ClipboardAccess, archive: ClipboardPersistence, now: @escaping () -> Date = Date.init,
         source: @escaping () -> String?) {
        self.board = board; self.archive = archive; self.now = now; self.source = source
        lastChange = board.changeCount // Never capture the clipboard present at startup/resume.
    }
    func configurePersistence(_ enabled: Bool, ageDays: Int, load: Bool = false) throws {
        if !enabled {
            // Disable preserves memory but revokes every previous disk restore
            // intent before attempting I/O, even if deletion commits then throws.
            persistent = false
            storageIntent = .delete
            defer { onChange() }
            try finishArchiveDeletion()
            self.ageDays = min(365, max(1, ageDays))
            return
        }
        // Clear is authoritative over every recovery/merge path. Never read
        // an archive containing discarded history until its deletion succeeds.
        if case .delete = storageIntent {
            try finishArchiveDeletion()
        }
        // Never replace an archive that startup has not successfully loaded and pruned.
        // An explicit disable/Clear may discard it; enabling must recover it first.
        if !load, let days = startupDays {
            try configurePersistence(true, ageDays: days, load: true)
        }
        if case .rollback = storageIntent {
            try reconcileStorage()
        }
        // Before first enable, remember disk work we don't yet own. If load
        // fails, do not write at all. A failed save must not silently delete an
        // older archive when restoring the disabled configuration.
        let originalArchive = !persistent && !load ? try archive.load() : nil
        let previousDays = self.ageDays
        let previousEntries = entries
        self.ageDays = min(365, max(1, ageDays))
        do {
            if load { entries = try archive.load() }
            else if let originalArchive { entries += originalArchive }
            prune()
            try archive.save(entries)
        } catch {
            self.ageDays = previousDays; entries = previousEntries
            if load {
                storageIntent = .startup(days: ageDays)
            } else if let originalArchive {
                storageIntent = .rollback(originalArchive)
            } else {
                // Retention/configuration saves restore the old memory state.
                storageIntent = .save
            }
            onChange()
            throw error
        }
        persistent = true
        storageIntent = .idle
        onChange()
    }
    func setExclusions(_ values: Set<String>) {
        exclusions = values
        entries.removeAll { exclusions.contains($0.source) }
        changed()
    }
    func setRecording(_ value: Bool) {
        lastChange = board.changeCount
        recording = value && startupDays == nil
        onChange()
    }
    func poll() {
        if storagePending { retryStorage() }
        let old = entries
        prune()
        if old != entries { changed() }
        let count = board.changeCount
        guard count != lastChange else { return }
        lastChange = count
        guard recording, let app = source(), !exclusions.contains(app), !board.markedPrivate else { return }
        let text = board.text()
        let image = text == nil ? board.image() : nil
        guard board.changeCount == count, !board.markedPrivate else { return }
        if let text { guard !text.isEmpty, text.utf8.count <= Self.textLimit else { return } }
        else { guard let image, !image.isEmpty, image.count <= Self.imageLimit else { return } }
        let existing = entries.first { $0.text == text && $0.image == image }
        entries.removeAll { $0.text == text && $0.image == image }
        entries.insert(ClipboardEntry(id: existing?.id ?? UUID(), created: now(), source: app,
                                      text: text, image: image, pinned: existing?.pinned ?? false), at: 0)
        prune(); changed()
    }
    func copy(_ id: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }), board.write(entry) else { return false }
        lastChange = board.changeCount
        return true
    }
    func delete(_ id: UUID) { entries.removeAll { $0.id == id }; changed() }
    func pin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle(); changed()
    }
    func clear() throws {
        entries = []; lastChange = board.changeCount
        if let days = startupDays {
            persistent = true
            ageDays = min(365, max(1, days))
        }
        storageIntent = .delete // Explicit Clear supersedes every restore intent.
        defer { onChange() }
        try finishArchiveDeletion()
    }
    @discardableResult
    func flushPendingStorage() -> Bool {
        if storagePending { retryStorage() }
        return !storagePending
    }
    func stop() { setRecording(false); entries = []; onChange() }
    private func prune() {
        let cutoff = now().addingTimeInterval(-Double(ageDays) * 86400)
        var ids = Set<UUID>()
        entries = entries.filter { entry in
            guard ids.insert(entry.id).inserted, !exclusions.contains(entry.source),
                  entry.created <= now(), entry.pinned || entry.created > cutoff else { return false }
            if let text = entry.text { return entry.image == nil && !text.isEmpty && text.utf8.count <= Self.textLimit }
            return entry.image.map { !$0.isEmpty && $0.count <= Self.imageLimit } ?? false
        }
        // Pins survive age expiry and are evicted last, but never bypass hard caps.
        while entries.count > 100 || entries.reduce(0, { $0 + ($1.image?.count ?? 0) }) > Self.imageBudget {
            let imageOver = entries.reduce(0, { $0 + ($1.image?.count ?? 0) }) > Self.imageBudget
            let index = entries.lastIndex { !$0.pinned && (!imageOver || $0.image != nil) }
                ?? entries.lastIndex { !imageOver || $0.image != nil }!
            entries.remove(at: index)
        }
    }
    private func changed() {
        if persistent {
            if case .idle = storageIntent { storageIntent = .save }
            retryStorage()
        }
        onChange()
    }
    private func finishArchiveDeletion() throws {
        try archive.clear()
        // Clear permits new post-Clear captures; Disable sets persistent=false
        // first and must never rewrite memory to disk during deletion recovery.
        storageIntent = persistent && !entries.isEmpty ? .save : .idle
        if case .save = storageIntent {
            try archive.save(entries)
            storageIntent = .idle
        }
    }
    private func reconcileStorage() throws {
        switch storageIntent {
        case .idle: return
        case .delete: try finishArchiveDeletion()
        case .startup(let days): try configurePersistence(true, ageDays: days, load: true)
        case .rollback(let original):
            if original.isEmpty { try archive.clear() }
            else { try archive.save(original) }
            storageIntent = .idle
        case .save:
            try archive.save(entries)
            storageIntent = .idle
        }
    }
    private func retryStorage() {
        do { try reconcileStorage() } catch { onError() }
        onChange()
    }
}
