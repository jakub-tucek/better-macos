import CoreGraphics
import Foundation
import CStrafe

let requireSafety = CommandLine.arguments.contains("--require-safety")
var safetyFailures = 0

final class PhaseRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [Int64] = []
    private var failures = 0
    let began = DispatchSemaphore(value: 0)

    func post(_ phase: Int64, _ progress: Double, _ velocity: Double) -> Bool {
        lock.lock()
        attempts.append(phase)
        if phase == strafe_gesture_phase_ended() { failures += 1 }
        lock.unlock()
        if phase == strafe_gesture_phase_began() { began.signal() }
        return phase != strafe_gesture_phase_ended()
    }

    var phases: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    var terminalFailures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

let record = PhaseRecord()
let engine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: record.post)
engine.setTransitionSpeed(.quick)
do { try engine.switchSpace(.right) } catch { fatalError("Unexpected dispatch failure: \(error)") }
guard record.began.wait(timeout: .now() + 2) == .success else { fatalError("Ramp did not start") }
var drained = false
engine.cancelPendingSwitches { drained = true }
let deadline = Date().addingTimeInterval(2)
while !drained && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
}
guard drained, record.phases.count == TransitionSpeed.rampSteps + 2,
      record.phases.last == strafe_gesture_phase_ended() else { fatalError("Unexpected ramp trace") }
print("REPRODUCED animated: terminal_failures=\(record.terminalFailures) drain_completions=1 reported_failures=0 attempts=\(record.phases.count)")
// Existing Void completion cannot express the injected failed terminal attempt.
if drained && record.terminalFailures > 0 { safetyFailures += 1 }

struct NoPostEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {}
}

func event(cgsType: Int64, phase: Int64 = 0, timestamp: UInt64) -> CGEvent {
    let event = CGEvent(source: nil)!
    for (field, value) in [(UInt32(55), cgsType), (110, 23), (123, 1), (132, phase)] {
        event.setIntegerValueField(CGEventField(rawValue: field)!, value: value)
    }
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    event.timestamp = timestamp
    return event
}

// Never call start(): direct production callback invocation, no installed tap.
let interceptor = SwipeInterceptor(engine: NoPostEngine(), isExposeActive: { false })
let dock = CGEventType(rawValue: 30)!
let companion = CGEventType(rawValue: 29)!
guard interceptor.handle(type: companion, event: event(cgsType: 29, timestamp: 0)) != nil else {
    fatalError("Idle companion must pass")
}
guard interceptor.handle(type: dock, event: event(cgsType: 30, phase: 1, timestamp: 1)) == nil else {
    fatalError("Expected began interception")
}
// Inject elapsed event time, not a production clock: the implementation has no clock seam.
let oneHour: UInt64 = 3_600_000_000_000
var suppressed = 0
for index in 1...100 {
    if interceptor.handle(type: companion, event: event(cgsType: 29, timestamp: oneHour + UInt64(index))) == nil {
        suppressed += 1
    }
}
let clickPasses = interceptor.handle(type: .leftMouseDown, event: event(cgsType: 1, timestamp: oneHour)) != nil
guard suppressed == 100, clickPasses else { fatalError("Unexpected lost-terminal trace") }
print("REPRODUCED interceptor: timestamp_gap_seconds=3600 companion_suppressed=\(suppressed)/100 ordinary_click_passes=\(clickPasses)")
if suppressed > 0 { safetyFailures += 1 }
_ = interceptor.handle(type: dock, event: event(cgsType: 30, phase: 8, timestamp: oneHour + 101))
guard interceptor.handle(type: companion, event: event(cgsType: 29, timestamp: oneHour + 102)) != nil else {
    fatalError("Cancellation did not clear tracking")
}
_ = interceptor.handle(type: dock, event: event(cgsType: 30, phase: 1, timestamp: oneHour + 103))
_ = interceptor.handle(type: .tapDisabledByTimeout, event: event(cgsType: 29, timestamp: oneHour + 104))
guard interceptor.handle(type: companion, event: event(cgsType: 29, timestamp: oneHour + 105)) != nil else {
    fatalError("Tap interruption did not clear tracking")
}
print("CONTROL interceptor: cancellation and tap interruption clear suppression")
if requireSafety && safetyFailures > 0 { exit(1) }
