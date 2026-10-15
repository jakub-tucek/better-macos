import AppKit

/// App-shell adapter: Dashboard bindings and native app selection stay out of
/// KeepAwakeFeature's ownership interface.
final class KeepAwakePresentation {
    struct AppChoice {
        let id: String
        let name: String
    }
    typealias ChooseApps = (@escaping ([AppChoice]) -> Void) -> Void

    private weak var model: DashboardModel?
    private let acceptsActions: () -> Bool
    private let chooseApps: ChooseApps
    var didPublish: (KeepAwakeFeature.State) -> Void = { _ in }

    init(model: DashboardModel, acceptsActions: @escaping () -> Bool, chooseApps: @escaping ChooseApps) {
        self.model = model
        self.acceptsActions = acceptsActions
        self.chooseApps = chooseApps
    }

    func bind(_ feature: KeepAwakeFeature) {
        guard let model else { return }
        model.onKeepAwakeStart = { [weak feature] in feature?.perform(.start) }
        model.onKeepAwakeRetry = { [weak feature] in feature?.perform(.retry) }
        model.onKeepAwakeStop = { [weak feature] in feature?.perform(.stop) }
        model.onKeepAwakeExtend = { [weak feature] in feature?.perform(.extend) }
        model.onKeepAwakeResume = { [weak feature] in feature?.perform(.resumeApps) }
        model.onKeepAwakeRemoveApp = { [weak feature] id in feature?.perform(.setApp(id: id, name: id, selected: false)) }
        model.onKeepAwakeMinutesChanged = { [weak feature] in feature?.perform(.setMinutes($0)) }
        model.onKeepDisplayAwakeChanged = { [weak feature] in feature?.perform(.setDisplay($0)) }
        model.onKeepAwakeAddApp = { [weak self, weak feature] in
            guard let self, self.acceptsActions(), feature != nil else { return }
            self.chooseApps { [weak feature] choices in
                // A modal chooser can return after quit closed admission. Each
                // action rechecks the host predicate inside the feature.
                for app in choices { feature?.perform(.setApp(id: app.id, name: app.name, selected: true)) }
            }
        }
    }

    func publish(_ state: KeepAwakeFeature.State) {
        model?.keepAwakeActive = state.active
        model?.keepAwakeCanStop = state.canStop
        model?.keepAwakeRemaining = state.remaining
        model?.keepAwakeMinutes = state.minutes
        model?.keepAwakeApps = state.apps
        model?.keepAwakeAppNames = state.appNames
        model?.keepAwakeAppsPaused = state.appsPaused
        model?.keepAwakeProtectionFailed = state.protectionFailed
        model?.keepDisplayAwake = state.display
        didPublish(state)
    }

    static func chooseApplications(completion: @escaping ([AppChoice]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose apps that keep the Mac awake"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { completion([]); return }
        completion(panel.urls.compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            return AppChoice(id: id, name: url.deletingPathExtension().lastPathComponent)
        })
    }
}
