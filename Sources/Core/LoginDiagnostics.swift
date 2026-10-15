import Foundation
import ServiceManagement

enum LoginDiagnostics {
    static func status() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not_registered"
        case .requiresApproval: return "requires_approval"
        case .notFound: return "not_found"
        @unknown default: return "unknown"
        }
    }
    /// Inject OS effects and status reads; never record localized error payloads.
    static func change(_ enabled: Bool, diagnostics: Diagnostics = .shared,
                       readStatus: () -> String = status,
                       apply: (Bool) throws -> Void = { enabled in
                           if enabled { try SMAppService.mainApp.register() }
                           else { try SMAppService.mainApp.unregister() }
                       }) throws {
        let started = diagnostics.start(), operation = UUID().uuidString
        diagnostics.emit("login", "change_requested", operation: operation,
                         fields: ["enabled": String(enabled), "status": readStatus()])
        do {
            try apply(enabled)
            diagnostics.emit("login", "change_finished", outcome: "success", operation: operation, since: started,
                             fields: ["enabled": String(enabled), "status": readStatus()])
        } catch {
            let failure = error as NSError
            diagnostics.emit("login", "change_finished", outcome: "failure", operation: operation, since: started,
                             fields: ["enabled": String(enabled), "status": readStatus(), "error_code": String(failure.code),
                                      "error_class": failure.domain == SMAppServiceErrorDomain ? "service_management" : "other"])
            throw error
        }
    }
}
