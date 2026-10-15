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
    case monitors, arrangement, bluetooth, audio, spaces, menuBar, quitGuard, keepAwake, windows, clipboard, mouse
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitors: return "Monitor switching"
        case .arrangement: return "Display arrangement"
        case .bluetooth: return "Bluetooth reconnect"
        case .audio: return "Audio"
        case .spaces: return "Animations"
        case .menuBar: return "Menu bar"
        case .quitGuard: return "Hold to quit"
        case .keepAwake: return "Keep awake"
        case .windows: return "Window positions"
        case .clipboard: return "Clipboard"
        case .mouse: return "Mouse"
        }
    }
    var detail: String {
        switch self {
        case .monitors: return "Turn monitors on/off, with recovery and confirmation."
        case .arrangement: return "Drag-to-arrange editor and automatic gap closing."
        case .bluetooth: return "Paired devices, manual connections, and reconnect monitoring."
        case .audio: return "Independent microphone and output selection and preferred routes."
        case .spaces: return "Limit Dock, window, and scrolling animations, with fast desktop switching."
        case .menuBar: return "Compact spacing and hide less-used menu-bar icons."
        case .quitGuard: return "Hold ⌘Q before quitting, with the app name and a countdown."
        case .keepAwake: return "Timed and app-based awake sessions, with optional display wake."
        case .windows: return "Named window layouts with optional reconnect and wake restoration."
        case .clipboard: return "Local history, search, pins, and optional disk retention. Recording starts paused."
        case .mouse: return "Opt-in mouse acceleration and tracking, with runtime restoration."
        }
    }
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
