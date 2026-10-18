import Foundation
import Darwin

// Read-only, local JSONL viewer. No app launch, defaults writes or device calls.
struct DiagnosticLogReader {
    struct Record {
        let timestamp: Date
        let object: [String: Any]
        var session: String { object["session"] as? String ?? "" }
        var pid: Int32 { (object["pid"] as? NSNumber)?.int32Value ?? 0 }
        var category: String { object["category"] as? String ?? "" }
        var event: String { object["event"] as? String ?? "" }
        var fields: [String: String] { object["fields"] as? [String: String] ?? [:] }
        var level: String { object["severity"] as? String ?? "info" }
    }
    static let levels = ["trace", "debug", "info", "warning", "error"]
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func read(_ directory: String) throws -> (records: [Record], skipped: Int) {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Log directory unavailable") }
        defer { close(fd) }
        var directoryInfo = stat()
        guard fstat(fd, &directoryInfo) == 0, directoryInfo.st_uid == getuid() else { throw failure("Log directory not owned by this user") }
        let enumeration = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard enumeration >= 0 else { throw failure("Cannot enumerate logs") }
        guard let stream = fdopendir(enumeration) else { close(enumeration); throw failure("Cannot enumerate logs") }
        defer { closedir(stream) }
        var files: [(String, Int)] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.range(of: #"^fixmacos-[0-9]+-[A-Fa-f0-9-]{36}-[012]\.jsonl$"#, options: .regularExpression) != nil else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, valid(info) else { continue }
            files.append((name, info.st_mtimespec.tv_sec))
        }
        var records: [Record] = [], skipped = 0
        // Select the newest bounded set, then read oldest first. For equal mtimes
        // the filename tie-break reads -2/-1/-0 in generation order; stable date
        // sorting below must not invert events sharing a millisecond at rotation.
        for (name, _) in files.sorted(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }).prefix(24).reversed() {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            var info = stat()
            guard fstat(file, &info) == 0, valid(info), let data = try? handle.read(upToCount: 512 * 1024) else { continue }
            let pieces = name.dropFirst("fixmacos-".count)
            let expectedPID = pieces.prefix(while: { $0 != "-" })
            let expectedSession = pieces.dropFirst(expectedPID.count + 1).prefix(36)
            // A partial trailing record is deliberately ignored.
            let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
            for line in lines where !line.isEmpty {
                guard line.count <= 64 * 1024,
                      let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let text = object["timestamp"] as? String, let timestamp = date(text),
                      object["session"] as? String == String(expectedSession),
                      (object["pid"] as? NSNumber)?.stringValue == String(expectedPID),
                      object["category"] is String, object["event"] is String,
                      levels.contains(object["severity"] as? String ?? "") else { skipped += 1; continue }
                records.append(Record(timestamp: timestamp, object: object))
            }
        }
        return (records.sorted { $0.timestamp < $1.timestamp }, skipped)
    }
    private static func valid(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_size <= 512 * 1024
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    /// Compare both executable and birth time. kill(pid, 0) alone accepts reused PIDs.
    static func liveGUI(_ startup: Record, birth: (Int32) -> Date?) -> Bool {
        guard startup.category == "process", startup.event == "startup", startup.fields["process_role"] == "gui",
              let born = birth(startup.pid) else { return false }
        return (0..<5).contains(startup.timestamp.timeIntervalSince(born))
    }
    static func processBirth(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart=", "-o", "comm="]
        process.environment = ["LC_ALL": "C", "TZ": "UTC"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, text.count > 24,
              URL(fileURLWithPath: String(text.dropFirst(24)).trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent == "fix-mac-os" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: String(text.prefix(24)))
    }
    static func run(_ arguments: [String]) throws {
        var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fix macOS").path
        var session: String?, pid: Int32?, since: Date?, category: String?, minimum: String?
        var all = false, limit = 60, index = 0
        while index < arguments.count {
            let arg = arguments[index]; index += 1
            if arg == "--all" { all = true; continue }
            if arg == "--help" {
                print("Usage: bash scripts/dev logs [--all] [--session UUID | --pid PID] [--since ISO8601] [--category NAME] [--level trace|debug|info|warning|error] [--limit 1..200] [--directory PATH]")
                return
            }
            guard index < arguments.count else { throw failure("Missing option value") }
            let value = arguments[index]; index += 1
            switch arg {
            case "--directory": directory = value
            case "--session":
                guard UUID(uuidString: value) != nil else { throw failure("Invalid session UUID") }; session = value
            case "--pid":
                guard let parsed = Int32(value), parsed > 0 else { throw failure("Invalid PID") }; pid = parsed
            case "--since":
                guard let parsed = date(value) else { throw failure("Invalid ISO8601 timestamp") }; since = parsed
            case "--category": category = value
            case "--level":
                guard levels.contains(value) else { throw failure("Invalid level") }; minimum = value
            case "--limit":
                guard let parsed = Int(value), (1...200).contains(parsed) else { throw failure("Limit must be 1..200") }; limit = parsed
            default: throw failure("Unknown option")
            }
        }
        guard session == nil || pid == nil else { throw failure("Choose session or PID, not both") }
        let loaded = try read(directory)
        let startups = loaded.records.filter { $0.category == "process" && $0.event == "startup" }
        if session == nil {
            if let pid { session = startups.last(where: { $0.pid == pid })?.session }
            else { session = startups.last(where: { liveGUI($0, birth: processBirth) })?.session }
        }
        guard let session else { throw failure("No verified live GUI startup in retained logs. Use --session UUID for a historical/helper run, or --pid PID. Nothing was launched.") }
        let selected = loaded.records.filter { $0.session.caseInsensitiveCompare(session) == .orderedSame }
        guard !selected.isEmpty else { throw failure("Session not found in retained logs") }
        let startup = selected.first(where: { $0.category == "process" && $0.event == "startup" })
        print("session=\(session) pid=\(selected[0].pid) level=\(startup?.fields["effective_log_level"] ?? "unknown") source=\(startup?.fields["log_level_source"] ?? "unknown") retained=\(selected.count) malformed_skipped=\(loaded.skipped)")
        let stateEvents = ["startup", "discovery_state_changed", "observation", "manual_action_finished", "quit_vetoed"]
        let filtered = selected.filter {
            (since == nil || $0.timestamp >= since!) && (category == nil || $0.category == category) &&
                (minimum == nil || levels.firstIndex(of: $0.level)! >= levels.firstIndex(of: minimum!)!) &&
                (all || minimum != nil || ["warning", "error"].contains($0.level) || stateEvents.contains($0.event))
        }
        for record in filtered.suffix(limit) {
            let object = record.object
            let fields = record.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("\(object["timestamp"] ?? "") \(record.level) \(record.category)/\(record.event) \(object["outcome"] ?? "") op=\(object["operation"] ?? "") ms=\(object["durationMS"] ?? "-") \(fields)")
        }
        print("shown=\(min(limit, filtered.count))/\(filtered.count) (use --all --limit 200 for verbose retained timeline)")
    }
}

#if !DIAGNOSTICS_READER_TESTS
@main enum DiagnosticLogCommand {
    static func main() {
        do { try DiagnosticLogReader.run(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("diagnostics: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
#endif
