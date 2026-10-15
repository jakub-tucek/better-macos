import Foundation
import Darwin

var regressionChecks = 0
func check(_ value: Bool, _ message: String) throws {
    guard value else { throw NSError(domain: "DiagnosticRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    regressionChecks += 1
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
    let creators = (0..<2).map { _ in RotatingDiagnosticSink(directory: concurrent, session: UUID().uuidString, pid: getpid()) }
    for creator in creators {
        done.enter()
        DispatchQueue.global().async {
            ready.signal(); go.wait()
            do { try creator.write(Data("concurrent\n".utf8)) }
            catch { lock.lock(); failures += 1; lock.unlock() }
            done.leave()
        }
    }
    try check(ready.wait(timeout: .now() + 5) == .success && ready.wait(timeout: .now() + 5) == .success, "concurrent creators reach barrier")
    go.signal(); go.signal()
    try check(done.wait(timeout: .now() + 5) == .success && failures == 0, "concurrent real-filesystem directory creation accepts secure winner")
    // The nonblocking cross-process lock may intentionally drop a racing event.
    for creator in creators { try creator.write(Data("after barrier\n".utf8)) }
    let created = try FileManager.default.contentsOfDirectory(atPath: concurrent.path).filter { $0.hasSuffix(".jsonl") }
    try check(created.count == 2, "concurrently created directory supports both distinct sessions")
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

func replacedDirectory() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs"), retained = root.appendingPathComponent("retained")
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let session = UUID().uuidString
    let sink = RotatingDiagnosticSink(directory: logs, session: session, pid: getpid(), limit: 1024, retainedFiles: 3)
    try sink.write(Data("original\n".utf8))
    try FileManager.default.moveItem(at: logs, to: retained)
    let ownedName = "fixmacos-\(getpid())-\(session)-0.jsonl"
    let sentinel = target.appendingPathComponent(ownedName)
    try Data("TARGET MUST STAY UNCHANGED".utf8).write(to: sentinel)
    var targetNames = [ownedName, "unrelated.txt"]
    for _ in 0..<4 { targetNames.append("fixmacos-2147483647-\(UUID().uuidString)-0.jsonl") }
    for name in targetNames.dropFirst() {
        try Data("DO NOT DELETE".utf8).write(to: target.appendingPathComponent(name))
        if name.hasPrefix("fixmacos-") { try Data("owned old session".utf8).write(to: retained.appendingPathComponent(name)) }
    }
    try Data("UNRELATED ORIGINAL".utf8).write(to: retained.appendingPathComponent("unrelated.txt"))
    try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: target)
    for _ in 0..<5 { try? sink.write(Data((String(repeating: "x", count: 800) + "\n").utf8)) }
    let afterSymlink = try Data(contentsOf: sentinel)
    try check(afterSymlink == Data("TARGET MUST STAY UNCHANGED".utf8), "prepared directory replacement symlink never receives appends or rotation")
    try check(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)) == Set(targetNames), "symlink target receives no lock files, creations or retention deletions")
    for name in targetNames.dropFirst() {
        try check(try Data(contentsOf: target.appendingPathComponent(name)) == Data("DO NOT DELETE".utf8), "replacement target contents stay unchanged during retention")
    }
    try FileManager.default.removeItem(at: logs)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
    let replacementSentinel = logs.appendingPathComponent(ownedName)
    try Data("REPLACEMENT MUST STAY UNCHANGED".utf8).write(to: replacementSentinel)
    for _ in 0..<5 { try? sink.write(Data((String(repeating: "y", count: 800) + "\n").utf8)) }
    let afterOrdinary = try Data(contentsOf: replacementSentinel)
    try check(afterOrdinary == Data("REPLACEMENT MUST STAY UNCHANGED".utf8), "ordinary replacement directory is not adopted by a prepared writer")
    try check(try FileManager.default.contentsOfDirectory(atPath: logs.path) == [ownedName], "ordinary replacement receives no lock, rotation or cleanup")
    try check(try Data(contentsOf: retained.appendingPathComponent("unrelated.txt")) == Data("UNRELATED ORIGINAL".utf8), "descriptor-relative retention preserves nonowned files in original inode")
    try check(targetNames.filter { $0.hasPrefix("fixmacos-2147483647-") }.allSatisfy {
        !FileManager.default.fileExists(atPath: retained.appendingPathComponent($0).path)
    }, "retention actually prunes owned old sessions only inside retained inode")

    let secure = root.appendingPathComponent("hardlink-test")
    let files = LocalDiagnosticFiles()
    try files.prepare(secure)
    let outside = root.appendingPathComponent("outside")
    try Data("OUTSIDE".utf8).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
    let linked = secure.appendingPathComponent("linked.jsonl")
    guard link(outside.path, linked.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    var rejected = 0
    do { try files.append(Data("bad".utf8), to: linked) } catch { rejected += 1 }
    do { try files.remove(linked) } catch { rejected += 1 }
    let outsideData = try Data(contentsOf: outside)
    let mode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber
    try check(rejected == 2 && outsideData == Data("OUTSIDE".utf8) && mode?.intValue == 0o644, "hardlinked regular files are rejected before content or permission mutation")
}

do {
    for _ in 0..<10 { try existingDirectory() }
    try responsiveDelivery(); try replacedDirectory()
    print("\(regressionChecks) diagnostic review regression checks passed")
}
catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
