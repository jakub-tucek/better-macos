import CryptoKit
import Foundation

struct SourceUpdateRun {
    enum Status: Equatable {
        case running(String)
        case installed(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let directory: URL
    var log: URL { directory.appendingPathComponent("Update.log") }
    private var receipt: URL { directory.appendingPathComponent("status") }

    init(directory: URL) {
        self.directory = directory
    }

    init(destination: String) {
        let path = URL(fileURLWithPath: destination).standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Better macOS/Updates/\(key)", isDirectory: true)
    }

    func start(revision: String, script: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try openLock()
        defer { try? lock.close() }
        guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ToggleError(message: "An update is already in progress.")
        }
        try Data().write(to: log, options: .atomic)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        try Data(revision.utf8).write(to: receipt, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = lock
        process.standardOutput = output
        process.standardError = output
        // Keep the lock across GUI quit; the build and its tools receive /dev/null as stdin.
        process.arguments = ["-c", """
            exec 3<&0 </dev/null
            /bin/bash -c "$1" 3<&-
            result=$?
            printf '%s\\n%s\\n' "$2" "$result" > status.pending && /bin/mv -f status.pending status
            """, "better-macos-update", script, revision]
        try process.run()
    }

    func status(installedRevision: String) -> Status? {
        guard let lock = try? openLock() else { return nil }
        defer { try? lock.close() }
        let finished = flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0
        guard let record = try? String(contentsOf: receipt, encoding: .utf8) else { return nil }
        let fields = record.split(separator: "\n")
        guard let target = fields.first, SourceUpdateComparison.isRevision(String(target)) else { return nil }
        let revision = String(target)
        if !finished { return .running(revision) }
        guard fields.count == 2, let outcome = Int(fields[1]) else {
            return .failed("The update was interrupted.")
        }
        if outcome == 0 { return installedRevision == revision ? .installed(revision) : nil }
        return .failed(failureDetails() ?? "See the update log for details.")
    }

    private func openLock() throws -> FileHandle {
        let descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func failureDetails() -> String? {
        guard let output = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? output.close() }
        guard let size = try? output.seekToEnd(), size > 0,
              (try? output.seek(toOffset: size - min(size, 2048))) != nil,
              let data = try? output.read(upToCount: 2048) else { return nil }
        let details = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
        return details.isEmpty ? nil : String(details.suffix(500))
    }
}
