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
         now: @escaping () -> TimeInterval = KeepAwakeModule.continuousTime, automaticUpdates: Bool = true) {
        self.defaults = defaults
        self.backend = backend
        self.now = now
        self.automaticUpdates = automaticUpdates
    }

    static func continuousTime() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    func start() throws {
        guard !active else { return }
        let seconds = Double(selectedMinutes * 60)
        systemAssertion = try backend.create(display: false, timeout: seconds)
        deadline = now() + seconds
        beginUpdates()
        do {
            if keepDisplayAwake { displayAssertion = try backend.create(display: true, timeout: seconds) }
        } catch {
            let creationError = error
            do { try stop() } catch { throw ToggleError(message: "Starting display wake failed; cleanup needs retry: \(error.localizedDescription)") }
            throw creationError
        }
        onChange?()
    }

    func extend() throws {
        try expireIfNeeded()
        guard active else { return }
        let seconds = min(24 * 3600, remaining + 15 * 60)
        if let systemAssertion { try backend.setTimeout(systemAssertion, seconds: seconds) }
        if let displayAssertion { try backend.setTimeout(displayAssertion, seconds: seconds) }
        deadline = now() + seconds
        onChange?()
    }

    func setKeepDisplayAwake(_ enabled: Bool) throws {
        try expireIfNeeded()
        if active {
            if enabled && displayAssertion == nil {
                displayAssertion = try backend.create(display: true, timeout: remaining)
            } else if !enabled, let id = displayAssertion {
                try backend.release(id)
                displayAssertion = nil
            }
        }
        defaults.set(enabled, forKey: "keepAwake.display")
        onChange?()
    }

    func tick() {
        do { try expireIfNeeded() } catch { onError?(error) }
        onChange?()
    }

    private func expireIfNeeded() throws {
        if active && remaining <= 0 { try stop() }
    }

    func stop() throws {
        var failure: Error?
        // Attempt both releases, retaining failed IDs for a retry.
        if let id = displayAssertion {
            do { try backend.release(id); displayAssertion = nil } catch { failure = error }
        }
        if let id = systemAssertion {
            do { try backend.release(id); systemAssertion = nil } catch { failure = error }
        }
        if !active { deadline = nil; endUpdates() }
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
        endUpdates()
        if let displayAssertion { try? backend.release(displayAssertion) }
        if let systemAssertion { try? backend.release(systemAssertion) }
    }
}
