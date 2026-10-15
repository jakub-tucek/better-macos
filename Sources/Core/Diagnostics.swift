import Foundation
import Darwin
import CryptoKit
import Security

/// Only audited operational metadata belongs here. Never pass error descriptions,
/// command arguments/output, clipboard payloads, or third-party identifiers.
struct DiagnosticEvent: Encodable {
    let timestamp: String
    let session: String
    let pid: Int32
    let category: String
    let event: String
    let severity: String
    let outcome: String
    let operation: String
    let durationMS: Double?
    let fields: [String: String]
}

protocol DiagnosticSink { func write(_ line: Data) throws }

/// A filesystem seam lets failure/rotation tests run without the production directory.
protocol DiagnosticFiles {
    func prepare(_ directory: URL) throws
    func size(_ file: URL) throws -> Int
    func append(_ data: Data, to file: URL) throws
    func remove(_ file: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func files(_ directory: URL) throws -> [URL]
    func withLock(_ directory: URL, work: () throws -> Void) throws
}

struct LocalDiagnosticFiles: DiagnosticFiles {
    private let manager = FileManager.default
    func prepare(_ directory: URL) throws {
        // Do not recursively create or chmod broad parent directories.
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch CocoaError.fileWriteFileExists {
            // Another session may already own it, including a concurrent creator.
            // Never accept EEXIST without the type/ownership checks below.
        }
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    func size(_ file: URL) throws -> Int {
        guard manager.fileExists(atPath: file.path) else { return 0 }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteNoPermission) }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
    func append(_ data: Data, to file: URL) throws {
        // O_NOFOLLOW rejects a symlink even if replaced after the size check.
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }
    func remove(_ file: URL) throws {
        if manager.fileExists(atPath: file.path) {
            guard try manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try manager.removeItem(at: file)
        }
    }
    func move(_ source: URL, to destination: URL) throws { try manager.moveItem(at: source, to: destination) }
    func files(_ directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]).filter {
            guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
    }
    func withLock(_ directory: URL, work: () throws -> Void) throws {
        let file = directory.appendingPathComponent(".rotation.lock")
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        // Never stall a feature on another process's logger. A busy lock drops
        // this event; later events retry. No recursive error logging.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        try work()
    }
}

/// Caller serializes writes. Unique process/session filenames avoid cross-process append races.
final class RotatingDiagnosticSink: DiagnosticSink {
    let directory: URL
    let prefix: String
    let limit: Int
    let retainedFiles: Int
    private let files: DiagnosticFiles
    private var prepared = false
    init(directory: URL, session: String, pid: Int32, limit: Int = 512 * 1024,
         retainedFiles: Int = 24, files: DiagnosticFiles = LocalDiagnosticFiles()) {
        self.directory = directory; self.limit = max(1024, limit); self.retainedFiles = max(3, retainedFiles)
        self.files = files
        prefix = "fixmacos-\(pid)-\(session)"
    }
    private func file(_ index: Int) -> URL { directory.appendingPathComponent("\(prefix)-\(index).jsonl") }
    func write(_ line: Data) throws {
        guard line.count <= limit else { return }
        if !prepared { try files.prepare(directory); prepared = true }
        try files.withLock(directory) { try writeLocked(line) }
    }
    private func writeLocked(_ line: Data) throws {
        if try files.size(file(0)) + line.count > limit {
            try files.remove(file(2))
            for index in stride(from: 1, through: 0, by: -1) {
                if try files.size(file(index)) > 0 { try files.move(file(index), to: file(index + 1)) }
            }
        }
        try files.append(line, to: file(0))
        // Own exact filename grammar only. The shared lock serializes retention
        // with helper rotation; global budget may evict old live-session files.
        let owned = try files.files(directory).filter { url in
            url.lastPathComponent.range(of: #"^fixmacos-[0-9]+-[A-Fa-f0-9-]{36}-[012]\.jsonl$"#, options: .regularExpression) != nil
        }
        var excess = owned.count - retainedFiles
        for url in owned where excess > 0 && !url.lastPathComponent.hasPrefix(prefix + "-") {
            try files.remove(url); excess -= 1
        }
    }
}

final class Diagnostics {
    // Tests do not initialize the production sink: main.swift explicitly installs it.
    static var shared = Diagnostics()
    private let queue = DispatchQueue(label: "Fix macOS diagnostics")
    private let sink: DiagnosticSink?
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    let session: String
    private let pid: Int32
    init(sink: DiagnosticSink? = nil, session: String = UUID().uuidString, pid: Int32 = getpid(),
         now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink; self.session = session; self.pid = pid; self.now = now; self.uptime = uptime
    }
    func start() -> TimeInterval { uptime() }
    func emit(_ category: String, _ event: String, outcome: String = "observed", operation: String = UUID().uuidString,
              since: TimeInterval? = nil, fields: [String: String] = [:]) {
        guard let sink else { return }
        queue.sync {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let record = DiagnosticEvent(timestamp: formatter.string(from: now()), session: session, pid: pid,
                                         category: category, event: event, severity: outcome == "failure" ? "error" : "info",
                                         outcome: outcome, operation: operation,
                                         durationMS: since.map { max(0, uptime() - $0) * 1000 }, fields: fields)
            // Logging failure must never veto feature work or recursively log itself.
            if var data = try? JSONEncoder().encode(record) { data.append(10); try? sink.write(data) }
        }
    }
    static func identity(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func install(revision: String, sourceState: String) {
        let session = UUID().uuidString
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fix macOS", isDirectory: true)
        let logger = Diagnostics(sink: RotatingDiagnosticSink(directory: directory, session: session, pid: getpid()), session: session)
        shared = logger
        // Read once at process entry, not later during a possibly replaced bundle.
        let bundle = Bundle.main
        let path = bundle.bundleURL.path
        var fields = ["compiled_base_revision": revision, "compiled_source_state": sourceState, "bundle_path_hash": identity(path),
                      "entry_uptime_seconds": String(ProcessInfo.processInfo.systemUptime),
                      "process_role": ProcessInfo.processInfo.arguments.contains("--watchdog") ? "watchdog" : (ProcessInfo.processInfo.arguments.count > 1 ? "command_or_helper" : "gui"),
                      "bundle_location": path.contains("/build/") ? "build" : (path.contains("/Applications/") ? "applications" : "other"),
                      "executable_path_hash": identity(ProcessInfo.processInfo.arguments.first ?? ""),
                      "bundle_revision_observed_at_entry": bundle.object(forInfoDictionaryKey: "FixMacOSRevision") as? String ?? "absent",
                      "version_observed_at_entry": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "absent",
                      "preferences_domain": bundle.bundleIdentifier ?? "absent",
                      "clipboard_storage_identity": identity(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fix macOS/Clipboard/history.json").path)]
        var code: SecCode?
        let signingStatus = SecCodeCopySelf([], &code)
        fields["signing_self_status"] = String(signingStatus)
        if let code {
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
               let info = information as? [String: Any] {
                if let hash = info[kSecCodeInfoUnique as String] as? Data {
                    fields["signing_code_directory_hash_observed_at_entry"] = hash.map { String(format: "%02x", $0) }.joined()
                }
                if let flags = info[kSecCodeInfoFlags as String] as? NSNumber { fields["signing_flags_observed_at_entry"] = flags.stringValue }
            }
        }
        for key in ["clipboard.persistence", "clipboard.days"] {
            fields[key + "_present"] = String(UserDefaults.standard.object(forKey: key) != nil)
        }
        logger.emit("process", "startup", fields: fields)
    }
}
