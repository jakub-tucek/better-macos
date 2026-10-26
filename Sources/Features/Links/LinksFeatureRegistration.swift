import SwiftUI

extension AppModule { static let links = AppModule("links") }
extension DashboardTab { static let links = DashboardTab("Links") }
extension SettingsGroup { static let links = SettingsGroup("Links") }

enum LinksFeatureRegistration: FeatureRegistration {
    static let order = 110
    static let definitions = [BuiltinFeatureDefinition(module: .links, title: "Links", detail: "Open each web link in the browser or browser profile you choose.", feature: .links, settings: .links, settingsOrder: 0, symbol: "arrow.triangle.branch")]
    static let settings = [FeatureSettingsDefinition(group: .links, symbol: "arrow.triangle.branch", summary: "Send each web link to the right browser or profile.")]
    static let setup: [AppModule: FeatureSetupDescription] = [.links: .init(
        introduction: "Open work links in your work browser profile and everything else in your personal one. Rules match a domain, text in the link, or a wildcard pattern.",
        effect: "Rules apply only after you make Better macOS your default browser in Settings. Turning Links off hands web links back to your fallback browser.",
        summary: "Configure link rules and your default browser in Links settings after setup.")]
    static let launchArguments: [String: DashboardTab] = ["--show-links": .links]
    static func makeOwner(_ context: FeatureContext) -> FeatureOwner? {
        let owner = LinksModule(defaults: context.preferences)
        owner.acceptsActions = context.acceptsActions
        return owner
    }
    static func settingsView(model: DashboardModel, feature: DashboardTab, draft: Bool) -> AnyView? {
        guard feature == .links else { return nil }
        if draft { return AnyView(Text("Add rules and make Better macOS your default browser in Links settings after setup. Setup never changes your default browser.")) }
        guard model.enabledModules.contains(.links), let owner = model.featureOwners?.owner(.links, as: LinksModule.self) else { return AnyView(Text("Links is off.")) }
        return AnyView(LinksSettingsView(module: owner))
    }
}

extension LinksModule: FeatureOwner, WebLinkHandling {
    var module: AppModule { .links }
    func reconcile(enabled: Bool) { setActive(enabled) }
    func stopFeature() { setActive(false) }
    var setupOutcome: FeatureSetupOutcome {
        .applied(isDefaultBrowser ? "Rules apply to new links." : "Make Better macOS your default browser in Links settings to route links.")
    }
}
