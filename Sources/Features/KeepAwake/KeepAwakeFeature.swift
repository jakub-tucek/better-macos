import Foundation

/// Main-thread ownership of the built-in Keep Awake feature. The host admits
/// choice changes and commits preferences; this module never approves quit.
final class KeepAwakeFeature {
    struct State: Equatable {
        var loaded = false
        var active = false
        var canStop = false
        var remaining: TimeInterval = 0
        var minutes = 30
        var apps: [String: String] = [:]
        var appNames: [String] = []
        var appsPaused = false
        var protectionFailed = false
        var display = false
    }

    enum Action {
        case start, retry, stop, extend, resumeApps
        case setApp(id: String, name: String, selected: Bool)
        case setMinutes(Int)
        case setDisplay(Bool)
    }

    private let makeOwner: () -> KeepAwakeModule
    private let acceptsActions: () -> Bool
    private let publish: (State) -> Void
    private let reportError: (Error) -> Void
    private var owner: KeepAwakeModule?
    private var generation = 0

    init(makeOwner: @escaping () -> KeepAwakeModule, acceptsActions: @escaping () -> Bool,
         publish: @escaping (State) -> Void, reportError: @escaping (Error) -> Void) {
        self.makeOwner = makeOwner
        self.acceptsActions = acceptsActions
        self.publish = publish
        self.reportError = reportError
    }

    var state: State {
        precondition(Thread.isMainThread)
        guard let owner else { return State() }
        return State(loaded: true, active: owner.active, canStop: owner.canStop,
                     remaining: owner.remaining, minutes: owner.selectedMinutes,
                     apps: owner.selectedApps, appNames: owner.activeAppNames,
                     appsPaused: owner.appsPaused, protectionFailed: owner.protectionFailed,
                     display: owner.keepDisplayAwake)
    }

    /// Internal host continuation, not a new action. Disabling follows successful
    /// prepareDisable and choice commit; do not recheck admission here.
    func reconcile(enabled: Bool) {
        precondition(Thread.isMainThread)
        if enabled {
            if owner == nil {
                let module = makeOwner()
                owner = module
                generation += 1
                let current = generation
                module.onChange = { [weak self, weak module] in
                    guard let self, let module, self.owner === module, self.generation == current else { return }
                    self.publish(self.state)
                }
                module.onError = { [weak self, weak module] error in
                    guard let self, let module, self.owner === module, self.generation == current else { return }
                    self.reportError(error)
                }
                module.activate()
            }
        } else {
            generation += 1
            owner?.onChange = nil
            owner?.onError = nil
            owner = nil
        }
        publish(state)
    }

    func perform(_ action: Action) {
        precondition(Thread.isMainThread)
        guard acceptsActions(), let owner else { return }
        do {
            switch action {
            case .start: try owner.start()
            case .retry: try owner.retry()
            case .stop: try owner.stop()
            case .extend: try owner.extend()
            case .resumeApps: try owner.resumeApps()
            case let .setApp(id, name, selected): try owner.setApp(id, name: name, selected: selected)
            // This setter already publishes valid changes, unlike the throwing
            // action path. Invalid values remain entirely inert.
            case .setMinutes(let minutes): owner.selectedMinutes = minutes; return
            case .setDisplay(let enabled): try owner.setKeepDisplayAwake(enabled)
            }
        } catch { reportError(error) }
        publish(state)
    }

    /// The caller has already admitted this choice change. Failure retains and
    /// reactivates the same owner, including failed assertion IDs and retry state.
    func prepareDisable() -> Result<Void, ModuleChoiceFailure> {
        precondition(Thread.isMainThread)
        guard let owner else { return .success(()) }
        do { try owner.deactivate(); return .success(()) }
        catch {
            owner.activate()
            return .failure(ModuleChoiceFailure(detail: error.localizedDescription, message: error.localizedDescription))
        }
    }

    func configureForSetup(minutes: Int, display: Bool, apps: [String: String]) -> FeatureSetupOutcome {
        precondition(Thread.isMainThread)
        guard acceptsActions() else { return .failed("Shutdown in progress.") }
        guard let owner else { return .failed("Feature owner is unavailable. Retry from its Settings group.") }
        do { try owner.configureForSetup(minutes: minutes, display: display, apps: apps) }
        catch { reportError(error); return .failed(error.localizedDescription) }
        publish(state)
        return owner.configurationOutcome
    }

    /// Existing best-effort termination cleanup, not preparation or a quit veto.
    /// Keep the owner (and any failed assertion IDs) until normal destruction.
    func shutdown() {
        precondition(Thread.isMainThread)
        try? owner?.deactivate()
    }
}
