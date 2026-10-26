import AppKit

func runBuiltinCatalogTests() {
    let mainMenu = AppDelegate.makeMainMenu()
    let shortcuts = mainMenu.items.flatMap { $0.submenu?.items ?? [] }.map { "\($0.keyEquivalent):\($0.action.map(NSStringFromSelector) ?? "")" }
    expect(shortcuts.contains("a:selectAll:") && shortcuts.contains("v:paste:") && shortcuts.contains("c:copy:") && shortcuts.contains("x:cut:") && shortcuts.contains("z:undo:"), "Native editing shortcuts remain available")
    expect(!shortcuts.contains { $0.hasPrefix("q:") }, "Native editing menu never bypasses host quit approval")
    let legacy = ["monitors", "arrangement", "bluetooth", "audio", "spaces", "menuBar", "quitGuard", "keepAwake", "windows", "clipboard", "mouse"]
    expect(Array(AppModule.allCases.prefix(legacy.count)).map(\.rawValue) == legacy, "Legacy persisted feature IDs and application order remain stable")
    expect(Set(AppModule.allCases).count == AppModule.allCases.count, "Feature IDs are unique")
    expect(Set(SettingsGroup.allCases).count == SettingsGroup.allCases.count, "Settings identities are unique")
    expect(Set(SetupDraft.featureOrder) == Set(AppModule.allCases) && SetupDraft.featureOrder.count == AppModule.allCases.count, "Setup visits every feature exactly once")
    for definition in BuiltinFeatures.definitions {
        expect(SettingsGroup.allCases.contains(definition.settings) && definition.settings.modules.contains(definition.module), "Feature has a reachable Settings destination")
        expect(AppModule(rawValue: definition.module.rawValue) == definition.module && !definition.title.isEmpty && !definition.detail.isEmpty, "Registered feature identity round-trips and has presentation text")
    }
    let orders = BuiltinFeatures.registrations.map { $0.order }
    expect(Set(orders).count == orders.count, "Registration order keys are unique")
    let flags = BuiltinFeatures.registrations.flatMap { $0.launchArguments.keys }
    expect(Set(flags).count == flags.count, "Registered launch flags are unique")
    for registration in BuiltinFeatures.registrations {
        for definition in registration.definitions {
            expect(registration.setup[definition.module] != nil && !definition.symbol.isEmpty, "Feature-local registration includes setup copy and symbol")
        }
        for (flag, feature) in registration.launchArguments {
            expect(UILaunchRoute.launch(arguments: [flag]) == .settings(SettingsGroup.forFeature(feature)), "Registered launch argument reaches feature Settings")
        }
    }
    expect(Set(BuiltinFeatures.widgets.map(\.kind)) == Set(WidgetKind.allCases) && Set(WidgetKind.allCases).count == WidgetKind.allCases.count, "Every widget is registered exactly once")
    expect(Array(WidgetKind.allCases.prefix(6)).map(\.rawValue) == ["keepAwake", "audio", "displays", "windows", "clipboard", "bluetooth"], "Legacy widget persistence identities remain stable")
    expect(Array(WidgetLayout.suggested(for: Set(AppModule.allCases)).entries.prefix(3)).map(\.kind) == ["keepAwake", "displays", "clipboard"], "Core quick actions retain suggested priority")
    for kind in WidgetKind.allCases {
        expect(AppModule.allCases.contains(kind.module), "Widget has a registered owner")
        let encoded = try? JSONEncoder().encode(kind)
        expect(encoded.flatMap { String(data: $0, encoding: .utf8) } == "\"\(kind.rawValue)\"", "Widget Codable representation remains a plain persisted string")
    }
    expect(AppModule(rawValue: "future") == nil && WidgetKind(rawValue: "future") == nil, "Unknown feature and widget IDs remain unknown")
    expect(WidgetLayout.suggested(for: [.arrangement]).entries.isEmpty, "Arrangement does not imply the monitor widget")
}
