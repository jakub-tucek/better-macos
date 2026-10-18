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
    func line(_ session: String, _ event: String, at time: Date, role: String = "gui", pid: Int = 123,
              category: String = "process", level: String = "info") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: time), "pid": pid,
            "session": session, "category": category, "event": event, "severity": level, "fields": ["process_role": role]])
        data.append(10); return data
    }
    var old = try line(first, "startup", at: now)
    old.append(Data("malformed\n{partial".utf8))
    try old.write(to: root.appendingPathComponent("fixmacos-123-\(first)-2.jsonl"))
    var current = try line(first, "same_tick", at: now)
    current.append(try line(first, "later", at: now.addingTimeInterval(1)))
    try current.write(to: root.appendingPathComponent("fixmacos-123-\(first)-0.jsonl"))
    for (generation, mtime) in [(0, 1000.0), (2, 2000.0)] {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: root.appendingPathComponent("fixmacos-123-\(first)-\(generation).jsonl").path)
    }
    try line(second, "startup", at: now.addingTimeInterval(2), role: "watchdog", pid: 456).write(to: root.appendingPathComponent("fixmacos-456-\(second)-0.jsonl"))
    try Data("PRIVATE_UNRELATED\n".utf8).write(to: root.appendingPathComponent("unrelated.jsonl"))
    let symlink = root.appendingPathComponent("fixmacos-789-\(UUID().uuidString)-0.jsonl")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("unrelated.jsonl"))
    let loaded = try DiagnosticLogReader.read(root.path)
    try check(loaded.records.count == 4 && loaded.skipped == 1, "reader skips malformed/partial lines, unrelated files and symlinks")
    try check(loaded.records.map(\.event) == ["startup", "same_tick", "later", "startup"], "reader orders rotations and distinct sessions, preserving equal-timestamp generation order")
    let startup = loaded.records[0]
    try check(DiagnosticLogReader.liveGUI(startup, birth: { _ in now.addingTimeInterval(-1) }), "current GUI matches actual birth time")
    try check(!DiagnosticLogReader.liveGUI(startup, birth: { _ in now.addingTimeInterval(5) }), "PID reuse cannot select an older startup")
    try check(!DiagnosticLogReader.liveGUI(loaded.records.last!, birth: { _ in now }), "newer helper cannot displace GUI session")
    try check(!DiagnosticLogReader.liveGUI(startup, birth: { _ in nil }), "dead PID cannot select historical GUI automatically")
    func rendered(_ arguments: [String]) throws -> [String] {
        var output: [String] = []
        try DiagnosticLogReader.run(arguments, output: { output.append($0) })
        return output
    }
    func events(_ output: [String]) -> [String] {
        output.filter { $0.hasPrefix("1970-") }.map { String($0.split(separator: " ")[2]) }
    }
    let combined = try rendered(["--directory", root.path, "--session", first, "--all", "--since", "1970-01-01T00:16:41Z", "--category", "process", "--level", "info", "--limit", "1"])
    try check(events(combined) == ["process/later"] && combined.last?.hasPrefix("shown=1/1 ") == true, "combined CLI filters assert included/excluded output and count")

    let batch = root.appendingPathComponent("batch")
    try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: false)
    let batchSession = "00000000-0000-0000-0000-000000000001"
    let otherSession = "00000000-0000-0000-0000-000000000002"
    let generationEvents = [["new_a", "new_b"], ["mid_a", "mid_b"], ["startup", "old_b"]]
    func writeBatch(mtimes: [Double]) throws {
        for generation in 0...2 {
            var data = Data()
            for event in generationEvents[generation] { data.append(try line(batchSession, event, at: now)) }
            let file = batch.appendingPathComponent("fixmacos-123-\(batchSession)-\(generation).jsonl")
            try data.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtimes[generation])], ofItemAtPath: file.path)
        }
    }
    try line(otherSession, "foreign", at: now).write(to: batch.appendingPathComponent("fixmacos-123-\(otherSession)-0.jsonl"))
    try line(otherSession, "helper", at: now, role: "watchdog", pid: 456).write(to: batch.appendingPathComponent("fixmacos-456-\(otherSession)-0.jsonl"))
    for mtimes in [[1000.0, 1500.0, 2000.0], [2000.0, 1500.0, 1000.0], [1000.0, 1000.0, 1000.0]] {
        try writeBatch(mtimes: mtimes)
        let records = try DiagnosticLogReader.read(batch.path).records
        try check(records.map(\.event) == ["startup", "old_b", "mid_a", "mid_b", "new_a", "new_b", "foreign", "helper"],
                  "equal timestamps merge by PID/session, generation descending and line order independent of mtimes \(mtimes)")
        let output = try rendered(["--directory", batch.path, "--session", batchSession, "--all", "--limit", "1"])
        try check(events(output) == ["process/new_b"] && output.last?.hasPrefix("shown=1/6 ") == true, "limit one selects newest generation's last equal-timestamp event")
    }

    let filters = root.appendingPathComponent("filters")
    try FileManager.default.createDirectory(at: filters, withIntermediateDirectories: false)
    let rows = [("startup", "process", "info"), ("debug_detail", "bluetooth", "debug"), ("trace_detail", "bluetooth", "trace"),
                ("observation", "bluetooth", "info"), ("ordinary", "bluetooth", "info"), ("warning_detail", "bluetooth", "warning"), ("error_detail", "login", "error")]
    var filterData = Data()
    for (index, row) in rows.enumerated() {
        filterData.append(try line(first, row.0, at: now.addingTimeInterval(Double(index)), category: row.1, level: row.2))
    }
    try filterData.write(to: filters.appendingPathComponent("fixmacos-123-\(first)-0.jsonl"))
    try line(second, "excluded_session", at: now, pid: 456, category: "bluetooth", level: "error").write(to: filters.appendingPathComponent("fixmacos-456-\(second)-0.jsonl"))
    let base = ["--directory", filters.path, "--session", first]
    for (flags, expected) in [
        ([], ["process/startup", "bluetooth/observation", "bluetooth/warning_detail", "login/error_detail"]),
        (["--all"], rows.map { "\($0.1)/\($0.0)" }),
        (["--level", "debug", "--category", "bluetooth"], ["bluetooth/debug_detail", "bluetooth/observation", "bluetooth/ordinary", "bluetooth/warning_detail"]),
        (["--all", "--level", "warning"], ["bluetooth/warning_detail", "login/error_detail"]),
        (["--all", "--category", "bluetooth", "--since", "1970-01-01T00:16:44Z"], ["bluetooth/ordinary", "bluetooth/warning_detail"]),
        (["--category", "bluetooth", "--since", "1970-01-01T00:16:44Z"], ["bluetooth/warning_detail"]),
        (["--all", "--level", "error", "--category", "bluetooth"], [])
    ] {
        try check(events(rendered(base + flags)) == expected, "rendered CLI flags \(flags) include exactly expected session/category/level/since/all events")
    }
    let byPID = try rendered(["--directory", filters.path, "--pid", "123", "--all"])
    try check(events(byPID) == rows.map { "\($0.1)/\($0.0)" }, "explicit PID output excludes other process/session records")

    // More than the global budget must fail rather than pick mutable-mtime winners.
    // Explicit selection still reads every selected generation before merging.
    for index in 0..<25 {
        let session = String(format: "00000000-0000-0000-0000-%012d", index + 100)
        try line(session, "noise", at: now, pid: 999).write(to: batch.appendingPathComponent("fixmacos-999-\(session)-0.jsonl"))
    }
    do { _ = try DiagnosticLogReader.read(batch.path); throw DiagnosticLogReader.failure("silently truncated directory") }
    catch { try check(error.localizedDescription.contains("More than 24"), "over-budget directory fails explicitly without truncating selected sessions") }
    let selectedBatch = try rendered(["--directory", batch.path, "--session", batchSession, "--all"])
    try check(events(selectedBatch) == ["process/startup", "process/old_b", "process/mid_a", "process/mid_b", "process/new_a", "process/new_b"], "session filter precedes file budget and retains all rotations")
    let selectedPID = try rendered(["--directory", batch.path, "--pid", "123", "--all", "--limit", "1"])
    try check(events(selectedPID) == ["process/new_b"], "PID filter precedes file budget without dropping selected generation")
    for args in [["--limit", "201"], ["--level", "invalid"], ["--since", "bad"], ["--pid", "0"], ["--session", first, "--pid", "123"], ["--session", UUID().uuidString, "--directory", root.path], ["--directory", root.appendingPathComponent("missing").path]] {
        do { try DiagnosticLogReader.run(args); throw DiagnosticLogReader.failure("accepted invalid/missing input") }
        catch { try check(!error.localizedDescription.contains("accepted invalid"), "invalid/missing reader input fails explicitly") }
    }
    print("\(checks) diagnostic reader checks passed")
} catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
