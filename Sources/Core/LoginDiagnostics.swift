import Foundation
import ServiceManagement

enum LoginDiagnostics {
    static func status(_ status: LoginStatus) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not_registered"
        case .requiresApproval: return "requires_approval"
        case .notFound: return "not_found"
        case .unknown: return "unknown"
        }
    }
    /// Inject OS effects and status reads; never record localized error payloads.
    static func change(_ enabled: Bool, service: LoginServicing = SystemLoginService(),
                       diagnostics: Diagnostics = .shared) throws {
        let started = diagnostics.start(), operation = UUID().uuidString
        diagnostics.emit("login", "change_requested", operation: operation,
                         fields: ["enabled": String(enabled), "status": status(service.status)])
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            diagnostics.emit("login", "change_finished", outcome: "success", operation: operation, since: started,
                             fields: ["enabled": String(enabled), "status": status(service.status)])
        } catch {
            let failure = error as NSError
            diagnostics.emit("login", "change_finished", outcome: "failure", operation: operation, since: started,
                             fields: ["enabled": String(enabled), "status": status(service.status), "error_code": String(failure.code),
                                      "error_class": failure.domain == SMAppServiceErrorDomain ? "service_management" : "other"])
            throw error
        }
    }
}
