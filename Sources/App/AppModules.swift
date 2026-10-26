import Foundation

enum FeatureSetupOutcome: Equatable {
    case applied(String)
    case pendingAccess(String)
    case pendingHardware(String)
    case failed(String)

    var description: String {
        switch self {
        case .applied(let detail): return "applied. \(detail)"
        case .pendingAccess(let detail): return "pending access. \(detail)"
        case .pendingHardware(let detail): return "pending hardware/readiness. \(detail)"
        case .failed(let detail): return "failed. \(detail)"
        }
    }
}

enum AppModule: String, CaseIterable, Identifiable {
    case monitors, arrangement, bluetooth, audio, spaces, menuBar, quitGuard, keepAwake, windows, clipboard, mouse, links, battery
    var id: String { rawValue }
    var title: String { BuiltinFeatures.definition(for: self).title }
    var detail: String { BuiltinFeatures.definition(for: self).detail }
}

final class ModuleSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var enabled: Set<AppModule> {
        Set(AppModule.allCases.filter { defaults.object(forKey: "modules.\($0.rawValue)") == nil || defaults.bool(forKey: "modules.\($0.rawValue)") })
    }
    var needsDisplays: Bool { !enabled.isDisjoint(with: [.monitors, .arrangement, .windows]) }
    func set(_ module: AppModule, enabled: Bool) { defaults.set(enabled, forKey: "modules.\(module.rawValue)") }
}
