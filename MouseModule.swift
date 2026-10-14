import Foundation

/// A capability is a backend guarantee, never inferred from the OS version or
/// the presence of a preference key. No live backend is qualified yet.
protocol MouseSettingsBackend {
    var identifier: String { get }
    var available: Bool { get }
    func read() throws -> MouseOriginalSettings
    func apply(acceleration: Bool, speed: Double) throws
    func restore(_ original: MouseOriginalSettings) throws
}

enum MouseSettingValue: Codable, Equatable {
    case absent, boolean(Bool), number(Double)
}

struct MouseOriginalSettings: Codable, Equatable {
    var acceleration: MouseSettingValue
    var speed: MouseSettingValue
}

struct MouseRecovery: Codable {
    let backend: String
    let original: MouseOriginalSettings
}

protocol MouseRecoveryStore {
    func load() throws -> MouseRecovery?
    /// Persist before returning for process-crash recovery. This contract does
    /// not promise power-loss durability; qualify that before adding a live writer.
    func save(_ recovery: MouseRecovery) throws
    func clear() throws
}

final class MouseFileRecoveryStore: MouseRecoveryStore {
    private let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> MouseRecovery? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MouseRecovery.self, from: Data(contentsOf: url))
    }
    func save(_ recovery: MouseRecovery) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recovery).write(to: url, options: .atomic)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// One host owner calls this synchronously on the main thread.
final class MouseModule {
    static let scrollLimitation = "Unavailable: public scroll events do not reliably identify the physical device. Continuous/discrete flags are not proof of a mouse. All scrolling passes through unchanged; no event tap is installed."
    static let unavailable = NSError(domain: "MouseControls", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Mouse controls require a verified mouse-only backend."])
    private let backend: MouseSettingsBackend
    private let recovery: MouseRecoveryStore
    private enum State { case idle, active, recoveryRequired }
    private var state = State.idle
    var active: Bool { state == .active }
    private(set) var hasSessionChanges = false
    var available: Bool { backend.available }

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fix macOS", isDirectory: true)
        self.init(backend: SystemMouseBackend(), recovery: MouseFileRecoveryStore(url: directory.appendingPathComponent("mouse-recovery.json")))
    }

    init(backend: MouseSettingsBackend, recovery: MouseRecoveryStore) {
        self.backend = backend
        self.recovery = recovery
    }

    func apply(acceleration: Bool, speed: Double) throws {
        guard available, speed.isFinite, (0.1...3).contains(speed) else { throw Self.unavailable }
        guard state != .recoveryRequired else { throw Self.unavailable }
        let pending: MouseRecovery?
        do { pending = try recovery.load() }
        catch { state = .recoveryRequired; throw error }
        if hasSessionChanges && (pending == nil || pending?.backend != backend.identifier) {
            state = .recoveryRequired
            throw Self.unavailable
        }
        // A pending journal after relaunch is recovery-only, never a new baseline.
        guard pending == nil || active else {
            throw NSError(domain: "MouseControls", code: 2, userInfo: [NSLocalizedDescriptionKey: "Restore the previous mouse settings before applying new changes."])
        }
        if pending == nil {
            try recovery.save(MouseRecovery(backend: backend.identifier, original: backend.read()))
        }
        do {
            hasSessionChanges = true // A throwing backend may already have changed one key.
            try backend.apply(acceleration: acceleration, speed: speed)
            state = .active
        } catch {
            let applyError = error
            do { try stop() }
            catch {
                throw NSError(domain: "MouseControls", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Mouse change failed: \(applyError.localizedDescription). Restoration also failed: \(error.localizedDescription). Recovery is retained; retry Restore."])
            }
            throw applyError
        }
    }

    /// Called on disable, exit and startup. Failed restores retain the journal.
    func stop() throws {
        state = .recoveryRequired
        guard let pending = try recovery.load() else {
            guard !hasSessionChanges else {
                throw NSError(domain: "MouseControls", code: 4, userInfo: [NSLocalizedDescriptionKey: "The recovery journal is missing for this session's mouse changes."])
            }
            state = .idle
            return
        }
        guard pending.backend == backend.identifier, available else { throw Self.unavailable }
        try backend.restore(pending.original)
        try recovery.clear()
        hasSessionChanges = false
        state = .idle
    }
}

/// Shared host policy for startup, module toggles, retry and termination. Tests
/// exercise this exact owner without starting AppKit or other modules.
final class MouseLifecycle {
    private let settings: ModuleSettings
    private let makeModule: () -> MouseModule
    private(set) var module: MouseModule?
    private(set) var recoveryRequired = false
    private(set) var errorMessage: String?
    var onChange: () -> Void = {}

    init(settings: ModuleSettings, makeModule: @escaping () -> MouseModule = { MouseModule() }) {
        self.settings = settings
        self.makeModule = makeModule
    }

    func start() {
        restore()
        reconcile()
    }

    func reconcile() {
        if settings.enabled.contains(.mouse) {
            if module == nil { module = makeModule() }
        } else if module?.hasSessionChanges != true { module = nil }
        onChange()
    }

    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            restore()
            guard module?.hasSessionChanges != true else { return false }
        }
        settings.set(.mouse, enabled: enabled)
        reconcile()
        return true
    }

    func restore() {
        do {
            try (module ?? makeModule()).stop()
            recoveryRequired = false
            errorMessage = nil
        } catch {
            recoveryRequired = true
            errorMessage = error.localizedDescription
            if module?.hasSessionChanges != true {
                errorMessage = "Mouse recovery data could not be restored by this build: \(error.localizedDescription) The journal is retained. You can disable Mouse or quit normally."
            }
        }
        onChange()
    }

    func prepareToQuit() -> Bool {
        restore()
        // Historical/corrupt metadata must not prevent other modules' cleanup
        // or trap this build in the app when it cannot perform recovery.
        return module?.hasSessionChanges != true
    }

    func apply(acceleration: Bool, speed: Double) {
        guard let module else { return }
        do { try module.apply(acceleration: acceleration, speed: speed); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        onChange()
    }

    func capability() -> String? {
        do { _ = try SystemMouseBackend().read(); return nil }
        catch { return error.localizedDescription }
    }
}

/// Policy seam for a future device-attributed stream. A CGEvent alone must
/// always be classified unknown; timestamp correlation is not attribution.
enum MouseScrollSource { case verifiedWheel, trackpad, unknown }
struct MouseScrollSample: Equatable {
    var vertical: Double
    var horizontal: Double
    var momentum = false
    var gesture = false
    var modified = false
}

enum MouseScrollPolicy {
    static func transform(_ sample: MouseScrollSample, source: MouseScrollSource,
                          enabled: Bool, reverse: Bool, speed: Double) -> MouseScrollSample {
        guard enabled, source == .verifiedWheel, !sample.momentum, !sample.gesture,
              !sample.modified, sample.horizontal == 0, sample.vertical.isFinite,
              speed.isFinite, (0.1...3).contains(speed) else { return sample }
        var result = sample
        let vertical = sample.vertical * speed * (reverse ? -1 : 1)
        guard vertical.isFinite else { return sample }
        result.vertical = vertical
        return result
    }
}
