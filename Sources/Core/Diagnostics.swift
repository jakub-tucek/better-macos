import Foundation
import Darwin
import CryptoKit
import Security

enum DiagnosticLevel: String, CaseIterable {
    case trace, debug, info, warning, error
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func parse(_ value: String?) -> Self? {
        guard let value, value.utf8.count <= 32 else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "all" ? .trace : Self(rawValue: normalized)
    }
}

/// Resolve only the logging key, never enumerate preferences. Invalid values are
/// reported as booleans, never copied into logs. The environment wins when valid.
struct DiagnosticConfiguration {
    static let preferenceKey = "diagnostics.level"
    let level: DiagnosticLevel
    let source: String
    var invalidEnvironment = false
    var invalidPreference = false
    static func resolve(environment: String?, preference: String?) -> Self {
        let env = DiagnosticLevel.parse(environment), saved = DiagnosticLevel.parse(preference)
        return Self(level: env ?? saved ?? .info, source: env != nil ? "environment" : (saved != nil ? "preference" : "default"),
                    invalidEnvironment: environment != nil && env == nil, invalidPreference: preference != nil && saved == nil)
    }
    var fields: [String: String] {
        ["effective_log_level": level.rawValue, "log_level_source": source,
         "invalid_log_level_environment": String(invalidEnvironment), "invalid_log_level_preference": String(invalidPreference)]
    }
}

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

/// Construct paths/backends on the drain worker too, not the safety entry caller.
private final class DeferredDiagnosticSink: DiagnosticSink {
    private let makeSink: () -> DiagnosticSink
    private var sink: DiagnosticSink?
    init(_ makeSink: @escaping () -> DiagnosticSink) { self.makeSink = makeSink }
    func write(_ line: Data) throws {
        let current = sink ?? makeSink()
        sink = current
        try current.write(line)
    }
}

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

/// One prepared sink owns one directory descriptor until deinit. After validation,
/// no operation resolves that directory's pathname again (even enumeration).
final class LocalDiagnosticFiles: DiagnosticFiles {
    private var directoryFD: Int32 = -1
    private var root: URL?
    deinit { if directoryFD >= 0 { close(directoryFD) } }
    private var denied: CocoaError { CocoaError(.fileWriteNoPermission) }
    func prepare(_ directory: URL) throws {
        if directoryFD >= 0 { guard root == directory else { throw denied }; return }
        // mkdir is deliberately non-recursive. EEXIST is accepted only after
        // opening the directory without following its final component.
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw denied }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw denied }
        var accepted = false
        defer { if !accepted { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), fchmod(descriptor, 0o700) == 0 else { throw denied }
        root = directory; directoryFD = descriptor; accepted = true
    }
    private func name(_ file: URL) throws -> String {
        guard directoryFD >= 0, file.deletingLastPathComponent().path == root?.path else { throw denied }
        let name = file.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw denied }
        return name
    }
    private func info(_ name: String) throws -> stat? {
        var result = stat()
        if fstatat(directoryFD, name, &result, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw denied
        }
        return result
    }
    private func regular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1
    }
    private func openFile(_ name: String, flags: Int32) throws -> Int32 {
        var descriptor: Int32 = -1
        // Bounded retry for interrupted/concurrent creation. A removed directory
        // still fails closed; retries never resolve the original pathname.
        for _ in 0..<3 {
            descriptor = openat(directoryFD, name, flags | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            if descriptor >= 0 || (errno != ENOENT && errno != EINTR) { break }
        }
        guard descriptor >= 0 else { throw denied }
        var information = stat()
        guard fstat(descriptor, &information) == 0, regular(information), fchmod(descriptor, 0o600) == 0 else {
            close(descriptor); throw denied
        }
        return descriptor
    }
    func size(_ file: URL) throws -> Int {
        guard let information = try info(name(file)) else { return 0 }
        guard regular(information) else { throw denied }
        return Int(information.st_size)
    }
    func append(_ data: Data, to file: URL) throws {
        let descriptor = try openFile(name(file), flags: O_WRONLY | O_APPEND)
        defer { close(descriptor) }
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
        let name = try name(file)
        guard let information = try info(name) else { return }
        guard regular(information), unlinkat(directoryFD, name, 0) == 0 else { throw denied }
    }
    func move(_ source: URL, to destination: URL) throws {
        let source = try name(source), destination = try name(destination)
        guard let information = try info(source), regular(information) else { throw denied }
        if let existing = try info(destination) { guard regular(existing) else { throw denied } }
        guard renameat(directoryFD, source, directoryFD, destination) == 0 else { throw denied }
    }
    func files(_ directory: URL) throws -> [URL] {
        guard directory == root else { throw denied }
        // openat(".") obtains an independent enumeration offset, without resolving
        // a replaced path or sharing dup()'s directory stream offset.
        let descriptor = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw denied }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw denied }
        defer { closedir(stream) }
        var found: [(String, timespec)] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != "..", let information = try info(name), regular(information) else { continue }
            found.append((name, information.st_mtimespec))
        }
        return found.sorted {
            if $0.1.tv_sec != $1.1.tv_sec { return $0.1.tv_sec < $1.1.tv_sec }
            return $0.1.tv_nsec < $1.1.tv_nsec
        }.map { directory.appendingPathComponent($0.0, isDirectory: false) }
    }
    func withLock(_ directory: URL, work: () throws -> Void) throws {
        guard directory == root else { throw denied }
        let descriptor = try openFile(".rotation.lock", flags: O_WRONLY)
        defer { close(descriptor) }
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
    private func file(_ index: Int) -> URL { directory.appendingPathComponent("\(prefix)-\(index).jsonl", isDirectory: false) }
    func write(_ line: Data) throws {
        guard line.count <= limit else { return }
        if !prepared { try files.prepare(directory); prepared = true }
        try files.withLock(directory) { try writeLocked(line) }
    }
    private func writeLocked(_ line: Data) throws {
        // Count, eviction, rotation and creation share the directory lock. Never
        // append a new file first and hope a subsequent cleanup can make room.
        var owned = try files.files(directory).filter { url in
            url.lastPathComponent.range(of: #"^fixmacos-[0-9]+-[A-Fa-f0-9-]{36}-[012]\.jsonl$"#, options: .regularExpression) != nil
        }
        let currentSize = try files.size(file(0))
        let rotating = currentSize > limit - line.count
        if rotating {
            // Removing the oldest own generation is part of rotation, not an
            // eviction fallback. If it cannot be removed, do not overwrite it.
            try files.remove(file(2))
            owned.removeAll { $0 == file(2) }
        }
        let createsCurrent = rotating || !owned.contains(file(0))
        var needed = max(0, owned.count + (createsCurrent ? 1 : 0) - retainedFiles)
        for url in owned where needed > 0 && !url.lastPathComponent.hasPrefix(prefix + "-") {
            do { try files.remove(url); needed -= 1 }
            catch { continue } // Immutable/failed candidates do not starve later ones.
        }
        // An already over-budget, undeletable directory cannot be repaired here.
        // Drop without appending, creating or renaming another generation.
        guard needed == 0 else { return }
        if rotating {
            if owned.contains(file(1)) { try files.move(file(1), to: file(2)) }
            try files.move(file(0), to: file(1))
        }
        try files.append(line, to: file(0))
    }
}

final class Diagnostics {
    // Tests do not initialize the production sink: main.swift explicitly installs it.
    static var shared = Diagnostics()
    private let queue = DispatchQueue(label: "Fix macOS diagnostics", qos: .utility)
    private let admission = NSCondition()
    private struct Pending {
        let date: Date
        let category: String
        let event: String
        let outcome: String
        let operation: String
        let durationMS: Double?
        let fields: [String: String]
        let level: DiagnosticLevel
    }
    private var pending: [Pending] = []
    private var running = false
    private var outstanding = 0
    private var dropped = 0
    private let capacity: Int
    private let startupMetadata: (() -> [String: String])?
    private let loadConfiguration: (() -> DiagnosticConfiguration)?
    private var configuration: DiagnosticConfiguration
    private var configurationLoaded: Bool
    private let sink: DiagnosticSink?
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    let session: String
    private let pid: Int32
    init(sink: DiagnosticSink? = nil, session: String = UUID().uuidString, pid: Int32 = getpid(),
         now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         capacity: Int = 128, startupMetadata: (() -> [String: String])? = nil,
         minimumLevel: DiagnosticLevel = .info, loadConfiguration: (() -> DiagnosticConfiguration)? = nil) {
        self.sink = sink; self.session = session; self.pid = pid; self.now = now; self.uptime = uptime
        self.capacity = max(1, min(128, capacity)); self.startupMetadata = startupMetadata
        self.loadConfiguration = loadConfiguration
        configuration = DiagnosticConfiguration(level: minimumLevel, source: "injected")
        configurationLoaded = loadConfiguration == nil
    }
    func start() -> TimeInterval { uptime() }
    func emit(_ category: String, _ event: String, outcome: String = "observed", operation: String = UUID().uuidString,
              since: TimeInterval? = nil, level: DiagnosticLevel? = nil, fields: [String: String] = [:]) {
        guard sink != nil else { return }
        let severity = level ?? (outcome == "failure" ? .error : .info)
        // Bound payload size as well as event count BEFORE retaining or scheduling.
        // No filesystem, encoder or arbitrary closure runs under admission.
        guard fields.count <= 64, [category, event, outcome, operation].allSatisfy({ $0.utf8.count <= 128 }),
              fields.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 1024 }),
              fields.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16 * 1024 else { return }
        let item = Pending(date: now(), category: category, event: event, outcome: outcome, operation: operation,
                           durationMS: since.map { max(0, uptime() - $0) * 1000 }, fields: fields, level: severity)
        admission.lock()
        // Until worker-side configuration completes, bounded admission accepts all
        // levels. Startup always explains the threshold, even at warning/error.
        guard !configurationLoaded || shouldDeliver(item) else { admission.unlock(); return }
        guard outstanding < capacity else { dropped = min(Int.max - 1, dropped) + 1; admission.unlock(); return }
        pending.append(item); outstanding += 1
        if !running {
            running = true
            // At most one drain task exists, not one dispatch closure per event.
            queue.async { self.drain() }
        }
        admission.unlock()
    }
    private func shouldDeliver(_ item: Pending) -> Bool {
        (item.category == "process" && item.event == "startup") || item.level.rank >= configuration.level.rank
    }
    private func drain() {
        if let loadConfiguration {
            admission.lock(); let needsConfiguration = !configurationLoaded; admission.unlock()
            if needsConfiguration {
                let loaded = loadConfiguration() // Preference I/O never runs on emit's caller.
                admission.lock(); configuration = loaded; configurationLoaded = true; admission.unlock()
            }
        }
        while true {
            admission.lock()
            guard !pending.isEmpty else {
                running = false; admission.broadcast(); admission.unlock(); return
            }
            let item = pending.removeFirst()
            admission.unlock()
            // A continuously busy drain must not accumulate Foundation autoreleases.
            autoreleasepool {
                guard shouldDeliver(item) else { return }
                var fields = item.fields
                if item.category == "process", item.event == "startup" {
                    fields.merge(configuration.fields) { _, actual in actual }
                    if let startupMetadata { fields.merge(startupMetadata()) { original, _ in original } }
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let record = DiagnosticEvent(timestamp: formatter.string(from: item.date), session: session, pid: pid,
                                             category: item.category, event: item.event, severity: item.level.rawValue,
                                             outcome: item.outcome, operation: item.operation, durationMS: item.durationMS, fields: fields)
                // Logging failure must never veto feature work or recursively log itself.
                if var data = try? JSONEncoder().encode(record) { data.append(10); try? sink?.write(data) }
            }
            admission.lock(); outstanding -= 1; admission.broadcast(); admission.unlock()
        }
    }
    /// Tests only. Production entry/exit/recovery NEVER waits for the writer.
    func flushForTesting(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        admission.lock(); defer { admission.unlock() }
        while outstanding > 0 { if !admission.wait(until: deadline) { return outstanding == 0 } }
        return true
    }
    var deliveryStateForTesting: (outstanding: Int, dropped: Int) {
        admission.lock(); defer { admission.unlock() }; return (outstanding, dropped)
    }
    static func identity(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func install(revision: String, sourceState: String) {
        let session = UUID().uuidString
        let sink = DeferredDiagnosticSink {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fix macOS", isDirectory: true)
            return RotatingDiagnosticSink(directory: directory, session: session, pid: getpid())
        }
        let logger = Diagnostics(sink: sink, session: session,
                                 startupMetadata: { startupMetadata(revision: revision, sourceState: sourceState) },
                                 loadConfiguration: {
                                     DiagnosticConfiguration.resolve(environment: ProcessInfo.processInfo.environment["MAC_UTILS_LOG_LEVEL"],
                                                                     preference: UserDefaults.standard.string(forKey: DiagnosticConfiguration.preferenceKey))
                                 })
        shared = logger
        logger.emit("process", "startup", fields: ["compiled_base_revision": revision, "compiled_source_state": sourceState,
                    "entry_uptime_seconds": String(ProcessInfo.processInfo.systemUptime)])
    }
    static func processRole(arguments: [String]) -> String {
        if arguments.contains("--bluetooth-readonly-probe") { return "gui" }
        if arguments.contains("--watchdog") { return "watchdog" }
        return arguments.count > 1 ? "command_or_helper" : "gui"
    }

    private static func startupMetadata(revision: String, sourceState: String) -> [String: String] {
        // Bundle/signature/prefs I/O belongs to the worker, never safety entry.
        // These observations are NOT evidence of the loaded image's identity.
        let bundle = Bundle.main
        let path = bundle.bundleURL.path
        var fields = ["compiled_base_revision": revision, "compiled_source_state": sourceState, "bundle_path_hash": identity(path),
                      "metadata_capture": "asynchronous_not_loaded_image",
                       "process_role": processRole(arguments: ProcessInfo.processInfo.arguments),
                      "bundle_location": path.contains("/build/") ? "build" : (path.contains("/Applications/") ? "applications" : "other"),
                      "executable_path_hash": identity(ProcessInfo.processInfo.arguments.first ?? ""),
                       "bundle_revision_observed_on_worker": bundle.object(forInfoDictionaryKey: "FixMacOSRevision") as? String ?? "absent",
                       "version_observed_on_worker": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "absent",
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
                    fields["signing_code_directory_hash_observed_on_worker"] = hash.map { String(format: "%02x", $0) }.joined()
                }
                if let flags = info[kSecCodeInfoFlags as String] as? NSNumber { fields["signing_flags_observed_on_worker"] = flags.stringValue }
            }
        }
        for key in ["clipboard.persistence", "clipboard.days"] {
            fields[key + "_present"] = String(UserDefaults.standard.object(forKey: key) != nil)
        }
        return fields
    }
}
