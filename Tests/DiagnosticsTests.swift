import Foundation
import ClipboardPolicy

final class MemoryDiagnosticSink: DiagnosticSink {
    var lines = [Data]()
    var fail = false
    func write(_ line: Data) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        lines.append(line)
    }
    var records: [[String: Any]] { lines.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
}

private final class MemoryDiagnosticFiles: DiagnosticFiles {
    var data: [URL: Data] = [:]
    var fail = false
    func prepare(_ directory: URL) throws { if fail { throw CocoaError(.fileWriteNoPermission) } }
    func size(_ file: URL) throws -> Int { data[file]?.count ?? 0 }
    func append(_ bytes: Data, to file: URL) throws { data[file, default: Data()].append(bytes) }
    func remove(_ file: URL) throws { data.removeValue(forKey: file) }
    func move(_ source: URL, to destination: URL) throws { data[destination] = data.removeValue(forKey: source) }
    func files(_ directory: URL) throws -> [URL] { Array(data.keys) }
    func withLock(_ directory: URL, work: () throws -> Void) throws { try work() }
}

private final class DiagnosticBoard: ClipboardAccess {
    var changeCount = 0
    var markedPrivate = false
    func text() -> String? { "NEVER_LOG_CLIPBOARD_SECRET" }
    func image() -> Data? { nil }
    func write(_ entry: ClipboardEntry) -> Bool { true }
}
private final class DiagnosticArchive: ClipboardPersistence {
    var fail = false
    func load() throws -> [ClipboardEntry] {
        if fail { throw CocoaError(.fileReadNoPermission) }
        return [ClipboardEntry(id: UUID(), created: Date(timeIntervalSince1970: 1000), source: "private.app.identifier", text: "NEVER_LOG_CLIPBOARD_SECRET", image: nil, pinned: false)]
    }
    func save(_ entries: [ClipboardEntry]) throws { if fail { throw CocoaError(.fileWriteNoPermission) } }
    func clear() throws { if fail { throw CocoaError(.fileWriteNoPermission) } }
}

private struct DiagnosticLoginService: LoginServicing {
    let failure: Error
    var status: LoginStatus { .requiresApproval }
    func register() throws { throw failure }
    func unregister() throws { throw failure }
    func openSettings() { preconditionFailure("No real settings action in diagnostics") }
}

func runDiagnosticsTests() throws {
    let memory = MemoryDiagnosticSink()
    var tick: TimeInterval = 10
    let logger = Diagnostics(sink: memory, session: "fixed-session", pid: 123,
                             now: { Date(timeIntervalSince1970: 0) }, uptime: { tick }, minimumLevel: .trace)
    let start = logger.start(); tick = 10.125
    logger.emit("test", "finished", outcome: "success", operation: "fixed-operation", since: start)
    expect(logger.flushForTesting(), "test-only diagnostic flush completes")
    let first = memory.records[0]
    expect(first["session"] as? String == "fixed-session" && first["pid"] as? Int == 123, "diagnostics preserve injected correlation")
    expect(first["timestamp"] as? String == "1970-01-01T00:00:00.000Z" && first["durationMS"] as? Double == 125, "diagnostics use injected wall and monotonic clocks")
    memory.fail = true
    logger.emit("test", "failed_io")
    expect(logger.flushForTesting(), "test-only failed IO flush completes")
    expect(memory.lines.count == 1, "failed diagnostic IO is swallowed without recursion")
    memory.fail = false
    DispatchQueue.concurrentPerform(iterations: 100) { index in
        logger.emit("test", "concurrent_write", fields: ["index": String(index)])
    }
    expect(logger.flushForTesting(), "test-only concurrent delivery flush completes")
    expect(memory.records.count == 101, "concurrent emitters serialize complete JSON records")

    let filesystem = MemoryDiagnosticFiles(), session = UUID().uuidString
    let directory = URL(fileURLWithPath: "/isolated-diagnostic-fixture")
    let rotating = RotatingDiagnosticSink(directory: directory, session: session, pid: getpid(), limit: 1024, retainedFiles: 3, files: filesystem)
    let unrelated = directory.appendingPathComponent("unrelated.jsonl")
    filesystem.data[unrelated] = Data("preserve".utf8)
    for index in 0..<12 { try rotating.write(Data((String(repeating: "x", count: 600) + "\(index)\n").utf8)) }
    expect(filesystem.data.count == 4 && filesystem.data.values.allSatisfy { $0.count <= 1024 }, "rotation bounds three files and leaves unrelated files untouched")
    expect(filesystem.data[unrelated] == Data("preserve".utf8), "retention never removes unrelated files")
    let old = directory.appendingPathComponent("fixmacos-2147483647-\(UUID().uuidString)-0.jsonl")
    filesystem.data[old] = Data([1])
    try rotating.write(Data([10]))
    expect(filesystem.data[old] == nil, "global retention reaps owned dead-process logs")
    filesystem.fail = true
    let failedSink = RotatingDiagnosticSink(directory: directory, session: UUID().uuidString, pid: 123, files: filesystem)
    let failedLogger = Diagnostics(sink: failedSink)
    failedLogger.emit("test", "no_directory")
    expect(failedLogger.flushForTesting(), "test-only failed preparation flush completes")
    expect(filesystem.data.count == 4, "directory preparation failure does not create logs or escape")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixmacos-diagnostic-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let localDirectory = root.appendingPathComponent("logs", isDirectory: true)
    let local = RotatingDiagnosticSink(directory: localDirectory, session: UUID().uuidString, pid: getpid(), limit: 1024)
    try local.write(Data("{}\n".utf8))
    let localFiles = try FileManager.default.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    let directoryMode = try FileManager.default.attributesOfItem(atPath: localDirectory.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: localFiles[0].path)[.posixPermissions] as? NSNumber
    expect(directoryMode?.intValue == 0o700 && fileMode?.intValue == 0o600, "diagnostic directory and files are private")
    let lockFile = localDirectory.appendingPathComponent(".rotation.lock")
    let descriptor = open(lockFile.path, O_WRONLY)
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { close(descriptor) }
    expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "fixture can hold global diagnostic rotation lock")
    try local.write(Data("{\"must_drop_while_busy\":true}\n".utf8))
    let afterBusyLock = try Data(contentsOf: localFiles[0])
    expect(afterBusyLock == Data("{}\n".utf8), "busy cross-process lock drops event instead of blocking")
    flock(descriptor, LOCK_UN)
    let symlink = root.appendingPathComponent("symlink-logs")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: localDirectory)
    let linked = RotatingDiagnosticSink(directory: symlink, session: UUID().uuidString, pid: getpid())
    do { try linked.write(Data("{}\n".utf8)); expect(false, "symlink directory must be rejected") } catch {}
    let unrelatedDirectory = localDirectory.appendingPathComponent("fixmacos-2147483647-\(UUID().uuidString)-0.jsonl")
    try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)
    try local.write(Data("{}\n".utf8))
    expect(FileManager.default.fileExists(atPath: unrelatedDirectory.path), "retention never recursively deletes a matching directory")

    // A fixture executable, not blueutil or a live device. Both output streams
    // deliberately contain known sensitive bytes that must never reach logs.
    let command = root.appendingPathComponent("blueutil")
    let sensitive = "AA-BB-CC-DD-EE-FF private-headset /Users/private-home NEVER_LOG_CLIPBOARD_SECRET"
    try Data("#!/bin/sh\necho '\(sensitive)'\necho '\(sensitive)' >&2\nexit 75\n".utf8).write(to: command)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
    do { _ = try CommandRunner(diagnostics: logger).run(command.path, ["--connect", sensitive]); expect(false, "fixture must fail") }
    catch {}
    expect(logger.flushForTesting(), "test-only command logging flush completes")
    let failure = memory.records.last!
    let fields = failure["fields"] as? [String: String]
    expect(fields?["exit_code"] == "75" && fields?["failure_class"] == "exit" && fields?["timed_out"] == "false", "Bluetooth exit 75 is classified with code, not raw output")
    expect(fields?["action"] == "--connect" && failure["outcome"] as? String == "failure", "Bluetooth logs safe operation semantics")
    expect(fields?["reported_failure"] == "unknown", "generic exit 75 retains unknown reported cause at all verbosity")
    for (text, classification) in [("connection failed private-headset", "reported_connection_failure"),
                                   ("timed out AA-BB-CC-DD-EE-FF", "reported_timeout"),
                                   ("not paired", "reported_not_paired"), ("permission denied", "reported_access_failure"),
                                   ("exit 1", "unknown"), ("exit 75", "unknown")] {
        expect(CommandRunner.reportedFailure(text) == classification, "command symptom classification uses closed phrases, not exit-code guesses")
    }
    expect(memory.records.suffix(2).first?["operation"] as? String == failure["operation"] as? String, "command start and failure correlate")
    do {
        try LoginDiagnostics.change(true, service: DiagnosticLoginService(failure:
            NSError(domain: "private.error.domain", code: 91, userInfo: [NSLocalizedDescriptionKey: sensitive])), diagnostics: logger)
        expect(false, "login fixture must throw")
    } catch {}
    expect(logger.flushForTesting(), "test-only login logging flush completes")
    let login = memory.records.last!, loginFields = memory.records.last?["fields"] as? [String: String]
    expect(login["outcome"] as? String == "failure" && loginFields?["status"] == "requires_approval" && loginFields?["error_code"] == "91", "login failure preserves approval and numeric error")
    let encoded = memory.lines.map { String(decoding: $0, as: UTF8.self) }.joined()
    for secret in [sensitive, "AA-BB-CC-DD-EE-FF", "private-headset", "/Users/private-home", "NEVER_LOG_CLIPBOARD_SECRET", "private.error.domain"] {
        expect(!encoded.contains(secret), "operational logs omit known sensitive fixture bytes")
    }

    let archive = DiagnosticArchive()
    var storageTick: TimeInterval = 0
    let history = ClipboardHistory(board: DiagnosticBoard(), archive: archive, now: { Date(timeIntervalSince1970: 1001) },
                                   source: { "private.app.identifier" }, monotonic: { storageTick += 0.125; return storageTick })
    var events = [ClipboardStorageDiagnostic]()
    history.onStorageDiagnostic = { events.append($0) }
    archive.fail = true
    do { try history.configurePersistence(true, ageDays: 7, load: true) } catch {}
    expect(events.last?.action == .load && events.last?.reason == .startup && events.last?.succeeded == false && history.storagePending,
           "failed startup archive load logs reason and retains existing pending policy")
    expect(events.last?.durationMS == 125, "policy diagnostic duration uses injected monotonic clock")
    expect(events.last?.failure == .io && events.last?.errorCode == CocoaError.fileReadNoPermission.rawValue,
           "archive failure diagnostics classify IO without raw error text")
    archive.fail = false
    expect(history.flushPendingStorage(), "diagnostic hooks preserve retry pipeline")
    expect(events.suffix(2).map(\.action) == [.load, .save] && events.last?.entryCount == 1, "recovery reports load/save counts without content")
    try history.clear()
    expect(events.last?.action == .clear && events.last?.reason == .explicitClear, "Clear logs explicit intent")
    try history.configurePersistence(false, ageDays: 7, load: true)
    expect(events.last?.action == .clear && events.last?.reason == .startup, "startup-default cleanup is distinguishable from explicit Clear")
}
