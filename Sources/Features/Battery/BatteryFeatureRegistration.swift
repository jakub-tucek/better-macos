import SwiftUI

extension AppModule { static let battery = AppModule("battery") }
extension DashboardTab { static let battery = DashboardTab("Battery") }
extension SettingsGroup { static let battery = SettingsGroup("Battery") }
extension WidgetKind { static let battery = WidgetKind("battery") }

enum BatteryFeatureRegistration: FeatureRegistration {
    static let order = 120
    static let definitions = [BuiltinFeatureDefinition(module: .battery, title: "Battery", detail: "Read-only power flow, charge, battery condition, cycles and temperature.", feature: .battery, settings: .battery, settingsOrder: 0, symbol: "battery.100percent")]
    static let widgets = [BuiltinWidgetDefinition(kind: .battery, module: .battery, title: "Battery", detail: "See charge and power source; expand for battery details.", suggested: false)]
    static let settings = [FeatureSettingsDefinition(group: .battery, symbol: "battery.100percent", summary: "Live power flow and battery details. Read-only.")]
    static let setup: [AppModule: FeatureSetupDescription] = [.battery: .init(
        introduction: "Check your MacBook’s charge, power source, battery condition, cycle count and temperature from the menu bar.",
        effect: "Read-only monitoring. Charging stays under macOS control. Macs without a built-in battery show an empty state; unsupported readings stay unavailable.",
        summary: "Read-only battery monitoring; no charging or power-setting changes.")]
    static let launchArguments: [String: DashboardTab] = ["--show-battery": .battery]
    static func makeOwner(_ context: FeatureContext) -> FeatureOwner? { BatteryModule() }
    static func settingsView(model: DashboardModel, feature: DashboardTab, draft: Bool) -> AnyView? {
        guard feature == .battery else { return nil }
        if draft { return AnyView(Text("After Finish, see live power flow and battery details in Battery settings or its widget. No extra permissions or charging changes.")) }
        guard model.enabledModules.contains(.battery), let owner = model.featureOwners?.owner(.battery, as: BatteryModule.self) else { return AnyView(Text("Battery is off.")) }
        return AnyView(BatteryOwnerView(owner: owner, widget: false, expanded: true))
    }
    static func widgetView(model: DashboardModel, entry: WidgetEntry) -> AnyView? {
        guard entry.known == .battery, let owner = model.featureOwners?.owner(.battery, as: BatteryModule.self) else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            BatteryOwnerView(owner: owner, widget: true, expanded: entry.expanded)
            AppActionRow(title: "Battery details", symbol: "arrow.up.right", action: { model.onOpenSettings(.battery) })
        })
    }
}

private struct BatteryOwnerView: View {
    @ObservedObject var owner: BatteryModule
    let widget: Bool
    let expanded: Bool
    var body: some View {
        if widget { BatteryStatusView(snapshot: owner.snapshot, expanded: expanded) }
        else { BatteryDetailsView(snapshot: owner.snapshot) }
    }
}

extension BatteryModule: FeatureOwner {
    var module: AppModule { .battery }
    func reconcile(enabled: Bool) { if enabled { start() } else { stop() } }
    func stopFeature() { stop() }
    var setupOutcome: FeatureSetupOutcome {
        snapshot.availability == .available ? .applied("Battery monitoring active. Charging stays under macOS control.") : .pendingHardware(snapshot.status)
    }
}
