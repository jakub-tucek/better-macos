import Foundation

// Compile-only domain seams. The production Bluetooth/Audio owners, command
// runner and journal compile unchanged. Neither display nor app composition runs.
struct ToggleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FeatureSetupOutcome {
    case applied(String), pendingAccess(String), pendingHardware(String), failed(String)
}

struct DiscardPermissionDiagnostics: DiagnosticSink {
    func write(_ line: Data) throws {}
}

final class PermissionDiscoveryDiagnostics: DiagnosticSink {
    private let lock = NSLock()
    private var lines: [Data] = []
    func write(_ line: Data) throws { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    var latestDiscovery: [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return lines.reversed().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .first { $0["event"] as? String == "discovery_state_changed" }?["fields"] as? [String: String]
    }
}
