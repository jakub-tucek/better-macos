import ClipboardPolicy
import Foundation
import Testing

@Suite("Clipboard JSON archive")
struct ClipboardArchiveTests {
    @Test("Round trip retains identity and image data with private permissions")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ClipboardArchive(directory: directory)
        #expect(try archive.load().isEmpty)
        let entries = [ClipboardEntry(id: UUID(), created: Date(timeIntervalSince1970: 1_000_000), source: "fixture", text: nil, image: Data([1, 2, 3]), pinned: true)]
        try archive.save(entries)
        #expect(try archive.load() == entries)
        let file = directory.appendingPathComponent("history.json")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
        try archive.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try archive.load().isEmpty)
        try archive.clear()
    }

    @Test("Malformed JSON is rejected without replacing the archive")
    func malformedArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try ClipboardArchive(directory: directory).load() }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
