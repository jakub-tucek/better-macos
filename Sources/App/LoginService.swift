import ServiceManagement

/// Registration intent and permission are separate: pending approval is not eligible to launch.
enum LoginStatus: Equatable {
    case enabled, notRegistered, requiresApproval, notFound, unknown

    var requested: Bool { self == .enabled || self == .requiresApproval }

    var needsAttention: Bool { self == .requiresApproval || self == .notFound || self == .unknown }

    var message: String {
        switch self {
        case .enabled: return "Enabled in macOS Login Items."
        case .notRegistered: return "Not registered to launch at login."
        case .requiresApproval: return "Approval required. Allow Fix macOS in macOS Login Items settings to finish enabling launch at login."
        case .notFound: return "macOS could not find this login item. Try enabling it again; if it still fails, check this app’s installation and signature."
        case .unknown: return "macOS returned an unknown login-item status. Check Login Items settings."
        }
    }
}

protocol LoginServicing {
    var status: LoginStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

struct SystemLoginService: LoginServicing {
    var status: LoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
