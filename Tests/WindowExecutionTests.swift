import Foundation

/// In-memory native facts and primitive writes only. No discovery/matching policy,
/// identity cache, collision planning or verification algorithm is duplicated here.
private final class ExecutionTestAccess: WindowNativeAccess {
    struct Entry {
        var pid: Int32?
        var frame: CGRect?
        var layer: Int? = 0
    }
    struct Record {
        var frame: CGRect? = CGRect(x: 10, y: 20, width: 300, height: 200)
        var title: String? = "Document"
        var subrole: String? = "AXStandardWindow"
        var minimized: Bool? = false
        var fullScreen: Bool? = false
        var positionSettable = true
        var sizeSettable = true
    }
    var permitted = true
    var now: TimeInterval = 100
    var uptime: TimeInterval { trace.append("clock"); return now }
    let ownPID: Int32 = 99
    var apps = [WindowApplication(pid: 1, bundle: "test.app")]
    var entries: [Entry]? = [Entry(pid: 1, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
    var appWindows: [Int: [Int]] = [-1: [1]]
    var records = [1: Record()]
    var identities: [Int: Int] = [:]
    var frontmost: WindowApplication? = WindowApplication(pid: 1, bundle: "test.app")
    var focus: Int? = 1
    var timeoutFailures = Set<Int>()
    var trace: [String] = []
    var timeouts: [Float] = []
    var writes: [WindowGeometryAttribute] = []
    var writeElements: [Int] = []
    var failWrite: Int?
    var makeValues = true
    var constrainSize = false
    var adjustPositionOnResize = false
    var unreadableAfterWrite = false
    var beforeApplications: (() -> Void)?
    var beforeWindows: (() -> Void)?
    var beforeValues: (() -> Void)?
    var beforeFrame: ((Int) -> Void)?
    var beforeString: ((Int, WindowStringAttribute) -> Void)?
    var beforeBool: ((Int, WindowBoolAttribute) -> Void)?

    func requestPermission() { trace.append("requestPermission") }
    func displays() -> [WindowDisplay] { [] }
    func inventory() -> [Entry]? { trace.append("inventory"); return entries }
    func ownerPID(_ entry: Entry) -> Int32? { entry.pid }
    func bounds(_ entry: Entry) -> CGRect? { entry.frame }
    func layer(_ entry: Entry) -> Int? { entry.layer }
    func applications() -> [WindowApplication] { trace.append("apps"); beforeApplications?(); return apps }
    func frontmostApplication() -> WindowApplication? { trace.append("frontmost"); return frontmost }
    func application(_ pid: Int32) -> Int { trace.append("root:\(pid)"); return -Int(pid) }
    func setTimeout(_ element: Int, seconds: Float) -> Bool {
        trace.append("timeout:\(element)"); timeouts.append(seconds); return !timeoutFailures.contains(element)
    }
    func windows(_ root: Int) -> [Int]? { trace.append("windows:\(root)"); beforeWindows?(); return appWindows[root] }
    func frame(_ element: Int) -> CGRect? {
        trace.append("frame:\(element)"); beforeFrame?(element)
        if unreadableAfterWrite && !writes.isEmpty { return nil }
        return records[element]?.frame
    }
    func string(_ element: Int, _ attribute: WindowStringAttribute) -> String? {
        trace.append("\(attribute):\(element)")
        beforeString?(element, attribute)
        return attribute == .title ? records[element]?.title : records[element]?.subrole
    }
    func bool(_ element: Int, _ attribute: WindowBoolAttribute) -> Bool? {
        trace.append("\(attribute):\(element)")
        beforeBool?(element, attribute)
        return attribute == .minimized ? records[element]?.minimized : records[element]?.fullScreen
    }
    func isSettable(_ element: Int, _ attribute: WindowGeometryAttribute) -> Bool {
        trace.append("settable:\(attribute):\(element)")
        return (attribute == .position ? records[element]?.positionSettable : records[element]?.sizeSettable) ?? false
    }
    func equal(_ lhs: Int, _ rhs: Int) -> Bool { (identities[lhs] ?? lhs) == (identities[rhs] ?? rhs) }
    func focused(_ root: Int) -> Int? { trace.append("focused:\(root)"); return focus }
    func focusEqual(_ focus: Int, _ element: Int) -> Bool { equal(focus, element) }
    func writeValues(_ frame: CGRect) -> CGRect? {
        trace.append("values"); beforeValues?(); return makeValues ? frame : nil
    }
    func write(_ element: Int, _ attribute: WindowGeometryAttribute, _ values: CGRect) -> Bool {
        trace.append("write:\(attribute):\(element)"); writes.append(attribute); writeElements.append(element)
        if failWrite == writes.count { return false }
        guard var frame = records[element]?.frame else { return false }
        if attribute == .position { frame.origin = values.origin }
        else {
            frame.size = constrainSize ? CGSize(width: values.width - 1, height: values.height) : values.size
            if adjustPositionOnResize { frame.origin.x += 20 }
        }
        records[element]?.frame = frame
        return true
    }
    func addWindow(_ id: Int, pid: Int32 = 1, title: String = "Other", frame: CGRect) {
        records[id] = Record(frame: frame, title: title)
        appWindows[-Int(pid), default: []].append(id)
        entries?.append(Entry(pid: pid, frame: frame))
    }
}

private func executionError(_ backend: WindowExecution<ExecutionTestAccess>) -> String? {
    do { _ = try backend.windows(); return nil }
    catch { return error.localizedDescription }
}

func runWindowExecutionTests() {
    do { try windowExecutionChecks() }
    catch { expect(false, "unexpected production execution discovery failure: \(error)") }
}

private func windowExecutionChecks() throws {
    let target = CGRect(x: -800, y: 50, width: 600, height: 450)
    let other = CGRect(x: 400, y: 20, width: 300, height: 200)

    do {
        let access = ExecutionTestAccess()
        let subject = WindowExecution(access: access)
        expect(access.trace.isEmpty, "execution construction performs no native work")
        let original = try subject.windows()[0]
        access.permitted = false; access.trace = []
        expect(executionError(subject)?.contains("permission") == true && access.trace.isEmpty,
               "production discovery denies permission before inventory or AX access")
        access.permitted = true
        expect(!subject.move(original, to: target) && access.writes.isEmpty,
               "permission failure clears cached identity before later moves")
    }
    do {
        let access = ExecutionTestAccess()
        let backend = WindowExecution(access: access)
        expect(backend.displays().isEmpty, "execution display reads stay on injected adapter")
        let original = try backend.windows()[0]
        access.entries = nil; access.trace = []
        expect(executionError(backend)?.contains("WindowServer") == true && access.trace == ["inventory"],
               "inventory failure throws before application enumeration")
        access.entries = []
        expect(!backend.move(original, to: target), "inventory failure discards prior cached token")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.apps.append(WindowApplication(pid: 2, bundle: "unreadable.app"))
        access.entries?.append(.init(pid: 2, frame: other))
        expect(executionError(backend)?.contains("unreadable.app") == true,
               "whole-desktop discovery fails for unreadable second app instead of accepting first app")
        expect(access.trace.contains("windows:-1") && access.trace.contains("windows:-2"),
               "execution scans all visible apps, not just focus")
        expect(access.writes.isEmpty, "unreadable app cannot write")
    }
    for missing in ["title", "frame"] {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.addWindow(2, frame: other)
        if missing == "title" { access.records[2]?.title = nil }
        else { access.records[2]?.frame = nil }
        expect(executionError(backend)?.contains("Incomplete Accessibility metadata for test.app") == true,
               "missing \(missing) invalidates entire matching domain")
    }
    for element in [-1, 1] {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access); access.timeoutFailures.insert(element)
        expect(executionError(backend)?.contains("timed out") == true,
               "failed timeout configuration on \(element) rejects snapshot")
        expect(!access.trace.contains("frame:1"), "timeout setup failure stops before frame access")
    }
    for phase in ["app", "window", "nextWindow"] {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        if phase == "app" { access.beforeApplications = { access.now += 0.75 } }
        if phase == "window" { access.beforeWindows = { access.now += 0.75 } }
        if phase == "nextWindow" {
            access.addWindow(2, frame: other)
            access.beforeFrame = { _ in access.now += 0.75 }
        }
        expect(executionError(backend)?.contains("timed out") == true,
               "750ms budget fails closed at exact deadline during \(phase)")
        expect(!access.trace.contains(phase == "app" ? "root:1" : phase == "window" ? "frame:1" : "frame:2"),
               "deadline prevents next native read during \(phase)")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.beforeWindows = { access.now = 100.749 }
        let snapshot = try backend.windows()
        expect(snapshot.count == 1, "scan just inside 750ms remains accepted")
        expect(access.timeouts == [0.05, 0.05], "production configures 50ms root and window timeouts")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.addWindow(2, title: "Different title", frame: access.records[1]!.frame!)
        access.entries?.removeLast()
        let snapshot = try backend.windows()
        expect(snapshot.count == 2 && snapshot.allSatisfy { !$0.supported },
               "same-geometry sibling is unsupported even with different title and one CG correlation")
        let focused = try backend.focusedWindow()
        expect(focused == nil, "unsupported geometry is not returned as focused")
        expect(!backend.move(snapshot[0], to: target) && access.writes.isEmpty,
               "production move rejects same-geometry ambiguity")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.addWindow(2, title: "Document", frame: other)
        let snapshot = try backend.windows()
        expect(snapshot.allSatisfy(\.supported), "distinct geometry remains supported despite duplicate titles")
        expect(!backend.move(snapshot[0], to: target) && access.writes.isEmpty,
               "fresh same-title refusal runs in production execution")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.windows()[0]
        access.identities[101] = 1; access.records[101] = access.records[1]; access.appWindows[-1] = [101]
        let refreshed = try backend.windows()[0]
        expect(refreshed.token == original.token, "adapter equality retains identity across distinct native handles")
        let focused = try backend.focusedWindow()
        expect(focused?.token == original.token, "focused lookup uses adapter identity equality rather than handle equality")
        access.appWindows[-1] = [1]
        expect(backend.move(original, to: target) && access.writeElements == [101, 101, 101],
               "equal fresh handle validates original cached element without replacing write identity")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let first = try backend.windows()[0]
        let second = try backend.windows()[0]
        expect(first.token == second.token, "equal native identities retain token across discovery")
        access.records[2] = access.records[1]; access.appWindows[-1] = [2]
        expect(!backend.move(first, to: target) && access.writes.isEmpty,
               "same title and geometry cannot replace cached AX identity during fresh move scan")
        let replacement = try backend.windows()[0]
        expect(replacement.token != first.token, "replacement AX identity gets new token")
        expect(!backend.move(first, to: target), "stale token remains rejected after replacement discovery")
        expect(backend.move(replacement, to: target) && access.writeElements == [2, 2, 2],
               "new token writes only replacement identity")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.windows()[0]
        var forged = original; forged.token = "not-cached"
        access.trace = []
        expect(!backend.move(forged, to: target) && access.trace.isEmpty,
               "unknown token fails before discovery and writes")
        access.addWindow(2, frame: target)
        expect(!backend.move(original, to: target) && access.writes.isEmpty,
               "fresh destination collision rejects newly arrived same-app window")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.apps.append(WindowApplication(pid: 2, bundle: "other.app"))
        access.addWindow(2, pid: 2, frame: target)
        let original = try backend.windows()[0]
        expect(backend.move(original, to: target), "different-app geometry does not cause same-app collision refusal")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.focusedWindow()!
        expect(original.supported, "production focused read resolves native identity from full snapshot")
        access.beforeValues = { access.focus = 2 }
        expect(!backend.moveFocused(original, to: target) && access.writes.isEmpty,
               "focus lost immediately before write preparation completion prevents all writes")
        expect(access.trace.suffix(5) == ["values", "frontmost", "root:1", "timeout:-1", "focused:-1"],
               "focus is rechecked after payload creation immediately before first write")
        access.beforeValues = nil; access.focus = 1; access.trace = []
        expect(backend.moveFocused(original, to: target), "focused move succeeds after fresh identity and focus validation")
        expect(access.trace.suffix(5) == ["focused:-1", "write:position:1", "write:size:1", "write:position:1", "frame:1"],
               "focus recheck, position-size-position, readback order is exact")
    }
    for phase in 1...3 {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.windows()[0]
        access.failWrite = phase; access.trace = []
        expect(!backend.move(original, to: target), "write failure phase \(phase) reports failure")
        expect(access.writes == Array([.position, .size, .position].prefix(phase)),
               "write failure phase \(phase) short-circuits remaining writes")
        expect(access.trace.last == "write:\(phase == 2 ? "size" : "position"):1",
               "write failure phase \(phase) does not perform verification read")
    }
    for fact in ["title", "minimized", "fullScreen"] {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.windows()[0]
        var reads = 0
        access.beforeString = { element, attribute in
            guard fact == "title", attribute == .title else { return }
            reads += 1
            if reads == 2 { access.records[element]?.title = "Renamed after discovery" }
        }
        access.beforeBool = { element, attribute in
            guard (fact == "minimized" && attribute == .minimized) || (fact == "fullScreen" && attribute == .fullScreen) else { return }
            reads += 1
            if reads == 2 {
                if attribute == .minimized { access.records[element]?.minimized = true }
                else { access.records[element]?.fullScreen = true }
            }
        }
        expect(!backend.move(original, to: target) && access.writes.isEmpty,
               "late \(fact) change after fresh discovery is rechecked before writing")
        expect(!access.trace.contains("values"), "late \(fact) refusal precedes write payload preparation")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.windows()[0]
        access.makeValues = false
        expect(!backend.moveFocused(original, to: target) && access.writes.isEmpty,
               "native write payload creation failure prevents all writes")
        expect(!access.trace.contains("frontmost"), "payload creation failure precedes focus recheck")
    }
    for mode in ["exact", "constrained", "unreadable"] {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        let original = try backend.windows()[0]
        access.adjustPositionOnResize = true
        access.constrainSize = mode == "constrained"
        access.unreadableAfterWrite = mode == "unreadable"
        expect(backend.move(original, to: target) == (mode == "exact"),
               "\(mode) readback uses exact geometry, without tolerance or assumed write success")
        expect(access.writes == [.position, .size, .position] && access.records[1]?.frame?.origin == target.origin,
               "\(mode) readback follows correction of resize-induced position shift")
    }
    for fact in ["subrole", "minimized", "fullScreen", "position", "size", "offScreen", "layer"] {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        switch fact {
        case "subrole": access.records[1]?.subrole = nil
        case "minimized": access.records[1]?.minimized = nil
        case "fullScreen": access.records[1]?.fullScreen = nil
        case "position": access.records[1]?.positionSettable = false
        case "size": access.records[1]?.sizeSettable = false
        case "offScreen": access.entries?[0].frame = other
        default: access.entries?[0].layer = 1
        }
        let snapshot = try backend.windows()
        expect(snapshot.count == 1 && !snapshot[0].supported, "\(fact) remains conservatively unsupported")
        expect(!backend.move(snapshot[0], to: target) && access.writes.isEmpty, "\(fact) cannot write")
    }
    do {
        let access = ExecutionTestAccess(), backend: WindowExecution<ExecutionTestAccess>
        backend = WindowExecution(access: access)
        access.apps += [WindowApplication(pid: 99, bundle: "self"), WindowApplication(pid: 3, bundle: nil), WindowApplication(pid: 4, bundle: "not.visible")]
        access.entries? += [.init(pid: 99, frame: other), .init(pid: 3, frame: other)]
        let snapshot = try backend.windows()
        expect(snapshot.count == 1 && !access.trace.contains("root:99") && !access.trace.contains("root:3") && !access.trace.contains("root:4"),
               "discovery excludes own process, missing bundle and absent inventory PID")
        access.frontmost = WindowApplication(pid: 99, bundle: "self")
        let focused = try backend.focusedWindow()
        expect(focused == nil, "own application cannot be shortcut focus")
    }
}
