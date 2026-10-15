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
    private var pausedInstances: [String: Set<pid_t>] = [:]
    private let processInstances: () -> [String: Set<pid_t>]
    private struct PublishedState: Equatable {
        let active: Bool
        let seconds: Int
        let apps: [String: String]
        let paused: Set<String>
        let failed: Bool
    }
    private var lastPublished: PublishedState?
    private var lastError: String?
    private(set) var protectionFailed = false
    private var cleanupPending = false
    private(set) var matchingApps: [String: String] = [:]
    var selectedApps: [String: String] { defaults.dictionary(forKey: "keepAwake.apps") as? [String: String] ?? [:] }
    var appsPaused: Bool { !pausedApps.isEmpty }
    var activeAppNames: [String] { matchingApps.filter { !pausedApps.contains($0.key) }.values.sorted() }
    private func assertionTimeout(remaining: TimeInterval) -> TimeInterval {
        activeAppNames.isEmpty ? remaining : max(60, remaining)
    }
    private func currentMatchingApps() -> [String: String] {
        guard watchingApps else { return [:] }
        let selected = selectedApps
        return runningApps().filter { selected[$0.key] != nil }
    }
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var active: Bool { systemAssertion != nil || displayAssertion != nil }
    var canStop: Bool { active || deadline != nil || !activeAppNames.isEmpty }
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
         runningApps: @escaping () -> [String: String] = KeepAwakeModule.systemRunningApps,
         processInstances: @escaping () -> [String: Set<pid_t>] = KeepAwakeModule.systemInstances) {
        self.defaults = defaults
        self.backend = backend
        self.now = now
        self.automaticUpdates = automaticUpdates
        self.runningApps = runningApps
        self.processInstances = processInstances
    }

    static func systemInstances() -> [String: Set<pid_t>] {
        var result: [String: Set<pid_t>] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let id = app.bundleIdentifier { result[id, default: []].insert(app.processIdentifier) }
        }
        return result
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
        if !selectedApps.isEmpty || active || cleanupPending { beginUpdates() }
        tick()
    }

    func setApp(_ id: String, name: String, selected: Bool) throws {
        var apps = selectedApps
        apps[id] = selected ? name : nil
        defaults.set(apps, forKey: "keepAwake.apps")
        if watchingApps && !apps.isEmpty { beginUpdates() }
        try reconcile()
        onChange?()
    }

    func configureForSetup(minutes: Int, display: Bool, apps: [String: String]) throws {
        guard selectedMinutes != minutes || keepDisplayAwake != display || selectedApps != apps else { return }
        // Replace the complete policy before reconciling once. Timed ownership
        // and app pauses stay intact; removed rules cannot acquire a new lease.
        defaults.set(apps, forKey: "keepAwake.apps")
        defaults.set(min(1440, max(5, minutes)), forKey: "keepAwake.minutes")
        defaults.set(display, forKey: "keepAwake.display")
        if watchingApps && !apps.isEmpty { beginUpdates() }
        try reconcile()
        onChange?()
    }

    func resumeApps() throws {
        pausedApps.removeAll()
        pausedInstances.removeAll()
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
            deadline = nil
            // Roll back only the new timed reason, preserving app rules and pauses.
            if activeAppNames.isEmpty {
                do { try releaseAssertions() } catch { throw ToggleError(message: "Starting display wake failed; cleanup needs retry: \(error.localizedDescription)") }
            }
            protectionFailed = true
            onChange?()
            throw creationError
        }
        onChange?()
    }

    func extend() throws {
        try expireIfNeeded()
        guard deadline != nil, !cleanupPending else { return }
        let seconds = min(24 * 3600, remaining + 15 * 60)
        let timeout = assertionTimeout(remaining: seconds)
        do {
            if let systemAssertion { try backend.setTimeout(systemAssertion, seconds: timeout) }
            if let displayAssertion { try backend.setTimeout(displayAssertion, seconds: timeout) }
        } catch {
            // Restore the original deadline on assertions already updated before failure.
            try? reconcile()
            throw error
        }
        deadline = now() + seconds
        onChange?()
    }

    func setKeepDisplayAwake(_ enabled: Bool) throws {
        try expireIfNeeded()
        if active {
            if enabled && displayAssertion == nil {
                displayAssertion = try backend.create(display: true, timeout: assertionTimeout(remaining: remaining))
            } else if !enabled, let id = displayAssertion {
                try backend.release(id)
                displayAssertion = nil
            }
        }
        defaults.set(enabled, forKey: "keepAwake.display")
        onChange?()
    }

    func tick() {
        do { try reconcile(); protectionFailed = false; lastError = nil }
        catch {
            protectionFailed = true
            if lastError != error.localizedDescription { lastError = error.localizedDescription; onError?(error) }
        }
        let state = PublishedState(active: active, seconds: Int(ceil(remaining)), apps: matchingApps,
                                   paused: pausedApps, failed: protectionFailed)
        if state != lastPublished { lastPublished = state; onChange?() }
    }

    private func expireIfNeeded() throws {
        if deadline != nil && remaining <= 0 { deadline = nil; try reconcile() }
    }

    private func reconcile() throws {
        do { try reconcileAssertions(); protectionFailed = false }
        catch { protectionFailed = true; throw error }
    }

    private func reconcileAssertions() throws {
        if watchingApps {
            matchingApps = currentMatchingApps()
            pausedApps.formIntersection(matchingApps.keys)
            let instances = processInstances()
            for id in pausedApps {
                let surviving = (pausedInstances[id] ?? []).intersection(instances[id] ?? [])
                pausedInstances[id] = surviving
                if surviving.isEmpty { pausedApps.remove(id) }
            }
        } else { matchingApps = [:] }
        if deadline != nil && remaining <= 0 { deadline = nil }
        if cleanupPending { try releaseAssertions() }
        let timeout = assertionTimeout(remaining: remaining)
        guard timeout > 0 else { try releaseAssertions(); return }
        if let id = systemAssertion { try backend.setTimeout(id, seconds: timeout) }
        else { systemAssertion = try backend.create(display: false, timeout: timeout) }
        if keepDisplayAwake {
            if let id = displayAssertion { try backend.setTimeout(id, seconds: timeout) }
            else { displayAssertion = try backend.create(display: true, timeout: timeout) }
        }
    }

    func stop() throws {
        defer { onChange?() }
        deadline = nil
        matchingApps = currentMatchingApps()
        pausedApps.formUnion(matchingApps.keys)
        let instances = processInstances()
        for id in matchingApps.keys { pausedInstances[id] = instances[id] ?? [] }
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
            if !watchingApps || selectedApps.isEmpty { endUpdates() }
        }
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
