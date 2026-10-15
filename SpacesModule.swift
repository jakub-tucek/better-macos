import AppKit
import ApplicationServices

protocol SpaceIntercepting: AnyObject {
    var isRunning: Bool { get }
    var overrideEnabled: Bool { get set }
    func start()
    func teardown()
}

extension SwipeInterceptor: SpaceIntercepting {}

/// Owns the vendored gesture machinery; UI only knows enable/disable and speed.
final class SpacesModule {
    private let defaults: UserDefaults
    private let engine: GestureSwitchEngine
    private var interceptor: SpaceIntercepting?
    private let makeInterceptor: (GestureSwitchEngine) -> SpaceIntercepting
    private let permissionCheck: () -> Bool
    private let conflictingAppRunning: () -> Bool
    private var observer: NSObjectProtocol?
    var observesSpaceChanges: Bool { observer != nil }

    var hasPermission: Bool { permissionCheck() }
    // Set by the host while its independent watchdog is ready.
    var isAvailable = false
    private(set) var needsStartupRestore = true
    private(set) var isDraining = false
    private var suspensionGeneration = 0
    var onChange: (() -> Void)?
    var savedEnabled: Bool { defaults.bool(forKey: "spaces.enabled") }
    var isEnabled: Bool { interceptor?.isRunning == true && interceptor?.overrideEnabled == true }
    var speed: TransitionSpeed {
        get { TransitionSpeed.from(rawValue: defaults.integer(forKey: "spaces.speed")) }
        set { defaults.set(newValue.rawValue, forKey: "spaces.speed"); engine.setTransitionSpeed(newValue) }
    }

    init(defaults: UserDefaults = .standard, engine: GestureSwitchEngine = GestureSwitchEngine(),
         makeInterceptor: @escaping (GestureSwitchEngine) -> SpaceIntercepting = { SwipeInterceptor(engine: $0) },
         permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         conflictingAppRunning: @escaping () -> Bool = { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.rileycx.strafe" } }) {
        self.defaults = defaults
        self.engine = engine
        self.makeInterceptor = makeInterceptor
        self.permissionCheck = permissionCheck
        self.conflictingAppRunning = conflictingAppRunning
        engine.setTransitionSpeed(speed)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [engine] _ in engine.resetPredictions() }
    }

    func restoreSavedState() throws {
        guard needsStartupRestore, isAvailable, !isDraining else { return }
        needsStartupRestore = false
        if savedEnabled { try setEnabled(true) }
    }

    func requestRestore(enabled: Bool) {
        defaults.set(enabled, forKey: "spaces.enabled")
        needsStartupRestore = true
    }

    /// Setup selects durable intent, not a snapshot of event-tap runtime state.
    /// Off is explicit even when inactive. On is saved without requesting access
    /// or starting interception; the host reconciles it after animation work.
    func installSetupIntent(_ enabled: Bool) throws {
        if !enabled { try setEnabled(false) }
        else if !savedEnabled || !isEnabled { requestRestore(enabled: true) }
    }

    func suspend(completion: @escaping () -> Void = {}) {
        interceptor?.overrideEnabled = false
        interceptor?.teardown()
        interceptor = nil
        suspensionGeneration += 1
        let generation = suspensionGeneration
        isDraining = true
        engine.cancelPendingSwitches { [self] in
            if suspensionGeneration == generation { isDraining = false }
            completion()
            onChange?()
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        needsStartupRestore = false
        if !enabled {
            suspend()
            defaults.set(false, forKey: "spaces.enabled")
            return
        }
        guard isAvailable else {
            throw ToggleError(message: "Space interception is disabled for safety while investigating a system input freeze.")
        }
        guard !isDraining else { throw ToggleError(message: "Wait for the current desktop transition to finish.") }
        guard hasPermission else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw ToggleError(message: "Enable Fix macOS in System Settings → Privacy & Security → Accessibility, then try this switch again. Monitors and Bluetooth work without it.")
        }
        guard !conflictingAppRunning() else {
            throw ToggleError(message: "Quit the standalone strafe app first, so two gesture interceptors do not compete.")
        }
        let interceptor = self.interceptor ?? makeInterceptor(engine)
        interceptor.overrideEnabled = true
        interceptor.start()
        guard interceptor.isRunning else { throw ToggleError(message: "Could not start gesture interception. Recheck Accessibility permission.") }
        self.interceptor = interceptor
        defaults.set(true, forKey: "spaces.enabled")
    }

    func stop(completion: @escaping () -> Void = {}) {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        suspend(completion: completion)
    }
}
