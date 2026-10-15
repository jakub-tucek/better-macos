import Foundation

enum ActivityTrigger: String {
    case user = "You", automatic = "Automatic", recovery = "Recovery"
}

enum ActivityRecoveryReason: String {
    case user = "Requested by you"
    case timeout = "Confirmation period ended"
    case failedChange = "A display change could not be confirmed"
    case featureDisable = "Preparing to disable a display feature"
    case quit = "Preparing to quit"
    var trigger: ActivityTrigger { self == .user ? .user : .recovery }
}

/// Closed, content-free descriptions. User labels and backend errors never cross this seam.
enum ActivityEvent: Equatable {
    case displayPower(Bool), displayArrangement, displayRecovery(ActivityRecoveryReason)
    case displayKept, arrangementKept
    case windowSave, windowRestore
    case awakeStart(Int), awakeStop, awakeExtend, awakeRetry, awakeProtection, awakeExpired(Bool), awakeRule(Bool)
    case bluetoothConnect(Bool), bluetoothPower, bluetoothWaiting

    var feature: String {
        switch self {
        case .displayPower, .displayArrangement, .displayRecovery, .displayKept, .arrangementKept: return "Displays"
        case .windowSave, .windowRestore: return "Window layouts"
        case .awakeStart, .awakeStop, .awakeExtend, .awakeRetry, .awakeProtection, .awakeExpired, .awakeRule: return "Keep awake"
        case .bluetoothConnect, .bluetoothPower, .bluetoothWaiting: return "Bluetooth"
        }
    }

    var title: String {
        switch self {
        case .displayPower(let on): return on ? "Turn on a display" : "Turn off a display"
        case .displayArrangement: return "Change display arrangement"
        case .displayRecovery: return "Restore displays"
        case .displayKept: return "Keep display change"
        case .arrangementKept: return "Keep display arrangement"
        case .windowSave: return "Save window layout"
        case .windowRestore: return "Restore window layout"
        case .awakeStart(let minutes): return "Keep your Mac awake for \(minutes) minutes"
        case .awakeStop: return "Stop keeping your Mac awake"
        case .awakeExtend: return "Extend keep awake session"
        case .awakeRetry: return "Retry keep awake protection"
        case .awakeProtection: return "Maintain keep awake protection"
        case .awakeExpired: return "Timed keep awake session ended"
        case .awakeRule(let active): return active ? "App rule is keeping your Mac awake" : "App rule stopped keeping your Mac awake"
        case .bluetoothConnect(let connected): return connected ? "Connect a Bluetooth device" : "Disconnect a Bluetooth device"
        case .bluetoothPower: return "Turn Bluetooth on"
        case .bluetoothWaiting: return "Automatic connection paused to protect other audio"
        }
    }
}

struct ActivityWindowCounts: Equatable {
    var restored = 0, missing = 0, ambiguous = 0, unsupported = 0, excluded = 0, failed = 0
    var details: String {
        "Restored \(restored); missing \(missing); ambiguous \(ambiguous); unsupported \(unsupported); excluded \(excluded); failed \(failed). Only ordinary accessible windows on the current desktop are supported."
    }
}

enum ActivityResult: Equatable {
    case completed, awaitingConfirmation, failed, uncertainDisplay, canceled, blocked
    case windowsSaved(Int), windowsRestored(ActivityWindowCounts), windowsCanceled(Int)
    case retryScheduled, cleanupNeeded, expired(appRuleActive: Bool)

    var label: String {
        switch self {
        case .completed, .windowsSaved: return "Completed"
        case .awaitingConfirmation: return "Confirmation requested"
        case .failed, .uncertainDisplay, .cleanupNeeded: return "Failed"
        case .canceled, .windowsCanceled: return "Canceled"
        case .blocked: return "Not performed"
        case .retryScheduled: return "Failed · retry scheduled"
        case .expired: return "Session ended"
        case .windowsRestored(let counts): return counts.failed + counts.missing + counts.ambiguous + counts.unsupported > 0 ? "Partial result" : "Completed"
        }
    }

    var details: String {
        switch self {
        case .completed: return "The app completed this operation."
        case .awaitingConfirmation: return "The display helper completed the change and requested confirmation. Keep and recovery outcomes are recorded separately. Unconfirmed changes trigger recovery when the confirmation period ends."
        case .failed: return "The operation did not complete successfully. See the feature's settings for available recovery or retry controls."
        case .uncertainDisplay: return "The display change could not be confirmed. It may already have taken effect. Recovery will be attempted; its result is recorded separately."
        case .canceled: return "The operation was canceled or superseded."
        case .blocked: return "The required permission, stable hardware state, or safe operation conditions were unavailable. No success is claimed."
        case .windowsSaved(let count): return "Saved a layout containing \(count) windows in app preferences."
        case .windowsRestored(let counts): return counts.details
        case .windowsCanceled(let count): return "Restoration canceled after \(count) confirmed window moves because conditions changed or the operation was superseded."
        case .retryScheduled: return "A device connection attempt failed. Another automatic attempt is scheduled in about 30 seconds while this policy remains enabled."
        case .cleanupNeeded: return "The app could not fully release keep awake protection. Recovery state is retained for retry."
        case .expired(let active): return active ? "The timed session ended. An app rule is still keeping your Mac awake." : "The timed session ended."
        }
    }
}

struct ActivityOperationID: Hashable {
    fileprivate let value = UUID()
    fileprivate let generation: UUID
}

struct ActivityEntry: Identifiable, Equatable {
    let id: ActivityOperationID
    let startedAt: Date
    let event: ActivityEvent
    let trigger: ActivityTrigger
    var queued = false
    var result: ActivityResult?
    var status: String { result?.label ?? (queued ? "Queued" : "Started") }
    var details: String {
        let description = result?.details ?? (queued ? "The request is waiting for current work to finish. No device change has been confirmed." : "The app has started this operation; no successful outcome has been confirmed yet.")
        if case .displayRecovery(let reason) = event { return "\(reason.rawValue). \(description)" }
        if result == .completed {
            switch event {
            case .displayPower, .displayArrangement: return "The display helper completed the requested change. This does not verify the physical screen's appearance."
            case .bluetoothConnect: return "The requested connection state was confirmed by a fresh device observation. Audio routing is a separate operation."
            case .bluetoothPower: return "The Bluetooth backend confirmed that the radio was on."
            case .bluetoothWaiting: return "Automatic connection is waiting to avoid interrupting other audio. Repeated unchanged checks are omitted."
            default: break
            }
        }
        return description
    }
}

/// Main-thread, memory-only journal. It never owns feature work or waits for delivery.
final class ActivityJournal {
    private(set) var entries: [ActivityEntry] = []
    private var generation = UUID()
    private let capacity: Int
    private let now: () -> Date
    var onChange: (() -> Void)?

    init(capacity: Int = 300, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, min(300, capacity)); self.now = now
    }

    @discardableResult
    func begin(_ event: ActivityEvent, trigger: ActivityTrigger, queued: Bool = false) -> ActivityOperationID {
        precondition(Thread.isMainThread)
        let id = ActivityOperationID(generation: generation)
        entries.insert(ActivityEntry(id: id, startedAt: now(), event: event, trigger: trigger, queued: queued), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        onChange?()
        return id
    }

    func start(_ id: ActivityOperationID) {
        precondition(Thread.isMainThread)
        guard id.generation == generation, let index = entries.firstIndex(where: { $0.id == id }), entries[index].result == nil, entries[index].queued else { return }
        entries[index].queued = false
        onChange?()
    }

    func finish(_ id: ActivityOperationID, result: ActivityResult) {
        precondition(Thread.isMainThread)
        guard id.generation == generation, let index = entries.firstIndex(where: { $0.id == id }), entries[index].result == nil else { return }
        entries[index].result = result
        onChange?()
    }

    func record(_ event: ActivityEvent, trigger: ActivityTrigger, result: ActivityResult) {
        let id = begin(event, trigger: trigger)
        finish(id, result: result)
    }

    func clear() {
        precondition(Thread.isMainThread)
        generation = UUID(); entries.removeAll(); onChange?()
    }
}
