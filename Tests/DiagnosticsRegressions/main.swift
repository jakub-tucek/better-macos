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

final class GatedSink: DiagnosticSink {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var lines: [Data] = []
    func write(_ line: Data) throws {
        if lines.isEmpty { entered.signal(); release.wait() }
        lines.append(line)
    }
}

func responsiveDelivery() throws {
    let sink = GatedSink()
    let blocked = Diagnostics(sink: sink, capacity: 4)
    let returned = DispatchSemaphore(value: 0), safetyAction = DispatchSemaphore(value: 0)
    defer { sink.release.signal() }
    DispatchQueue.global().async {
        blocked.emit("test", "blocked")
        // Stand-in for unrelated host recovery immediately after diagnostics.
        safetyAction.signal(); returned.signal()
    }
    try check(sink.entered.wait(timeout: .now() + 5) == .success, "writer reaches deterministic filesystem gate")
    try check(returned.wait(timeout: .now() + 5) == .success && safetyAction.wait(timeout: .now() + 5) == .success,
              "blocked writer never delays caller or subsequent safety work")
    for index in 0..<1000 { blocked.emit("test", "queued\(index)", fields: ["bounded": String(repeating: "x", count: 1024)]) }
    let state = blocked.deliveryStateForTesting
    try check(state.outstanding == 4 && state.dropped == 997, "admission bounds active plus pending events before scheduling and drops overflow")
    blocked.emit("test", "oversized", fields: ["payload": String(repeating: "x", count: 32 * 1024)])
    try check(blocked.deliveryStateForTesting.outstanding == 4, "oversized payload is never retained")
    sink.release.signal()
    try check(blocked.flushForTesting(), "test-only bounded flush drains after filesystem release")
    let events = try sink.lines.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    try check(events.compactMap { $0?["event"] as? String } == ["blocked", "queued0", "queued1", "queued2"], "accepted events retain admission order")

    let metadataEntered = DispatchSemaphore(value: 0), metadataRelease = DispatchSemaphore(value: 0)
    let startupReturned = DispatchSemaphore(value: 0)
    let startup = Diagnostics(sink: sink, startupMetadata: {
        metadataEntered.signal(); metadataRelease.wait(); return ["metadata_capture": "worker"]
    })
    defer { metadataRelease.signal() }
    DispatchQueue.global().async { startup.emit("process", "startup"); startupReturned.signal() }
    try check(metadataEntered.wait(timeout: .now() + 5) == .success && startupReturned.wait(timeout: .now() + 5) == .success,
              "blocked startup metadata collection cannot delay helper caller")
    metadataRelease.signal()
    try check(startup.flushForTesting(), "startup metadata drains only through test-only flush")
}

do { try existingDirectory(); try responsiveDelivery() }
catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
