import Foundation
import Darwin

var checks = 0
func check(_ value: Bool, _ label: String) throws {
    guard value else { throw DiagnosticLogReader.failure(label) }
    checks += 1; print("PASS: \(label)")
}
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = UUID().uuidString, second = UUID().uuidString
    let now = Date(timeIntervalSince1970: 1000)
    func line(_ session: String, _ event: String, at time: Date, role: String = "gui", pid: Int = 123) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: time), "pid": pid,
            "session": session, "category": "process", "event": event, "severity": "info", "fields": ["process_role": role]])
        data.append(10); return data
    }
    var old = try line(first, "startup", at: now)
    old.append(Data("malformed\n{partial".utf8))
    try old.write(to: root.appendingPathComponent("fixmacos-123-\(first)-2.jsonl"))
    try line(first, "later", at: now.addingTimeInterval(1)).write(to: root.appendingPathComponent("fixmacos-123-\(first)-0.jsonl"))
    try line(second, "startup", at: now.addingTimeInterval(2), role: "watchdog", pid: 456).write(to: root.appendingPathComponent("fixmacos-456-\(second)-0.jsonl"))
    try Data("PRIVATE_UNRELATED\n".utf8).write(to: root.appendingPathComponent("unrelated.jsonl"))
    let symlink = root.appendingPathComponent("fixmacos-789-\(UUID().uuidString)-0.jsonl")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("unrelated.jsonl"))
    let loaded = try DiagnosticLogReader.read(root.path)
    try check(loaded.records.count == 3 && loaded.skipped == 1, "reader skips malformed/partial lines, unrelated files and symlinks")
    try check(loaded.records.map(\.event) == ["startup", "later", "startup"], "reader orders rotations and distinct sessions chronologically")
    let startup = loaded.records[0]
    try check(DiagnosticLogReader.liveGUI(startup, birth: { _ in now.addingTimeInterval(-1) }), "current GUI matches actual birth time")
    try check(!DiagnosticLogReader.liveGUI(startup, birth: { _ in now.addingTimeInterval(5) }), "PID reuse cannot select an older startup")
    try check(!DiagnosticLogReader.liveGUI(loaded.records[2], birth: { _ in now }), "newer helper cannot displace GUI session")
    try check(!DiagnosticLogReader.liveGUI(startup, birth: { _ in nil }), "dead PID cannot select historical GUI automatically")
    try DiagnosticLogReader.run(["--directory", root.path, "--session", first, "--all", "--since", "1970-01-01T00:16:41Z", "--category", "process", "--level", "info", "--limit", "1"])
    for args in [["--limit", "201"], ["--level", "invalid"], ["--since", "bad"], ["--pid", "0"], ["--session", first, "--pid", "123"], ["--session", UUID().uuidString, "--directory", root.path], ["--directory", root.appendingPathComponent("missing").path]] {
        do { try DiagnosticLogReader.run(args); throw DiagnosticLogReader.failure("accepted invalid/missing input") }
        catch { try check(!error.localizedDescription.contains("accepted invalid"), "invalid/missing reader input fails explicitly") }
    }
    print("\(checks) diagnostic reader checks passed")
} catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
