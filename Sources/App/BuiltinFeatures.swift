import Foundation

/// Inert, build-time registration. Presentation lookup never constructs an owner.
struct BuiltinFeatureDefinition {
    let module: AppModule
    let title: String
    let detail: String
    let feature: DashboardTab
    let settings: SettingsGroup
    let settingsOrder: Int
}

struct BuiltinWidgetDefinition {
    let kind: WidgetKind
    let module: AppModule
    let title: String
    let detail: String
}

enum BuiltinFeatures {
    static let definitions: [BuiltinFeatureDefinition] = [
        .init(module: .monitors, title: "Monitor switching", detail: "Turn monitors on/off, with recovery and confirmation.", feature: .monitors, settings: .displays, settingsOrder: 0),
        .init(module: .arrangement, title: "Display arrangement", detail: "Drag-to-arrange editor and automatic gap closing.", feature: .monitors, settings: .displays, settingsOrder: 1),
        .init(module: .bluetooth, title: "Bluetooth reconnect", detail: "Paired devices, manual connections, and reconnect monitoring.", feature: .bluetooth, settings: .sound, settingsOrder: 1),
        .init(module: .audio, title: "Audio", detail: "Independent microphone and output selection and preferred routes.", feature: .audio, settings: .sound, settingsOrder: 0),
        .init(module: .spaces, title: "Animations", detail: "Limit Dock, window, and scrolling animations, with fast desktop switching.", feature: .spaces, settings: .system, settingsOrder: 0),
        .init(module: .menuBar, title: "Menu bar", detail: "Compact spacing and hide less-used menu-bar icons.", feature: .menuBar, settings: .system, settingsOrder: 1),
        .init(module: .quitGuard, title: "Hold to quit", detail: "Hold ⌘Q before quitting, with the app name and a countdown.", feature: .keyboard, settings: .input, settingsOrder: 0),
        .init(module: .keepAwake, title: "Keep awake", detail: "Timed and app-based awake sessions, with optional display wake.", feature: .keepAwake, settings: .system, settingsOrder: 2),
        .init(module: .windows, title: "Window positions", detail: "Keyboard tiling and named layouts with optional reconnect and wake restoration.", feature: .windows, settings: .displays, settingsOrder: 2),
        .init(module: .clipboard, title: "Clipboard", detail: "Local history, search, pins, automatic recording and optional disk retention.", feature: .clipboard, settings: .clipboard, settingsOrder: 0),
        .init(module: .mouse, title: "Mouse", detail: "Opt-in mouse acceleration and tracking, with runtime restoration.", feature: .mouse, settings: .input, settingsOrder: 1),
        .init(module: .links, title: "Links", detail: "Open each web link in the browser or browser profile you choose.", feature: .links, settings: .links, settingsOrder: 0)
    ]

    // Persisted-layout migration / Restore suggested order, independent of enum order.
    static let widgets: [BuiltinWidgetDefinition] = [
        .init(kind: .keepAwake, module: .keepAwake, title: "Keep awake", detail: "Start or stop an idle-sleep prevention session."),
        .init(kind: .displays, module: .monitors, title: "Displays", detail: "Switch monitors, arrange screens, and restore windows."),
        .init(kind: .clipboard, module: .clipboard, title: "Clipboard", detail: "Open private history; copied content is never previewed here."),
        .init(kind: .audio, module: .audio, title: "Audio", detail: "Switch output and microphone without opening Settings."),
        .init(kind: .windows, module: .windows, title: "Window layouts", detail: "Restore named layouts on compatible displays."),
        .init(kind: .bluetooth, module: .bluetooth, title: "Bluetooth", detail: "Connect chosen devices and see reconnect status.")
    ]

    static func definition(for module: AppModule) -> BuiltinFeatureDefinition {
        guard let value = definitions.first(where: { $0.module == module }) else {
            preconditionFailure("Missing built-in feature registration: \(module.rawValue)")
        }
        return value
    }

    static func widget(for kind: WidgetKind) -> BuiltinWidgetDefinition {
        guard let value = widgets.first(where: { $0.kind == kind }) else {
            preconditionFailure("Missing built-in widget registration: \(kind.rawValue)")
        }
        return value
    }

    static func modules(in group: SettingsGroup) -> [AppModule] {
        definitions.filter { $0.settings == group }.sorted { $0.settingsOrder < $1.settingsOrder }.map(\.module)
    }
}
