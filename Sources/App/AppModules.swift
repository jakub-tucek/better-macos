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

struct AppModule: RawRepresentable, Hashable, CaseIterable, Identifiable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init?(rawValue: String) { guard Self.allCases.contains(where: { $0.rawValue == rawValue }) else { return nil }; self.rawValue = rawValue }
    static var allCases: [AppModule] { BuiltinFeatures.definitions.map(\.module) }
    static let monitors = AppModule("monitors"), arrangement = AppModule("arrangement"), bluetooth = AppModule("bluetooth"), audio = AppModule("audio")
    static let spaces = AppModule("spaces"), menuBar = AppModule("menuBar"), quitGuard = AppModule("quitGuard"), keepAwake = AppModule("keepAwake")
    static let windows = AppModule("windows"), clipboard = AppModule("clipboard"), mouse = AppModule("mouse")
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
