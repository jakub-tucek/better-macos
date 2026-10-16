import Foundation
import Darwin

/// Numeric/closed diagnostics only, intended for injected fixture evidence.
struct BluetoothProfilerTrace {
    let issue: BluetoothReadIssue?
    let waitStatus: Int32?
    let stdoutEOF: Bool
    let stderrEOF: Bool
    let outputBytes: Int
    let elapsedMS: Int
    let killed: Bool
}

/// Dedicated read-only subprocess. This worker exclusively owns waitpid and its
/// pipe descriptors: EOF, child exit and exit status are independent facts.
struct BluetoothProfilerProcess {
    var executable = "/usr/sbin/system_profiler"
    var arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic", "-timeout", "8"]
    var timeout: TimeInterval = 10
    var outputLimit = 1024 * 1024
    var trace: ((BluetoothProfilerTrace) -> Void)?

    func read(shouldContinue: @escaping () -> Bool) throws -> Data {
        guard shouldContinue() else { throw BluetoothReadIssue.canceled }
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        defer { for fd in output + errors where fd >= 0 { close(fd) } }
        guard pipe(&output) == 0, pipe(&errors) == 0 else { throw BluetoothReadIssue.pipeOpen }
        for index in 0...1 {
            if output[index] < 3 {
                let replacement = fcntl(output[index], F_DUPFD_CLOEXEC, 3)
                guard replacement >= 0 else { throw BluetoothReadIssue.pipeOpen }
                close(output[index]); output[index] = replacement
            }
            if errors[index] < 3 {
                let replacement = fcntl(errors[index], F_DUPFD_CLOEXEC, 3)
                guard replacement >= 0 else { throw BluetoothReadIssue.pipeOpen }
                close(errors[index]); errors[index] = replacement
            }
        }
        for fd in output + errors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw BluetoothReadIssue.pipeOpen }
        }
        for fd in [output[0], errors[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw BluetoothReadIssue.pipeOpen }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw BluetoothReadIssue.launch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw BluetoothReadIssue.launch }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw BluetoothReadIssue.launch }
        guard posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0 else { throw BluetoothReadIssue.launch }
        for fd in output + errors {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw BluetoothReadIssue.launch }
        }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + environment { free(value) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard spawned == 0 else { throw BluetoothReadIssue.launch }
        close(output[1]); output[1] = -1
        close(errors[1]); errors[1] = -1
        let started = ProcessInfo.processInfo.systemUptime
        var data = Data(), bytes = 0, outClosed = false, errClosed = false
        var failure: BluetoothReadIssue?, terminationStarted: TimeInterval?
        var killed = false, exited = false, status: Int32 = 0
        defer {
            // An OS-delayed exit cannot retain pipe readers or the feature worker.
            // Keep explicit reaping ownership without a blocked reaper thread.
            if !exited {
                kill(pid, SIGKILL)
                Self.reapOnExit(pid)
            }
            trace?(BluetoothProfilerTrace(issue: failure, waitStatus: exited ? status : nil,
                                          stdoutEOF: outClosed, stderrEOF: errClosed, outputBytes: bytes,
                                          elapsedMS: Int((ProcessInfo.processInfo.systemUptime - started) * 1000), killed: killed))
        }
        while true {
            if !exited {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { exited = true }
                else if result < 0 && errno != EINTR {
                    // Lost ownership: never signal a PID that another reaper released.
                    exited = true; status = -1; failure = failure ?? .exitFailure
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if !shouldContinue() { failure = .canceled }
                else if now - started >= timeout { failure = .timeout }
            }
            if failure != nil {
                if terminationStarted == nil {
                    terminationStarted = now
                    if !exited { kill(pid, SIGTERM) }
                }
                if now - (terminationStarted ?? now) >= 0.15, !killed {
                    killed = true
                    if !exited { kill(pid, SIGKILL) }
                }
                if exited || now - (terminationStarted ?? now) >= 1 { throw failure ?? .timeout }
            }
            for (fd, isOutput) in [(output[0], true), (errors[0], false)] {
                if isOutput ? outClosed : errClosed { continue }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    bytes += count
                    if bytes > outputLimit { failure = failure ?? .outputLimit }
                    else if isOutput { data.append(contentsOf: buffer.prefix(count)) }
                } else if count == 0 {
                    if isOutput { outClosed = true } else { errClosed = true }
                } else if errno != EAGAIN && errno != EINTR {
                    failure = failure ?? .pipeOpen
                }
            }
            if exited, outClosed, errClosed {
                if let failure { throw failure }
                // Raw wait status zero is the only successful normal exit.
                guard status == 0 else { failure = .exitFailure; throw BluetoothReadIssue.exitFailure }
                return data
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func reapOnExit(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var status: Int32 = 0
            // Exit notification makes this nonblocking collection sufficient.
            _ = waitpid(pid, &status, WNOHANG)
            source.setEventHandler(handler: nil)
            source.cancel()
        }
        source.resume()
    }
}

extension BluetoothObservationService {
    static func live() -> BluetoothObservationService {
        BluetoothObservationService { try BluetoothProfilerProcess().read(shouldContinue: $0) }
    }
}
