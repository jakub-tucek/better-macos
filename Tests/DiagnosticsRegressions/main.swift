import Foundation
import Darwin

func check(_ value: Bool, _ message: String) throws {
    guard value else { throw NSError(domain: "DiagnosticRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    print("PASS: \(message)")
}

func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-regression-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

func existingDirectory() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    let first = RotatingDiagnosticSink(directory: logs, session: UUID().uuidString, pid: getpid())
    try first.write(Data("first\n".utf8))
    let second = RotatingDiagnosticSink(directory: logs, session: UUID().uuidString, pid: getpid())
    try second.write(Data("second\n".utf8))
    let records = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    try check(records.count == 2, "distinct sessions reuse a validated existing directory")

    let concurrent = root.appendingPathComponent("concurrent")
    let ready = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), done = DispatchGroup()
    let lock = NSLock()
    var failures = 0
    for _ in 0..<2 {
        done.enter()
        DispatchQueue.global().async {
            ready.signal(); go.wait()
            do { try LocalDiagnosticFiles().prepare(concurrent) }
            catch { lock.lock(); failures += 1; lock.unlock() }
            done.leave()
        }
    }
    try check(ready.wait(timeout: .now() + 5) == .success && ready.wait(timeout: .now() + 5) == .success, "concurrent creators reach barrier")
    go.signal(); go.signal()
    try check(done.wait(timeout: .now() + 5) == .success && failures == 0, "concurrent real-filesystem directory creation accepts secure winner")
}

do { try existingDirectory() }
catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
