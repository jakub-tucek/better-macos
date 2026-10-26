import AppKit
import SwiftUI

/// Compile-time contributions. Metadata lookup never constructs feature owners.
protocol FeatureRegistration {
    static var order: Int { get }
    static var definitions: [BuiltinFeatureDefinition] { get }
    static var widgets: [BuiltinWidgetDefinition] { get }
    static var settings: [FeatureSettingsDefinition] { get }
    static var setup: [AppModule: FeatureSetupDescription] { get }
    static var launchArguments: [String: DashboardTab] { get }
    static func makeOwner(_ context: FeatureContext) -> FeatureOwner?
    static func settingsView(model: DashboardModel, feature: DashboardTab, draft: Bool) -> AnyView?
    static func widgetView(model: DashboardModel, entry: WidgetEntry) -> AnyView?
}

extension FeatureRegistration {
    static var widgets: [BuiltinWidgetDefinition] { [] }
    static var settings: [FeatureSettingsDefinition] { [] }
    static var setup: [AppModule: FeatureSetupDescription] { [:] }
    static var launchArguments: [String: DashboardTab] { [:] }
    static func makeOwner(_ context: FeatureContext) -> FeatureOwner? { nil }
    static func settingsView(model: DashboardModel, feature: DashboardTab, draft: Bool) -> AnyView? { nil }
    static func widgetView(model: DashboardModel, entry: WidgetEntry) -> AnyView? { nil }
}

struct FeatureSettingsDefinition {
    let group: SettingsGroup
    let symbol: String
    let summary: String
}

struct FeatureSetupDescription {
    let introduction: String
    let effect: String
    let summary: String
}

struct FeatureContext {
    let preferences: UserDefaults
    let acceptsActions: () -> Bool
}

/// Independent features only. Restoration/drain owners keep their existing typed host paths.
protocol FeatureOwner: AnyObject {
    var module: AppModule { get }
    func reconcile(enabled: Bool)
    func stopFeature()
    var setupOutcome: FeatureSetupOutcome { get }
}

/// Incoming URL delivery remains available during disabled-feature and quit paths.
protocol WebLinkHandling: AnyObject { func route(_ url: URL) }

final class FeatureOwners {
    typealias Factory = (FeatureContext) -> FeatureOwner
    private let owners: [AppModule: FeatureOwner]
    init(context: FeatureContext, overrides: [AppModule: Factory] = [:], registrations: [FeatureRegistration.Type] = BuiltinFeatures.registrations) {
        var values: [AppModule: FeatureOwner] = [:]
        for registration in registrations {
            let ids = registration.definitions.map(\.module)
            let overridden = ids.compactMap { overrides[$0] }
            precondition(overridden.count <= 1, "One independent owner per registration")
            let owner = overridden.first.map { $0(context) } ?? registration.makeOwner(context)
            if let owner {
                precondition(ids.contains(owner.module), "Owner identity must belong to its registration")
                precondition(values[owner.module] == nil, "Duplicate feature owner")
                values[owner.module] = owner
            }
        }
        precondition(values.values.filter { $0 is WebLinkHandling }.count <= 1, "Multiple web link owners")
        owners = values
    }
    func owner<T>(_ module: AppModule, as type: T.Type) -> T? { owners[module] as? T }
    func reconcile(enabled: Set<AppModule>) {
        for module in AppModule.allCases { owners[module]?.reconcile(enabled: enabled.contains(module)) }
    }
    func setupOutcome(for module: AppModule) -> FeatureSetupOutcome? { owners[module]?.setupOutcome }
    func route(_ url: URL) { owners.values.compactMap { $0 as? WebLinkHandling }.first?.route(url) }
    func stop() { for module in AppModule.allCases { owners[module]?.stopFeature() } }
}
