import Foundation
import Darwin

/// Dedicated read-only subprocess. No shell, global runner changes or blocking pipe readers.
struct BluetoothProfilerProcess {
    var executable = "/usr/sbin/system_profiler"
    var arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic", "-timeout", "8"]
    var timeout: TimeInterval = 10
    var outputLimit = 1024 * 1024

    func read(shouldContinue: @escaping () -> Bool) throws -> Data {
        guard shouldContinue() else { throw BluetoothReadIssue.canceled }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        // Foundation owns child reaping, including the rare delayed exit after SIGKILL.
        process.terminationHandler = { _ in }
        do { try process.run() } catch { throw BluetoothReadIssue.launch }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let out = output.fileHandleForReading.fileDescriptor, err = errors.fileHandleForReading.fileDescriptor
        defer { try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
        guard fcntl(out, F_SETFL, O_NONBLOCK) != -1, fcntl(err, F_SETFL, O_NONBLOCK) != -1 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw BluetoothReadIssue.pipeOpen
        }
        let started = ProcessInfo.processInfo.systemUptime
        var data = Data(), bytes = 0, outClosed = false, errClosed = false
        var failure: BluetoothReadIssue?, terminationStarted: TimeInterval?
        var killed = false
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if !shouldContinue() { failure = .canceled }
                else if now - started >= timeout { failure = .timeout }
            }
            if failure != nil {
                if terminationStarted == nil {
                    terminationStarted = now
                    if process.isRunning { process.terminate() }
                }
                if now - (terminationStarted ?? now) >= 0.15, !killed {
                    killed = true
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                // Never wait on EOF from a descendant holding an inherited descriptor.
                if !process.isRunning || now - (terminationStarted ?? now) >= 1 { throw failure ?? .timeout }
            }
            for (fd, isOutput) in [(out, true), (err, false)] {
                if isOutput ? outClosed : errClosed { continue }
                var buffer = [UInt8](repeating: 0, count: 8192)
                // One bounded read per stream per turn; continuous writers cannot starve cancellation.
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    bytes += count
                    if bytes > outputLimit { failure = .outputLimit }
                    else if isOutput { data.append(contentsOf: buffer.prefix(count)) }
                } else if count == 0 {
                    if isOutput { outClosed = true } else { errClosed = true }
                } else if errno != EAGAIN && errno != EINTR {
                    failure = .pipeOpen
                }
            }
            if !process.isRunning, outClosed, errClosed {
                if let failure { throw failure }
                guard process.terminationStatus == 0 else { throw BluetoothReadIssue.exitFailure }
                return data
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

extension BluetoothObservationService {
    static func live() -> BluetoothObservationService {
        BluetoothObservationService { try BluetoothProfilerProcess().read(shouldContinue: $0) }
    }
}
