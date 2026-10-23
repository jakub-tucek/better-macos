import Foundation
import Darwin

private func ownedLogs(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
        $0.lastPathComponent.range(of: #"^bettermacos-[0-9]+-[A-Fa-f0-9-]{36}-[012]\.jsonl$"#, options: .regularExpression) != nil
    }
}

/// Flags are changed only on files this fixture created under its unique root.
private final class RetentionFixture {
    let root: URL
    let logs: URL
    private var flagged: [URL] = []
    init() throws {
        root = try temporaryRoot(); logs = root.appendingPathComponent("logs", isDirectory: true)
        try LocalDiagnosticFiles().prepare(logs)
    }
    deinit {
        for file in flagged {
            if chflags(file.path, 0) != 0 && errno != ENOENT { fputs("FAIL: restoring fixture-owned temporary flags\n", stderr) }
        }
        try? FileManager.default.removeItem(at: root)
    }
    func seed(immutable: Bool, oldest: Bool = false, owned: Bool = true) throws -> URL {
        let name = owned ? "bettermacos-2147483647-\(UUID().uuidString)-0.jsonl" : "unrelated-\(UUID().uuidString).txt"
        let file = logs.appendingPathComponent(name, isDirectory: false)
        try Data("fixture sentinel\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: oldest ? 1 : 2)], ofItemAtPath: file.path)
        if immutable {
            guard chflags(file.path, UInt32(UF_IMMUTABLE)) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            flagged.append(file)
        }
        return file
    }
    func unchanged(_ file: URL) throws -> Bool {
        var info = stat()
        return try Data(contentsOf: file) == Data("fixture sentinel\n".utf8)
            && lstat(file.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0
    }
}

private func immutableOldestRetention() throws {
    let fixture = try RetentionFixture()
    let oldest = try fixture.seed(immutable: true, oldest: true)
    let unrelated = try fixture.seed(immutable: true, owned: false)
    var failures = 0
    var latest: URL?
    for index in 0..<30 {
        let sink = RotatingDiagnosticSink(directory: fixture.logs, session: UUID().uuidString, pid: getpid())
        latest = fixture.logs.appendingPathComponent("\(sink.prefix)-0.jsonl")
        do { try sink.write(Data("new session \(index)\n".utf8)) } catch { failures += 1 }
    }
    let count = try ownedLogs(fixture.logs).count
    print("INFO: oldest-immutable reproduction owned=\(count) writeFailures=\(failures)")
    try check(count <= 24 && failures == 0, "immutable oldest candidate cannot defeat 24-file admission; later candidates are evicted")
    try check(count == 24 && (try latest.map { try Data(contentsOf: $0) }) == Data("new session 29\n".utf8),
              "eligible later evictions keep newest-session delivery working rather than dropping every full-budget event")
    try check(try fixture.unchanged(oldest) && fixture.unchanged(unrelated), "retention never clears immutable flags or changes unrelated immutable content")
}

private func existingAtCapacity() throws {
    let fixture = try RetentionFixture()
    for _ in 0..<23 { _ = try fixture.seed(immutable: true) }
    let sink = RotatingDiagnosticSink(directory: fixture.logs, session: UUID().uuidString, pid: getpid(), limit: 1024)
    let current = fixture.logs.appendingPathComponent("\(sink.prefix)-0.jsonl")
    let initial = Data(repeating: 97, count: 800), tail = Data(repeating: 98, count: 100)
    try sink.write(initial); try sink.write(tail)
    var expected = initial; expected.append(tail)
    try check(try ownedLogs(fixture.logs).count == 24 && Data(contentsOf: current) == expected,
              "existing in-budget file can append within size limit even when other sessions are immutable")
    try? sink.write(initial)
    try check(try ownedLogs(fixture.logs).count == 24 && Data(contentsOf: current) == expected,
              "rotation needing another slot drops at fully blocked capacity without modifying current file")
    _ = try fixture.seed(immutable: true)
    try? sink.write(Data("must drop\n".utf8))
    try check(try ownedLogs(fixture.logs).count == 25 && Data(contentsOf: current) == expected,
              "pre-existing over-budget state is pruned or dropped even for an existing-file append")
}

private func blockedRetention() throws {
    let fixture = try RetentionFixture()
    var blocked: [URL] = []
    for _ in 0..<24 { blocked.append(try fixture.seed(immutable: true)) }
    let sink = RotatingDiagnosticSink(directory: fixture.logs, session: UUID().uuidString, pid: getpid(), limit: 1024)
    for _ in 0..<2 { try? sink.write(Data(repeating: 120, count: 800)) }
    try check(try ownedLogs(fixture.logs).count == 24, "all candidates blocked: repeated delivery creates no additional session or rotation file")
    try check(try blocked.allSatisfy { try fixture.unchanged($0) }, "all blocked files retain content and immutable flags")

    // An externally/pre-existing over-budget directory cannot always be repaired.
    let extra = try fixture.seed(immutable: true)
    try? sink.write(Data("must drop\n".utf8))
    try check(try ownedLogs(fixture.logs).count == 25 && fixture.unchanged(extra), "already over budget and undeletable: drop without additional growth")
}

private func rotationCapacity() throws {
    let fixture = try RetentionFixture()
    let oldest = try fixture.seed(immutable: true, oldest: true)
    let evictable = try fixture.seed(immutable: false)
    let session = UUID().uuidString
    let sink = RotatingDiagnosticSink(directory: fixture.logs, session: session, pid: getpid(), limit: 1024, retainedFiles: 3)
    let bytes = Data(repeating: 97, count: 800)
    try sink.write(bytes)
    try sink.write(bytes)
    let current = fixture.logs.appendingPathComponent("bettermacos-\(getpid())-\(session)-0.jsonl")
    let previous = fixture.logs.appendingPathComponent("bettermacos-\(getpid())-\(session)-1.jsonl")
    try check(try ownedLogs(fixture.logs).count == 3 && Data(contentsOf: current) == bytes && Data(contentsOf: previous) == bytes,
              "rotation reserves room before creating new current file at capacity")
    try check(!FileManager.default.fileExists(atPath: evictable.path) && (try fixture.unchanged(oldest)), "rotation skips immutable candidate and evicts another eligible session")
    // The remaining other session is immutable: no capacity for another generation.
    try? sink.write(bytes)
    let generations = try ownedLogs(fixture.logs)
    try check(generations.count == 3 && (try Data(contentsOf: current)) == bytes && (try Data(contentsOf: previous)) == bytes,
              "blocked rotation drops before renaming or adding a generation")
    try check(try generations.allSatisfy { try Data(contentsOf: $0).count <= 1024 }, "capacity drops never permit per-file overflow")
}

private final class CapacityProbe {
    private let lock = NSLock()
    private(set) var maximum = 0
    private(set) var failures = 0
    func observe(_ directory: URL) throws {
        let count = try ownedLogs(directory).count
        lock.lock(); maximum = max(maximum, count); lock.unlock()
    }
    func fail() { lock.lock(); failures += 1; lock.unlock() }
}

/// Actual descriptor-relative filesystem and flock; only the first lock body is gated.
private final class GatedRetentionFiles: DiagnosticFiles {
    let base = LocalDiagnosticFiles()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private var gate: Bool
    let directory: URL
    let probe: CapacityProbe
    init(directory: URL, gate: Bool, probe: CapacityProbe) { self.directory = directory; self.gate = gate; self.probe = probe }
    func prepare(_ directory: URL) throws { try base.prepare(directory) }
    func size(_ file: URL) throws -> Int { try base.size(file) }
    func append(_ line: Data, to file: URL) throws { try base.append(line, to: file); try probe.observe(directory) }
    func remove(_ file: URL) throws { try base.remove(file) }
    func move(_ source: URL, to destination: URL) throws { try base.move(source, to: destination) }
    func files(_ directory: URL) throws -> [URL] { try base.files(directory) }
    func withLock(_ directory: URL, work: () throws -> Void) throws {
        try base.withLock(directory) {
            if gate { gate = false; entered.signal(); release.wait() }
            try work()
        }
    }
}

private func concurrentRetention() throws {
    let fixture = try RetentionFixture()
    _ = try fixture.seed(immutable: true, oldest: true)
    _ = try fixture.seed(immutable: false)
    _ = try fixture.seed(immutable: false)
    let probe = CapacityProbe()
    let filesA = GatedRetentionFiles(directory: fixture.logs, gate: true, probe: probe)
    let filesB = GatedRetentionFiles(directory: fixture.logs, gate: false, probe: probe)
    let a = RotatingDiagnosticSink(directory: fixture.logs, session: UUID().uuidString, pid: getpid(), limit: 1024, retainedFiles: 3, files: filesA)
    let b = RotatingDiagnosticSink(directory: fixture.logs, session: UUID().uuidString, pid: getpid(), limit: 1024, retainedFiles: 3, files: filesB)
    let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
    let bytes = Data(repeating: 99, count: 800)
    defer { filesA.release.signal() }
    DispatchQueue.global().async { do { try a.write(bytes) } catch { probe.fail() }; first.signal() }
    try check(filesA.entered.wait(timeout: .now() + 5) == .success, "real directory lock is held before concurrent capacity test")
    DispatchQueue.global().async { do { try b.write(bytes) } catch { probe.fail() }; second.signal() }
    try check(second.wait(timeout: .now() + 5) == .success && (try ownedLogs(fixture.logs).count) == 3,
              "distinct session drops under real lock contention before creating files")
    filesA.release.signal()
    try check(first.wait(timeout: .now() + 5) == .success, "lock holder completes capacity admission after gate release")
    try check(try ownedLogs(fixture.logs).contains { $0.lastPathComponent == "\(a.prefix)-0.jsonl" }, "lock holder actually delivers after evicting an eligible session")
    let done = DispatchGroup(), ready = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
    for sink in [a, b] {
        done.enter()
        DispatchQueue.global().async {
            ready.signal(); go.wait()
            for _ in 0..<20 { do { try sink.write(bytes) } catch { probe.fail() } }
            done.leave()
        }
    }
    try check(ready.wait(timeout: .now() + 5) == .success && ready.wait(timeout: .now() + 5) == .success, "distinct real filesystem sessions reach concurrent writer barrier")
    go.signal(); go.signal()
    try check(done.wait(timeout: .now() + 10) == .success, "concurrent rotation writers complete without blocking on directory lock")
    try check(probe.maximum == 3 && probe.failures == 0 && (try ownedLogs(fixture.logs).count) <= 3,
              "count plus eviction plus creation remains within budget inside real locked appends")
}

func runRetentionRegressions() throws {
    var failed = 0
    let cases: [(String, () throws -> Void)] = [("immutable oldest", immutableOldestRetention), ("all blocked", blockedRetention), ("existing file", existingAtCapacity),
                                               ("rotation capacity", rotationCapacity), ("concurrent capacity", concurrentRetention)]
    for (name, test) in cases {
        do { try test() }
        catch { failed += 1; fputs("FAIL: \(name): \(error.localizedDescription)\n", stderr) }
    }
    if failed > 0 { throw NSError(domain: "RetentionRegression", code: failed, userInfo: [NSLocalizedDescriptionKey: "\(failed) retention regression cases failed"]) }
}
