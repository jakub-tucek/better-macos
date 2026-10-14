import Foundation

enum AppModule: String, CaseIterable, Identifiable {
    case monitors, arrangement, bluetooth, spaces
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitors: return "Monitor switching"
        case .arrangement: return "Display arrangement"
        case .bluetooth: return "Bluetooth reconnect"
        case .spaces: return "Animations"
        }
    }
    var detail: String {
        switch self {
        case .monitors: return "Turn monitors on/off, with recovery and confirmation."
        case .arrangement: return "Drag-to-arrange editor and automatic gap closing."
        case .bluetooth: return "Paired devices, manual connections, and reconnect monitoring."
        case .spaces: return "Limit Dock, window, and scrolling animations, with fast desktop switching."
        }
    }
}

final class ModuleSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var enabled: Set<AppModule> {
        Set(AppModule.allCases.filter { defaults.object(forKey: "modules.\($0.rawValue)") == nil || defaults.bool(forKey: "modules.\($0.rawValue)") })
    }
    var needsDisplays: Bool { !enabled.isDisjoint(with: [.monitors, .arrangement]) }
    func set(_ module: AppModule, enabled: Bool) { defaults.set(enabled, forKey: "modules.\(module.rawValue)") }
}
