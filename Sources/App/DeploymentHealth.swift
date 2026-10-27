import AppKit
import CryptoKit

/// A live main-thread reply, never a cached preference or a helper's startup log.
struct DeploymentHealth: Codable {
    var schema = 1
    var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    var session: String
    var revision: String
    var bundlePath: String
    var timestamp = Date().timeIntervalSince1970
    var blockers: [String]
    var checks: [String: String]
    var configurationHash: String

    static func configurationHash(_ defaults: UserDefaults) -> String {
        let keys = ["ui.widgets.v1", "ui.setup.version", "ui.setup.draft.v1", "links.config",
                    "windows.shortcuts", "windows.auto", "windows.paused", "windows.selected", "windows.exclusions", "windows.layouts",
                    "keepAwake.minutes", "keepAwake.display", "keepAwake.apps", "clipboard.persistence", "clipboard.days", "clipboard.exclusions",
                    "audio.automatic", "audio.output.preferences", "audio.input.preferences", "audio.output.fallback", "audio.input.fallback",
                    "bluetooth.autoEnabled", "bluetooth.autoAddresses", "bluetooth.protectAudio", "bluetooth.protectedAudioAddresses", "bluetooth.switchAudio",
                    "menuBar.compact", "menuBar.hiding", "animations.enabled", "monitors.confirmDisable", "mouse.proposedAcceleration", "mouse.proposedTracking",
                    "arrangement.matchEdges", "quitGuard.enabled", "quitGuard.duration", "spaces.enabled", "spaces.speed"]
            + AppModule.allCases.map { "modules.\($0.rawValue)" }
        func json(_ value: Any) -> Any {
            if let data = value as? Data { return data.base64EncodedString() }
            if let date = value as? Date { return date.timeIntervalSince1970 }
            if let values = value as? [String: Any] { return values.mapValues(json) }
            if let values = value as? [Any] { return values.map(json) }
            return value
        }
        var values: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { values[key] = json(value) } }
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct UpdateSessionPolicy {
    var busy = false
    var keepAwake = false
    var mouseOverride = false
    var displayRecovery = false
    var volatileClipboard = false
    var clipboardRecording = false
    var unsavedRules = false
    var transientUI = false
    var browserChange = false
    var audioOverride = false
    var unsavedWidgets = false

    var blockers: [String] {
        [(busy, "Wait for the current operation to finish."),
         (keepAwake, "End the Keep awake session or paused app-rule session before updating."),
         (mouseOverride, "Restore the Mouse override before updating."),
         (displayRecovery, "Restore pending display changes before updating."),
         (volatileClipboard, "Clipboard has memory-only history. Save it using its retention setting, or clear it before updating."),
         (clipboardRecording, "Pause Clipboard recording before updating."),
         (unsavedRules, "Save or discard the Links draft before updating."),
         (transientUI, "Close the display editor or settings sheet and reveal hidden menu-bar icons before updating."),
         (browserChange, "Wait for the default-browser change to finish."),
         (audioOverride, "A manual Audio override is active. Resolve it with Resume in Audio before updating."),
         (unsavedWidgets, "Finish or cancel widget editing before updating.")].compactMap { $0.0 ? $0.1 : nil }
    }
}

/// Same-user request/reply, addressed to one GUI PID, with a fresh nonce per call.
/// Replies contain status categories and a configuration digest, never user content.
final class DeploymentEndpoint: NSObject {
    static let request = Notification.Name("io.github.jakub-tucek.better-macos.deployment.request")
    static let response = Notification.Name("io.github.jakub-tucek.better-macos.deployment.response")
    private let snapshot: () -> DeploymentHealth
    private let prepareQuit: () -> [String]
    private let terminate: () -> Void

    init(snapshot: @escaping () -> DeploymentHealth, prepareQuit: @escaping () -> [String], terminate: @escaping () -> Void) {
        self.snapshot = snapshot; self.prepareQuit = prepareQuit; self.terminate = terminate
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)), name: Self.request, object: nil)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func receive(_ notification: Notification) {
        guard let nonce = notification.object as? String, UUID(uuidString: nonce) != nil,
              let expires = notification.userInfo?["expires"] as? String, let deadline = Double(expires),
              deadline >= Date().timeIntervalSince1970, deadline <= Date().timeIntervalSince1970 + 15,
              let pid = notification.userInfo?["pid"] as? String, pid == String(ProcessInfo.processInfo.processIdentifier),
              let action = notification.userInfo?["action"] as? String, ["status", "quit"].contains(action) else { return }
        let blockers = action == "quit" ? prepareQuit() : nil
        var report = snapshot()
        if let blockers { report.blockers = blockers }
        guard let data = try? JSONEncoder().encode(report), let text = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(Self.response, object: nonce, userInfo: ["report": text], deliverImmediately: true)
        if action == "quit", report.blockers.isEmpty { DispatchQueue.main.async { self.terminate() } }
    }
}

final class DeploymentClient: NSObject {
    private var report: DeploymentHealth?
    private let nonce = UUID().uuidString
    @objc private func receive(_ notification: Notification) {
        guard notification.object as? String == nonce, let text = notification.userInfo?["report"] as? String,
              let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(DeploymentHealth.self, from: data) else { return }
        report = value
    }

    static func run(path: String, quit: Bool) throws {
        let bundle = URL(fileURLWithPath: path).standardizedFileURL
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy != .prohibited && $0.bundleURL?.standardizedFileURL == bundle
        }
        guard apps.count <= 1 else { throw ToggleError(message: "Multiple GUI instances are running; close the extra instance before updating.") }
        guard let app = apps.first else { print("null"); return }
        let client = DeploymentClient()
        let center = DistributedNotificationCenter.default()
        center.addObserver(client, selector: #selector(receive(_:)), name: DeploymentEndpoint.response, object: client.nonce)
        defer { center.removeObserver(client) }
        center.postNotificationName(DeploymentEndpoint.request, object: client.nonce,
                                    userInfo: ["pid": String(app.processIdentifier), "action": quit ? "quit" : "status", "expires": String(Date().addingTimeInterval(10).timeIntervalSince1970)], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(10)
        while client.report == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let report = client.report, report.schema == 1, report.pid == app.processIdentifier,
              URL(fileURLWithPath: report.bundlePath).standardizedFileURL == bundle,
              abs(Date().timeIntervalSince1970 - report.timestamp) < 15 else {
            throw ToggleError(message: "No fresh response from the installed GUI. It may be busy or predate guarded deployment.")
        }
        if quit {
            guard report.blockers.isEmpty else { throw ToggleError(message: report.blockers.joined(separator: "\n")) }
            let deadline = Date().addingTimeInterval(40)
            while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            guard app.isTerminated else { throw ToggleError(message: "The host refused or could not finish quitting. The installed bundle was not replaced.") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
