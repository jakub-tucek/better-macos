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
