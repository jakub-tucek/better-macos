import AppKit
import ApplicationServices

/// Owns the vendored gesture machinery; UI only knows enable/disable and speed.
final class SpacesModule {
    private let defaults = UserDefaults.standard
    private let engine = GestureSwitchEngine()
    private var interceptor: SwipeInterceptor?
    private var observer: NSObjectProtocol?

    var hasPermission: Bool { AXIsProcessTrusted() }
    // Set by the host while its independent watchdog is ready. Never auto-start.
    var isAvailable = false
    var isEnabled: Bool { interceptor?.isRunning == true && interceptor?.overrideEnabled == true }
    var speed: TransitionSpeed {
        get { TransitionSpeed.from(rawValue: defaults.integer(forKey: "spaces.speed")) }
        set { defaults.set(newValue.rawValue, forKey: "spaces.speed"); engine.setTransitionSpeed(newValue) }
    }

    init() {
        engine.setTransitionSpeed(speed)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [engine] _ in engine.resetPredictions() }
        defaults.set(false, forKey: "spaces.enabled")
    }

    func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            interceptor?.overrideEnabled = false
            interceptor?.teardown()
            interceptor = nil
            defaults.set(false, forKey: "spaces.enabled")
            return
        }
        guard isAvailable else {
            throw ToggleError(message: "Space interception is disabled for safety while investigating a system input freeze.")
        }
        guard hasPermission else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw ToggleError(message: "Enable fix-mac-os in System Settings → Privacy & Security → Accessibility, then try this switch again. Monitors and Bluetooth work without it.")
        }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.rileycx.strafe" }) else {
            throw ToggleError(message: "Quit the standalone strafe app first, so two gesture interceptors do not compete.")
        }
        let interceptor = self.interceptor ?? SwipeInterceptor(engine: engine)
        interceptor.overrideEnabled = true
        interceptor.start()
        guard interceptor.isRunning else { throw ToggleError(message: "Could not start gesture interception. Recheck Accessibility permission.") }
        self.interceptor = interceptor
        defaults.set(true, forKey: "spaces.enabled")
    }

    func stop() {
        interceptor?.overrideEnabled = false
        interceptor?.teardown()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
