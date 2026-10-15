import Foundation
import Darwin

protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    func set(_ data: Data) { lock.lock(); stored = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Commands run only on a background queue, with argument arrays (never a shell).
struct CommandRunner: CommandRunning {
    var diagnostics: Diagnostics = .shared
    static func timeout(for executable: String, arguments: [String]) -> TimeInterval {
        // A normal Bluetooth page timeout is slightly longer than 15 seconds.
        // Do not kill a legitimate connection just before the OS reports it.
        URL(fileURLWithPath: executable).lastPathComponent == "blueutil" && arguments.first == "--connect" ? 35 : 15
    }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        let started = diagnostics.start(), operation = UUID().uuidString
        let isBluetooth = URL(fileURLWithPath: executable).lastPathComponent == "blueutil"
        let allowed = ["--connect", "--disconnect", "--paired", "--connected", "--power", "--info"]
        let action = isBluetooth ? (arguments.first.flatMap { allowed.contains($0) ? $0 : nil } ?? "other") : "other"
        let category = isBluetooth ? "bluetooth" : "command"
        diagnostics.emit(category, "command_start", operation: operation, fields: ["action": action])
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch {
            diagnostics.emit(category, "command_finish", outcome: "failure", operation: operation, since: started,
                             fields: ["action": action, "failure_class": "launch"])
            throw error
        }
        let stdout = CapturedOutput()
        let stderr = CapturedOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { stdout.set(output.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { stderr.set(errors.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        let timedOut = CapturedOutput()
        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set(Data([1]))
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let seconds = Self.timeout(for: executable, arguments: arguments)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer { timeout.cancel() }
        process.waitUntilExit()
        readers.wait()
        let text = String(decoding: stdout.get(), as: UTF8.self)
        let errorText = String(decoding: stderr.get(), as: UTF8.self)
        diagnostics.emit(category, "command_finish", outcome: process.terminationStatus == 0 ? "success" : "failure",
                         operation: operation, since: started, fields: ["action": action,
                         "exit_code": String(process.terminationStatus), "timed_out": String(!timedOut.get().isEmpty),
                         "stdout_bytes": String(stdout.get().count), "stderr_bytes": String(stderr.get().count),
                         "failure_class": !timedOut.get().isEmpty ? "timeout" : (process.terminationStatus == 0 ? "none" : "exit")])
        guard process.terminationStatus == 0 else {
            let detail = (errorText.isEmpty ? text : errorText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToggleError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (exit \(process.terminationStatus)): \(detail.isEmpty ? "device unavailable or command timed out after \(Int(seconds))s" : detail)")
        }
        return text
    }

    static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin"].map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
