import Foundation
import Darwin

private func safetyPreferences(_ domain: String) -> UserDefaults {
    // macOS returns nil for a suite named after the current app's own bundle.
    // A CLI fixture has no bundle ID, so it must explicitly name the suite.
    if Bundle.main.bundleIdentifier == domain { return .standard }
    return UserDefaults(suiteName: domain) ?? .standard
}

struct WatchdogSession: Codable {
    let parentPID: Int32
    let token: String
    let timeout: TimeInterval
    let executable: String
    let preferencesDomain: String
}

enum WatchdogPolicy {
    static func shouldStop(parentIsAlive: Bool, now: TimeInterval, heartbeat: TimeInterval, timeout: TimeInterval) -> Bool {
        parentIsAlive && now - heartbeat > timeout
    }
}

/// Runs in a separate process: no AppKit, graphics queries, input interception,
/// or automatic system restart. It can terminate only its own immediate parent.
enum SafetyWatchdog {
    static func run(directory: URL) -> Int32 {
        do {
            let session = try JSONDecoder().decode(WatchdogSession.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
            guard session.parentPID == getppid(), session.parentPID > 1, session.timeout >= 0.5,
                  URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path == session.executable else { return 2 }
            let defaults = safetyPreferences(session.preferencesDomain)
            try Data(session.token.utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
            while getppid() == session.parentPID {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) { return 0 }
                let text = try? String(contentsOf: directory.appendingPathComponent("heartbeat"), encoding: .utf8)
                let heartbeat = text.flatMap(Double.init) ?? 0
                if WatchdogPolicy.shouldStop(parentIsAlive: true, now: ProcessInfo.processInfo.systemUptime,
                                             heartbeat: heartbeat, timeout: session.timeout) {
                    defaults.set("UI heartbeat stopped; the watchdog terminated Fix macOS.", forKey: "safety.lastIncident")
                    defaults.set(false, forKey: "spaces.enabled")
                    try Data("UI heartbeat expired".utf8).write(to: directory.appendingPathComponent("tripped"), options: .atomic)
                    // Re-check parentage immediately before signaling. PID reuse
                    // after the original parent exits cannot target another app.
                    guard getppid() == session.parentPID else { return 0 }
                    kill(session.parentPID, SIGTERM)
                    Thread.sleep(forTimeInterval: 1)
                    if getppid() == session.parentPID { kill(session.parentPID, SIGKILL) }
                    // Do not restart the app, Dock, WindowServer, or the Mac.
                    // Recovery is attempted only for explicitly app-disabled
                    // displays, and that child is independently time-limited.
                    if let data = defaults.data(forKey: "displayRecords"),
                       let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       records.contains(where: { $0["disabledByApp"] as? Bool == true }) {
                        let recovery = Process()
                        recovery.executableURL = URL(fileURLWithPath: session.executable)
                        recovery.arguments = ["--restore"]
                        try recovery.run()
                        let deadline = ProcessInfo.processInfo.systemUptime + 8
                        while recovery.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.1) }
                        if recovery.isRunning { recovery.terminate() }
                        Thread.sleep(forTimeInterval: 0.5)
                        if recovery.isRunning { kill(recovery.processIdentifier, SIGKILL) }
                    }
                    return 0
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            return 0
        } catch { return 1 }
    }
}

final class SafetySupervisor {
    private let defaults: UserDefaults
    private let domain: String
    private let timeout: TimeInterval
    private let root: URL
    private var process: Process?
    private var directory: URL?
    private var timer: Timer?
    private var startupTime: TimeInterval = 0
    private(set) var isReady = false
    var onStatusChanged: ((String) -> Void)?

    init(domain: String = "io.github.jakub-tucek.mac-utils", timeout: TimeInterval = 8, root: URL? = nil) {
        self.domain = domain
        defaults = safetyPreferences(domain)
        self.timeout = timeout
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mac Utils/Safety", isDirectory: true)
    }

    func start() throws {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let token = UUID().uuidString
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let session = WatchdogSession(parentPID: getpid(), token: token, timeout: timeout,
                                      executable: executable, preferencesDomain: domain)
        try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        try writeHeartbeat()
        let previousSessionUnclean = defaults.bool(forKey: "safety.sessionActive")
        defaults.set(true, forKey: "safety.sessionActive")
        if previousSessionUnclean && defaults.string(forKey: "safety.lastIncident") == nil {
            defaults.set("Previous session did not close cleanly; private system controls remain paused.", forKey: "safety.lastIncident")
        }
        startupTime = ProcessInfo.processInfo.systemUptime
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--watchdog", directory.path]
        try process.run()
        self.process = process
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick(expectedToken: token) }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        onStatusChanged?("Starting recovery watchdog…")
    }

    private func writeHeartbeat() throws {
        guard let directory else { return }
        try Data(String(ProcessInfo.processInfo.systemUptime).utf8)
            .write(to: directory.appendingPathComponent("heartbeat"), options: .atomic)
    }

    private func tick(expectedToken: String) {
        do { try writeHeartbeat() } catch {
            isReady = false
            onStatusChanged?("Watchdog heartbeat failed; keep system controls paused")
            return
        }
        guard process?.isRunning == true, let directory else {
            isReady = false
            onStatusChanged?("Watchdog unavailable; system controls remain paused")
            return
        }
        let token = try? String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)
        if token == expectedToken && !isReady {
            isReady = true
            onStatusChanged?("Recovery watchdog active · \(Int(timeout.rounded(.up)))s hang limit")
        } else if token != expectedToken && ProcessInfo.processInfo.systemUptime - startupTime > 3 {
            onStatusChanged?("Watchdog did not become ready; system controls remain paused")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let directory { try? Data().write(to: directory.appendingPathComponent("stop"), options: .atomic) }
        process?.terminate()
        defaults.set(false, forKey: "safety.sessionActive")
        isReady = false
    }
}
