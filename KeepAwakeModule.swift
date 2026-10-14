import AppKit
import IOKit.pwr_mgt

protocol PowerAssertionBackend {
    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID
    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws
    func release(_ id: IOPMAssertionID) throws
}

struct SystemPowerAssertions: PowerAssertionBackend {
    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: "Fix macOS: keep \(display ? "display" : "computer") awake",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: timeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff
        ]
        var id: IOPMAssertionID = 0
        try check(IOPMAssertionCreateWithProperties(properties as CFDictionary, &id))
        return id
    }

    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws {
        try check(IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: seconds)))
        try check(IOPMAssertionSetProperty(id, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn)))
    }

    func release(_ id: IOPMAssertionID) throws { try check(IOPMAssertionRelease(id)) }

    private func check(_ result: IOReturn) throws {
        guard result == kIOReturnSuccess else {
            throw ToggleError(message: "Could not update the keep-awake session (IOKit \(result)).")
        }
    }
}

/// Session deadlines and power assertions are transient. Only UI choices persist.
/// The continuous clock counts sleep; IOKit also bounds assertions if our UI stalls.
final class KeepAwakeModule {
    private let defaults: UserDefaults
    private let backend: PowerAssertionBackend
    private let now: () -> TimeInterval
    private let automaticUpdates: Bool
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var deadline: TimeInterval?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []
    private let runningApps: () -> [String: String]
    private var watchingApps = false
    private var pausedApps = Set<String>()
    private var cleanupPending = false
    private(set) var matchingApps: [String: String] = [:]
    var selectedApps: [String: String] { defaults.dictionary(forKey: "keepAwake.apps") as? [String: String] ?? [:] }
    var appsPaused: Bool { !pausedApps.isEmpty }
    var activeAppNames: [String] { matchingApps.filter { !pausedApps.contains($0.key) }.values.sorted() }
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var active: Bool { systemAssertion != nil || displayAssertion != nil }
    var remaining: TimeInterval { max(0, (deadline ?? now()) - now()) }
    var keepDisplayAwake: Bool { defaults.bool(forKey: "keepAwake.display") }
    var selectedMinutes: Int {
        get {
            let saved = defaults.integer(forKey: "keepAwake.minutes")
            return (5...1440).contains(saved) ? saved : 30
        }
        set { defaults.set(min(1440, max(5, newValue)), forKey: "keepAwake.minutes"); onChange?() }
    }

    init(defaults: UserDefaults = .standard, backend: PowerAssertionBackend = SystemPowerAssertions(),
         now: @escaping () -> TimeInterval = KeepAwakeModule.continuousTime, automaticUpdates: Bool = true,
         runningApps: @escaping () -> [String: String] = KeepAwakeModule.systemRunningApps) {
        self.defaults = defaults
        self.backend = backend
        self.now = now
        self.automaticUpdates = automaticUpdates
        self.runningApps = runningApps
    }

    static func systemRunningApps() -> [String: String] {
        var result: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let id = app.bundleIdentifier { result[id] = app.localizedName ?? id }
        }
        return result
    }

    func activate() {
        watchingApps = true
        if automaticUpdates && appObservers.isEmpty {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                appObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.tick() })
            }
        }
        beginUpdates()
        tick()
    }

    func setApp(_ id: String, name: String, selected: Bool) throws {
        var apps = selectedApps
        apps[id] = selected ? name : nil
        defaults.set(apps, forKey: "keepAwake.apps")
        try reconcile()
        onChange?()
    }

    func resumeApps() throws {
        pausedApps.removeAll()
        try reconcile()
        onChange?()
    }

    func deactivate() throws {
        watchingApps = false
        appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.removeAll()
        endUpdates()
        try stop()
    }

    static func continuousTime() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    func start() throws {
        try expireIfNeeded()
        guard deadline == nil, !cleanupPending else { return }
        let seconds = Double(selectedMinutes * 60)
        deadline = now() + seconds
        beginUpdates()
        do {
            try reconcile()
        } catch {
            let creationError = error
            do { try stop() } catch { throw ToggleError(message: "Starting display wake failed; cleanup needs retry: \(error.localizedDescription)") }
            throw creationError
        }
        onChange?()
    }

    func extend() throws {
        try expireIfNeeded()
        guard deadline != nil, !cleanupPending else { return }
        let seconds = min(24 * 3600, remaining + 15 * 60)
        let timeout = activeAppNames.isEmpty ? seconds : max(60, seconds)
        if let systemAssertion { try backend.setTimeout(systemAssertion, seconds: timeout) }
        if let displayAssertion { try backend.setTimeout(displayAssertion, seconds: timeout) }
        deadline = now() + seconds
        onChange?()
    }

    func setKeepDisplayAwake(_ enabled: Bool) throws {
        try expireIfNeeded()
        if active {
            if enabled && displayAssertion == nil {
                displayAssertion = try backend.create(display: true, timeout: activeAppNames.isEmpty ? remaining : max(60, remaining))
            } else if !enabled, let id = displayAssertion {
                try backend.release(id)
                displayAssertion = nil
            }
        }
        defaults.set(enabled, forKey: "keepAwake.display")
        onChange?()
    }

    func tick() {
        do { try reconcile() } catch { onError?(error) }
        onChange?()
    }

    private func expireIfNeeded() throws {
        if deadline != nil && remaining <= 0 { deadline = nil; try reconcile() }
    }

    private func reconcile() throws {
        if watchingApps {
            matchingApps = runningApps().filter { selectedApps[$0.key] != nil }
            pausedApps.formIntersection(matchingApps.keys)
        } else { matchingApps = [:] }
        if deadline != nil && remaining <= 0 { deadline = nil }
        if cleanupPending { try releaseAssertions() }
        let timeout = activeAppNames.isEmpty ? remaining : max(60, remaining)
        guard timeout > 0 else { try releaseAssertions(); return }
        if let id = systemAssertion { try backend.setTimeout(id, seconds: timeout) }
        else { systemAssertion = try backend.create(display: false, timeout: timeout) }
        if keepDisplayAwake {
            if let id = displayAssertion { try backend.setTimeout(id, seconds: timeout) }
            else { displayAssertion = try backend.create(display: true, timeout: timeout) }
        }
    }

    func stop() throws {
        deadline = nil
        matchingApps = watchingApps ? runningApps().filter { selectedApps[$0.key] != nil } : [:]
        pausedApps.formUnion(matchingApps.keys)
        try releaseAssertions()
    }

    private func releaseAssertions() throws {
        cleanupPending = true
        var failure: Error?
        // Attempt both releases, retaining failed IDs for a retry.
        if let id = displayAssertion {
            do { try backend.release(id); displayAssertion = nil } catch { failure = error }
        }
        if let id = systemAssertion {
            do { try backend.release(id); systemAssertion = nil } catch { failure = error }
        }
        if !active {
            cleanupPending = false
            if !watchingApps { endUpdates() }
        }
        onChange?()
        if let failure { throw failure }
    }

    private func beginUpdates() {
        guard automaticUpdates, timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.tick() }
    }

    private func endUpdates() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    deinit {
        appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        endUpdates()
        if let displayAssertion { try? backend.release(displayAssertion) }
        if let systemAssertion { try? backend.release(systemAssertion) }
    }
}
