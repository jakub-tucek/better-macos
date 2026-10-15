import Foundation

/// Owns only the system preference keys changed by the animation preset.
/// The durable snapshot also permits recovery after a partial write or app exit.
final class AnimationPreferences {
    struct Setting {
        let domain: String
        let key: String
        let value: Any
        var id: String { "\(domain)/\(key)" }
    }
    static let settings: [Setting] = [
        Setting(domain: "com.apple.dock", key: "autohide-delay", value: 0.0),
        Setting(domain: "com.apple.dock", key: "autohide-time-modifier", value: 0.0),
        Setting(domain: "com.apple.dock", key: "magnification", value: false),
        Setting(domain: "com.apple.dock", key: "mineffect", value: "scale"),
        Setting(domain: "com.apple.dock", key: "launchanim", value: false),
        Setting(domain: "com.apple.dock", key: "no-bouncing", value: true),
        Setting(domain: "com.apple.finder", key: "DisableAllAnimations", value: true),
        Setting(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", value: false),
        Setting(domain: "NSGlobalDomain", key: "NSWindowResizeTime", value: 0.001),
        Setting(domain: "NSGlobalDomain", key: "NSScrollAnimationEnabled", value: false),
        Setting(domain: "com.apple.WindowManager", key: "DisableTilingAnimations", value: true)
    ]
    private let defaults: UserDefaults
    private let read: (Setting) -> Any?
    private let write: (Setting, Any?) throws -> Void
    var enabled: Bool { defaults.bool(forKey: "animations.enabled") }
    var recoveryRequired: Bool {
        defaults.bool(forKey: "animations.recoveryRequired") ||
        (!enabled && defaults.data(forKey: "animations.originals") != nil)
    }
    var needsUpdate: Bool {
        guard enabled, let snapshot = try? loadSnapshot() else { return enabled }
        return Self.settings.contains { snapshot[$0.id] == nil }
    }

    init(defaults: UserDefaults = .standard,
         read: @escaping (Setting) -> Any? = AnimationPreferences.readSystem,
         write: @escaping (Setting, Any?) throws -> Void = AnimationPreferences.writeSystem) {
        self.defaults = defaults
        self.read = read
        self.write = write
    }

    private static func domain(_ setting: Setting) -> CFString {
        setting.domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : setting.domain as CFString
    }

    static func readSystem(_ setting: Setting) -> Any? {
        CFPreferencesCopyValue(setting.key as CFString, domain(setting), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func writeSystem(_ setting: Setting, _ value: Any?) throws {
        CFPreferencesSetValue(setting.key as CFString, value as CFPropertyList?, domain(setting), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain(setting), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ToggleError(message: "Could not save animation preference: \(setting.key)")
        }
    }

    func setEnabled(_ enabled: Bool, preserveChoice: Bool = false) throws {
        if recoveryRequired { try recoverPendingRestore() }
        let backupKey = "animations.originals"
        if enabled {
            var snapshot = try loadSnapshot()
            // A newer preset may add keys. Never replace an earlier original value.
            for setting in Self.settings where snapshot[setting.id] == nil {
                    snapshot[setting.id] = read(setting).map { ["value": $0] } ?? [:]
            }
            let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
            defaults.set(data, forKey: backupKey)
            defaults.set(true, forKey: "animations.recoveryRequired")
            guard defaults.synchronize() else { throw ToggleError(message: "Could not save original animation settings.") }
            do {
                for setting in Self.settings { try write(setting, setting.value) }
            } catch {
                do { try recoverPendingRestore() }
                catch let recoveryError {
                    throw ToggleError(message: "Animation changes failed: \(error.localizedDescription). Restoring originals also failed: \(recoveryError.localizedDescription). Retry Restore original settings.")
                }
                throw error
            }
        } else {
            defaults.set(true, forKey: "animations.recoveryRequired")
            guard defaults.synchronize() else { throw ToggleError(message: "Could not record pending animation restoration.") }
            try restore()
        }
        if !preserveChoice { defaults.set(enabled, forKey: "animations.enabled") }
        defaults.set(false, forKey: "animations.recoveryRequired")
        defaults.synchronize()
    }

    /// Recovery is driven by the durable transaction marker, not the UI choice.
    /// Runs at startup even if the preset or its parent module is disabled.
    func recoverPendingRestore() throws {
        guard recoveryRequired else { return }
        defaults.set(true, forKey: "animations.recoveryRequired")
        guard defaults.synchronize() else { throw ToggleError(message: "Could not record animation recovery.") }
        try restore()
        defaults.set(false, forKey: "animations.enabled")
        defaults.set(false, forKey: "animations.recoveryRequired")
        defaults.synchronize()
    }

    private func loadSnapshot() throws -> [String: [String: Any]] {
        guard let data = defaults.data(forKey: "animations.originals") else { return [:] }
        guard let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            throw ToggleError(message: "The original animation settings could not be read.")
        }
        return snapshot
    }

    private func restore() throws {
        let snapshot = try loadSnapshot()
        // Older presets never changed newer keys, so leave those keys alone.
        for setting in Self.settings where snapshot[setting.id] != nil {
            try write(setting, snapshot[setting.id]?["value"])
        }
        defaults.removeObject(forKey: "animations.originals")
    }
}
