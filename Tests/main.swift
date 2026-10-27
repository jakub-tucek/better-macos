import AppKit
import SwiftUI
import CStrafe
import CoreBluetooth
import IOKit.pwr_mgt

if let index = CommandLine.arguments.firstIndex(of: "--deployment-restart-fixture"), index + 2 < CommandLine.arguments.count {
    try runDeploymentRestartFixture(mode: CommandLine.arguments[index + 1], suite: CommandLine.arguments[index + 2])
    exit(0)
}

if CommandLine.arguments.contains("--deployment-tests") {
    runDeploymentHealthTests()
    exit(0)
}

if CommandLine.arguments.contains("--presentation-tests") {
    runPresentationDisplayRefreshTests()
    exit(0)
}

if CommandLine.arguments.contains("--window-execution-tests") {
    runWindowExecutionTests()
    exit(0)
}

if CommandLine.arguments.contains("--window-shortcut-tests") {
    runWindowShortcutTests()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--window-palette-fixtures"), index + 1 < CommandLine.arguments.count {
    try renderWindowActionPaletteFixtures(directory: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--login-ui-fixtures"), index + 1 < CommandLine.arguments.count {
    try renderLoginUIFixtures(directory: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--release-ui-fixtures"), index + 1 < CommandLine.arguments.count {
    try renderReleaseUIFixtures(directory: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--compact-ui-fixtures"), index + 1 < CommandLine.arguments.count {
    try renderCompactUIFixtures(directory: CommandLine.arguments[index + 1])
    exit(0)
}

// Explicit, bounded OS probe; never part of the normal isolated suite.
if CommandLine.arguments.contains("--awake-power-probe") {
    let backend = SystemPowerAssertions()
    var owned: [IOPMAssertionID] = []
    defer { for id in owned { try? backend.release(id) } }
    func listsBothOwnedTypes(_ listing: String) -> Bool {
        let lines = listing.components(separatedBy: "\n").filter {
            $0.contains("pid \(ProcessInfo.processInfo.processIdentifier)(isolated-tests)")
        }
        return ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"].allSatisfy { type in
            lines.contains { $0.contains(type) }
        }
    }
    for display in [false, true] { owned.append(try backend.create(display: display, timeout: 3)) }
    let initialListing = try CommandRunner().run("/usr/bin/pmset", ["-g", "assertions"])
    print(initialListing)
    guard listsBothOwnedTypes(initialListing) else {
        for ownedID in owned { try? backend.release(ownedID) }
        throw ToggleError(message: "Both created assertion types must appear in pmset")
    }
    Thread.sleep(forTimeInterval: 8)
    let expiredListing = try CommandRunner().run("/usr/bin/pmset", ["-g", "assertions"])
    print(expiredListing)
    for id in owned {
        let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        print("Expired assertion properties: \(String(describing: properties))")
        guard !expiredListing.contains("pid \(ProcessInfo.processInfo.processIdentifier)(isolated-tests)") else {
            for ownedID in owned { try? backend.release(ownedID) }
            throw ToggleError(message: "OS timeout did not turn assertion off within eight seconds")
        }
        try backend.setTimeout(id, seconds: 3)
    }
    let renewedListing = try CommandRunner().run("/usr/bin/pmset", ["-g", "assertions"])
    guard listsBothOwnedTypes(renewedListing) else {
        for ownedID in owned { try? backend.release(ownedID) }
        throw ToggleError(message: "Both renewed assertion types must appear in pmset")
    }
    for id in owned { try backend.release(id) }
    owned.removeAll()
    let releasedListing = try CommandRunner().run("/usr/bin/pmset", ["-g", "assertions"])
    print(releasedListing)
    guard !releasedListing.contains("pid \(ProcessInfo.processInfo.processIdentifier)(isolated-tests)") else {
        throw ToggleError(message: "Released assertions still listed")
    }
    print("Bounded keep-awake OS probe passed; all owned assertions released.")
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--watchdog"), index + 1 < CommandLine.arguments.count {
    exit(SafetyWatchdog.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)))
}
if let index = CommandLine.arguments.firstIndex(of: "--watchdog-fixture"), index + 2 < CommandLine.arguments.count {
    if CommandLine.arguments.contains("--expect-bundle"), Bundle.main.bundleIdentifier != CommandLine.arguments[index + 1] { exit(76) }
    let supervisor = SafetySupervisor(domain: CommandLine.arguments[index + 1], timeout: 0.75,
                                      root: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true))
    try supervisor.start()
    // Deliberately stall THIS expendable child, never the real app or desktop.
    Thread.sleep(forTimeInterval: 4)
    supervisor.stop()
    exit(77)
}

let speaker = BluetoothDevice(address: "00-00-00-00-00-01", name: "Test speakers", connected: false)
let headphones = BluetoothDevice(address: "00-00-00-00-00-02", name: "Test headphones", connected: true)
let keyboard = BluetoothDevice(address: "00-00-00-00-00-03", name: "Test keyboard", connected: true)
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
    print("PASS: \(message)")
}

if CommandLine.arguments.contains("--presentation-display-refresh-regressions") {
    runPresentationDisplayRefreshTests()
    print("\(checks) presentation display refresh regression checks passed")
    exit(0)
}

if CommandLine.arguments.contains("--bluetooth-discovery-visibility-regressions") {
    try runBluetoothErrorRecoveryTests()
    print("\(checks) Bluetooth discovery visibility and recovery checks passed")
    exit(0)
}

runWindowShortcutTests()
runWindowExecutionTests()
runBluetoothCycleDeliveryTests()

final class FakeWindowBackend: WindowPositionBackend {
    var permitted = true
    var screens = [WindowDisplay(id: "A", bounds: CGRect(x: 0, y: 25, width: 1000, height: 700))]
    var items = [PositionedWindow(token: "1", app: "test.editor", title: "Document", frame: CGRect(x: 800, y: 600, width: 500, height: 400), supported: true)]
    var moves: [CGRect] = []
    var succeeds = true
    var failDiscovery = false
    func requestPermission() {}
    func displays() -> [WindowDisplay] { screens }
    func windows() throws -> [PositionedWindow] {
        if failDiscovery { throw ToggleError(message: "Injected discovery timeout") }
        return items
    }
    func move(_ window: PositionedWindow, to frame: CGRect) -> Bool {
        guard let index = items.firstIndex(where: { $0.token == window.token }),
              items.filter({ $0.app == window.app && $0.frame == items[index].frame }).count == 1,
              AXWindowPositionBackend.destinationIsClear(frame, for: window, in: items) else { return false }
        moves.append(frame)
        if succeeds { items[index].frame = frame }
        return succeeds
    }
}
let failedWindowServer = AXWindowPositionBackend(permissionCheck: { true }, windowInfo: { nil })
do { _ = try failedWindowServer.windows(); expect(false, "WindowServer failure must throw") }
catch { expect(error.localizedDescription.contains("WindowServer discovery failed"), "real adapter throws injected WindowServer discovery failure without live calls") }
var revokedWindowInfoReads = 0
let revokedWindowAccess = AXWindowPositionBackend(permissionCheck: { false }, windowInfo: { revokedWindowInfoReads += 1; return [] })
do { _ = try revokedWindowAccess.windows(); expect(false, "revoked Accessibility permission must throw") }
catch { expect(revokedWindowInfoReads == 0 && error.localizedDescription.contains("permission"), "real adapter rejects revoked permission without returning an empty snapshot") }
let windowDomain = "test.windows.\(UUID().uuidString)"
let windowDefaults = UserDefaults(suiteName: windowDomain)!
let windowBackend = FakeWindowBackend()
let windowModule = WindowPositions(backend: windowBackend, defaults: windowDefaults, schedule: { $0() })
windowModule.reconcile(ready: true, settled: true)
windowModule.save("Desk")
expect(windowModule.layouts.count == 1 && !windowModule.automatic, "window layout saves; automation defaults off")
let savedWindowID = windowModule.selected
let savedWindowFrame = windowModule.layouts[0].windows[0].frame
expect(windowModule.rename(savedWindowID, to: "  Renamed desk  ") && windowModule.layouts[0].name == "Renamed desk",
       "layout rename trims and updates the saved name")
expect(windowModule.selected == savedWindowID && windowModule.layouts[0].windows[0].frame == savedWindowFrame && windowBackend.moves.isEmpty,
       "rename preserves identity, automatic selection and geometry without moving windows")
expect(!windowModule.rename(savedWindowID, to: " \n ") && !windowModule.rename("missing", to: "Other"),
       "empty and missing layout renames leave saved data unchanged")
let renamedWindows = WindowPositions(backend: windowBackend, defaults: windowDefaults)
expect(renamedWindows.layouts[0].name == "Renamed desk" && renamedWindows.selected == savedWindowID,
       "layout rename persists across recreation")
expect(windowModule.canCapture, "window actions become ready with isolated backend permission")
windowBackend.permitted = false
expect(!windowModule.canCapture, "revoked window permission disables primary actions")
windowBackend.permitted = true
expect(Set(DashboardTab.features) == Set(DashboardTab.allCases.filter { $0 != .modules }) && DashboardTab.features.contains(.mouse),
       "settings setup list includes every feature including Mouse")
expect(DashboardTab.features.allSatisfy { !$0.symbol.isEmpty } && DashboardTab.keepAwake.symbol == "pill.fill",
       "feature navigation provides icons and Keep awake shares the pill symbol")
expect(DashboardTab.quickFeatures == [.monitors, .keepAwake, .audio, .clipboard, .windows],
       "quick home contains everyday actions, not configuration-only modules")
expect(Set(AppModule.allCases.map(\.dashboardFeature)) == Set(DashboardTab.features),
       "Settings module setup buttons cover every feature without a dropdown")
var navigation = DashboardNavigation.launch(arguments: ["app", "--show-dashboard"])
expect(navigation.context == .quick && navigation.feature == nil, "default launch opens quick home")
navigation.openQuick(.audio)
expect(navigation.context == .quick && navigation.feature == .audio, "home opens focused Audio quick controls")
navigation.openSettings()
expect(navigation.context == .settings && navigation.feature == nil, "gear opens Settings list, not feature dropdown")
navigation.openSetup(.audio)
expect(navigation.isSetup && navigation.feature == .audio, "same module has a separate setup context")
navigation.back()
expect(navigation.isSetup && navigation.feature == nil, "setup Back returns to Settings list")
navigation.back()
expect(!navigation.isSetup && navigation.feature == .audio, "Settings Back restores prior quick panel")
navigation.back()
expect(navigation.context == .quick && navigation.feature == nil, "quick Back returns home")
navigation.openQuick(.mouse)
expect(navigation.feature == nil, "configuration-only modules cannot enter quick context")
navigation.openSettings()
navigation.openSettings()
navigation.back()
expect(!navigation.isSetup && navigation.feature == nil, "repeated gear preserves home return target")
navigation.openQuick(.keepAwake)
navigation.openSetup(.keepAwake)
navigation.back()
navigation.back()
expect(!navigation.isSetup && navigation.feature == .keepAwake, "direct Setup returns through Settings to prior quick panel")
for feature in DashboardTab.features {
    navigation.show(feature)
    expect(navigation.feature == feature && navigation.isSetup == !DashboardTab.quickFeatures.contains(feature),
           "explicit entry uses appropriate context for \(feature.rawValue)")
}
let launchFlags: [(String, DashboardTab)] = [
    ("--show-monitors", .monitors), ("--show-bluetooth", .bluetooth),
    ("--show-spaces", .spaces), ("--show-menu-bar", .menuBar),
    ("--show-keyboard", .keyboard), ("--show-keep-awake", .keepAwake),
    ("--show-mouse", .mouse), ("--show-audio", .audio),
    ("--show-clipboard", .clipboard), ("--show-windows", .windows)
]
for (flag, feature) in launchFlags {
    let launched = DashboardNavigation.launch(arguments: ["app", "--show-dashboard", flag])
    expect(launched.feature == feature && launched.isSetup == !DashboardTab.quickFeatures.contains(feature),
           "launch flag \(flag) retains explicit feature entry")
}
let modulesLaunch = DashboardNavigation.launch(arguments: ["--show-modules"])
expect(modulesLaunch.isSetup && modulesLaunch.feature == nil, "show-modules opens Settings root")
let navigationModel = DashboardModel()
navigationModel.enabledModules = []
for feature in DashboardTab.quickFeatures {
    navigationModel.navigation.openQuick(feature)
    expect(navigationModel.navigation.feature == feature, "disabled \(feature.rawValue) remains navigable")
    navigationModel.navigation.openSettings()
    navigationModel.navigation.back()
    expect(navigationModel.navigation.feature == feature && !navigationModel.navigation.isSetup,
           "disabled-module Enable in settings retains quick return target")
}
expect(!navigationModel.displayControlsReachable, "fully disabled idle display modules show enable guidance")
navigationModel.pendingArrangement = true
expect(navigationModel.displayControlsReachable, "pending layout recovery stays reachable with modules disabled")
navigationModel.pendingArrangement = false
navigationModel.disabledMonitorCount = 1
expect(navigationModel.displayControlsReachable, "disabled display recovery stays reachable")
navigationModel.disabledMonitorCount = 0
navigationModel.countdowns = ["layout": 10]
expect(navigationModel.displayControlsReachable, "in-progress confirmation remains reachable")
navigationModel.countdowns = [:]
navigationModel.stoppingModules = [.arrangement]
expect(navigationModel.displayControlsReachable, "in-progress module restoration remains reachable")
navigationModel.stoppingModules = []
navigationModel.monitorBusy = true
expect(navigationModel.displayControlsReachable, "in-flight display change cannot disappear behind disabled guidance")
windowModule.restore(windowModule.selected)
expect(windowBackend.moves == [CGRect(x: 500, y: 325, width: 500, height: 400)], "restore clamps to available bounds")
windowBackend.items.append(windowBackend.items[0])
windowModule.restore(windowModule.selected)
expect(windowBackend.moves.count == 1 && windowModule.summary.contains("ambiguous 1"), "ambiguous current windows never move")
windowBackend.items.removeLast()
windowModule.exclusions = "test.editor"
windowModule.restore(windowModule.selected)
expect(windowBackend.moves.count == 1 && windowModule.summary.contains("excluded 1"), "excluded apps never move")
windowModule.exclusions = ""
windowBackend.permitted = false
windowModule.restore(windowModule.selected)
expect(windowBackend.moves.count == 1, "permission denial blocks writes")
windowBackend.permitted = true
windowModule.automatic = true
windowModule.wake()
windowModule.reconcile(ready: false, settled: false)
expect(windowBackend.moves.count == 1, "wake waits for display settle")
windowModule.reconcile(ready: false, settled: true)
expect(windowBackend.moves.count == 1, "pending confirmation blocks automatic restoration")
windowModule.reconcile(ready: true, settled: true)
windowModule.reconcile(ready: true, settled: true)
expect(windowBackend.moves.count == 2, "wake restores once after confirmation; repeated snapshots do not move")
windowModule.wake()
windowModule.paused = true
windowModule.reconcile(ready: true, settled: true)
expect(windowBackend.moves.count == 2, "pause cancels pending wake")
windowModule.paused = false
windowBackend.screens = []
windowModule.reconcile(ready: true, settled: true)
windowBackend.screens = windowModule.layouts[0].displays
windowModule.reconcile(ready: true, settled: true)
expect(windowBackend.moves.count == 3, "reconnected display set restores once")
windowModule.wake()
windowModule.stop()
windowModule.reconcile(ready: true, settled: true)
expect(windowBackend.moves.count == 3, "unload cancels pending work")
let reloadedWindows = WindowPositions(backend: windowBackend, defaults: windowDefaults)
expect(reloadedWindows.layouts.count == 1 && reloadedWindows.automatic, "layouts and automation survive unload")
windowDefaults.removePersistentDomain(forName: windowDomain)

let matchingDomain = "test.windows.matching.\(UUID().uuidString)"
let matchingDefaults = UserDefaults(suiteName: matchingDomain)!
let matchingBackend = FakeWindowBackend()
let matchingModule = WindowPositions(backend: matchingBackend, defaults: matchingDefaults, schedule: { $0() })
matchingModule.reconcile(ready: true, settled: true)
matchingModule.save("Matching")
matchingBackend.failDiscovery = true
matchingModule.save("Failed capture")
expect(matchingModule.layouts.count == 1 && matchingModule.summary.contains("discovery failed"), "incomplete discovery never persists or selects an empty layout")
matchingModule.restore(matchingModule.selected)
expect(matchingModule.summary.contains("discovery failed") && matchingBackend.moves.isEmpty, "incomplete discovery is reported distinctly from missing windows")
matchingBackend.failDiscovery = false
matchingBackend.items[0].title = "Different document"
matchingModule.restore(matchingModule.selected)
expect(matchingBackend.moves.isEmpty && matchingModule.summary.contains("missing 1"), "changed title does not guess another document")
matchingBackend.items[0].title = "Document"
matchingBackend.items[0].supported = false
matchingModule.restore(matchingModule.selected)
expect(matchingBackend.moves.isEmpty && matchingModule.summary.contains("unsupported 1"), "unsupported current windows are reported without writes")
matchingBackend.items[0].supported = true
matchingBackend.succeeds = false
matchingModule.restore(matchingModule.selected)
expect(matchingModule.summary.contains("failed 1"), "backend refusal is reported as failure")
matchingBackend.moves = []
matchingBackend.succeeds = true
matchingBackend.items.append(matchingBackend.items[0])
matchingModule.save("Duplicate saved titles")
matchingBackend.items.removeLast()
matchingModule.restore(matchingModule.selected)
expect(matchingBackend.moves.isEmpty && matchingModule.summary.contains("ambiguous 2"), "saved duplicates cannot both target one current window")
matchingDefaults.removePersistentDomain(forName: matchingDomain)

let queuedDomain = "test.windows.queued.\(UUID().uuidString)"
let queuedDefaults = UserDefaults(suiteName: queuedDomain)!
let queuedBackend = FakeWindowBackend()
queuedBackend.items.append(PositionedWindow(token: "2", app: "test.browser", title: "Page", frame: CGRect(x: 10, y: 30, width: 200, height: 200), supported: true))
var windowTasks: [() -> Void] = []
let queuedWindows = WindowPositions(backend: queuedBackend, defaults: queuedDefaults, schedule: { windowTasks.append($0) })
let windowHost = AppDelegate(windowPositions: queuedWindows)
var windowState = SystemControlLifecycle.State(watchdogReady: true, displaySettling: false, displayOperation: false,
    pendingConfirmation: false, layoutFresh: true, cursorRequested: false, arrangementEnabled: false, layout: [])
windowHost.reconcileWindows(state: windowState)
queuedWindows.save("Two apps")
queuedWindows.restore(queuedWindows.selected)
expect(queuedBackend.moves.isEmpty, "host restore yields before its first write")
windowTasks.removeFirst()()
expect(queuedBackend.moves.count == 1, "restore writes only one window per scheduled step")
windowState.pendingConfirmation = true
windowHost.reconcileWindows(state: windowState)
windowTasks.removeFirst()()
expect(queuedBackend.moves.count == 1, "host confirmation cancels remaining queued writes")
windowState.pendingConfirmation = false
windowHost.reconcileWindows(state: windowState)
queuedWindows.automatic = true
queuedWindows.connectionChanged()
queuedWindows.connectionChanged()
windowState.displaySettling = true
windowHost.reconcileWindows(state: windowState)
expect(windowTasks.isEmpty, "connection callback storm does not restore during host settling")
windowState.displaySettling = false
windowHost.reconcileWindows(state: windowState)
while !windowTasks.isEmpty { windowTasks.removeFirst()() }
expect(queuedBackend.moves.count == 3, "same-final-set rapid reconnect restores both apps exactly once")
windowHost.reconcileWindows(state: windowState)
expect(windowTasks.isEmpty, "settled host refresh does not repeat reconnect restore")
queuedWindows.restore(queuedWindows.selected)
queuedBackend.screens[0].bounds.size.width = 900
windowTasks.removeFirst()()
expect(queuedBackend.moves.count == 3, "queued write rejects changed display bounds without waiting for notifications")
let identicalFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
expect(!AXWindowPositionBackend.hasUniqueGeometry(identicalFrame, in: [identicalFrame, identicalFrame]), "same-geometry off-Space sibling makes visibility correlation ambiguous")
queuedWindows.stop()
queuedDefaults.removePersistentDomain(forName: queuedDomain)

let swapDomain = "test.windows.swap.\(UUID().uuidString)"
let swapDefaults = UserDefaults(suiteName: swapDomain)!
let swapBackend = FakeWindowBackend()
let leftFrame = CGRect(x: 10, y: 30, width: 200, height: 200)
let rightFrame = CGRect(x: 400, y: 30, width: 200, height: 200)
swapBackend.items = [PositionedWindow(token: "left", app: "editor", title: "One", frame: leftFrame, supported: true),
                     PositionedWindow(token: "right", app: "editor", title: "Two", frame: rightFrame, supported: true)]
let swapModule = WindowPositions(backend: swapBackend, defaults: swapDefaults, schedule: { $0() })
swapModule.reconcile(ready: true, settled: true)
swapModule.save("Two documents")
swapBackend.items[0].frame = rightFrame
swapBackend.items[1].frame = leftFrame
swapModule.restore(swapModule.selected)
expect(swapBackend.items[0].frame == leftFrame && swapBackend.items[1].frame == rightFrame && swapBackend.moves.count == 3,
       "same-app swapped windows restore through safe temporary geometry without ambiguity")
expect(swapModule.summary.contains("Restored 2"), "temporary parking is not double counted in result summary")
swapBackend.items[0].frame = rightFrame
swapBackend.items[1].frame = leftFrame
swapBackend.moves = []
swapBackend.succeeds = false
swapModule.restore(swapModule.selected)
expect(swapBackend.moves.count == 1 && swapBackend.items[0].frame == rightFrame && swapBackend.items[1].frame == leftFrame,
       "failed prerequisite aborts collision-dependent subsequent moves")
expect(!AXWindowPositionBackend.destinationIsClear(leftFrame, for: swapBackend.items[0], in: swapBackend.items),
       "fresh destination occupancy rejects an externally moved same-app sibling")
let thirdFrame = CGRect(x: 700, y: 30, width: 200, height: 200)
swapBackend.items[0].frame = thirdFrame
swapBackend.items[1].frame = leftFrame
swapModule.save("Dependent ordinary moves")
swapBackend.items[0].frame = leftFrame
swapBackend.items[1].frame = rightFrame
swapBackend.moves = []
swapModule.restore(swapModule.selected)
expect(swapBackend.moves.count == 1 && swapBackend.items[1].frame == rightFrame && swapModule.summary.contains("failed 1"),
       "failed ordinary prerequisite stops later moves into its still-occupied destination")
swapDefaults.removePersistentDomain(forName: swapDomain)

let displaySetDomain = "test.windows.display-sets.\(UUID().uuidString)"
let displaySetDefaults = UserDefaults(suiteName: displaySetDomain)!
let displaySetBackend = FakeWindowBackend()
displaySetBackend.screens.append(WindowDisplay(id: "B", bounds: CGRect(x: 1000, y: -400, width: 1200, height: 900)))
displaySetBackend.screens.append(WindowDisplay(id: "C", bounds: CGRect(x: -1000, y: 25, width: 1000, height: 700)))
displaySetBackend.items = [PositionedWindow(token: "display-B", app: "editor", title: "B document", frame: CGRect(x: 1200, y: -300, width: 400, height: 300), supported: true)]
let displaySetModule = WindowPositions(backend: displaySetBackend, defaults: displaySetDefaults, schedule: { $0() })
displaySetModule.reconcile(ready: true, settled: true)
displaySetModule.save("A B C")
let threeDisplayLayout = displaySetModule.selected
displaySetBackend.screens[1].bounds.origin.x = 1400
displaySetModule.restore(threeDisplayLayout)
expect(displaySetBackend.moves.last == CGRect(x: 1600, y: -300, width: 400, height: 300), "window frame follows saved display identity after topology translation")
displaySetModule.save("Alternative A B C")
displaySetModule.selected = ""
displaySetModule.automatic = true
displaySetBackend.moves = []
displaySetModule.wake()
displaySetModule.reconcile(ready: true, settled: true)
expect(displaySetBackend.moves.isEmpty && displaySetModule.summary.contains("unique saved layout"), "multiple layouts require an explicit selection rather than guessing")
displaySetModule.selected = threeDisplayLayout
displaySetBackend.screens.remove(at: 1)
displaySetModule.reconcile(ready: true, settled: true)
expect(displaySetModule.layouts.count == 2 && displaySetBackend.moves.isEmpty, "A B C to A C retains layouts without moving windows for a mismatched set")
displaySetBackend.screens.insert(WindowDisplay(id: "B", bounds: CGRect(x: 1400, y: -400, width: 1200, height: 900)), at: 1)
displaySetModule.reconcile(ready: true, settled: true)
expect(displaySetBackend.moves.count == 1, "A C to A B C restores the explicitly selected display-set layout once")
displaySetModule.reconcile(ready: true, settled: true)
expect(displaySetBackend.moves.count == 1, "repeated A B C snapshot does not repeat restoration")
displaySetDefaults.removePersistentDomain(forName: displaySetDomain)
runHostTransactionsTests()
runLoginServiceTests()
runKeepAwakeFeatureTests()
try runDiagnosticsTests()
try runActivityTests()
try runUITests()
try RegisteredFeatureTests.run()
runScreenEdgeAccessTests()
runSetupResumeTests()
runDeploymentHealthTests()
runQuitGuardAccessTests()
try runClipboardTests()

final class FakeRunner: CommandRunning {
    var current: [BluetoothDevice] = [speaker]
    var audioOutputs = Set([speaker.name])
    var commands: [[String]] = []
    var headphonesArrive = false
    var failConnect = false
    var failedAddresses = Set<String>()
    var powerOn = true
    var failAudioObservation = false
    var failPostConnectAudioObservation = false
    var failDeviceObservation = false

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        commands.append([executable] + arguments)
        switch arguments.first {
        case "--power":
            if arguments.count > 1 { powerOn = arguments[1] == "1" }
            return powerOn ? "1" : "0"
        case "--paired":
            if failDeviceObservation { throw ToggleError(message: "Observation failed") }
            let json = current.map { ["address": $0.address, "name": $0.name, "connected": $0.connected] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        case "--connect", "--disconnect":
            let address = arguments[1]
            if failConnect || failedAddresses.contains(address) { throw ToggleError(message: "Connection failed") }
            current = current.map { device in
                device.address == address ? BluetoothDevice(address: device.address, name: device.name, connected: arguments[0] == "--connect") : device
            }
            if headphonesArrive { current.append(headphones); audioOutputs.insert(headphones.name) }
            return ""
        case "-a":
            if failAudioObservation { throw ToggleError(message: "Audio observation failed") }
            if failPostConnectAudioObservation && current.contains(where: { $0.address == speaker.address && $0.connected }) {
                throw ToggleError(message: "Post-connect audio observation failed")
            }
            return audioOutputs.sorted().joined(separator: "\n")
        case "-t": return ""
        default: throw ToggleError(message: "Unexpected command")
        }
    }

    var connections: [[String]] { commands.filter { $0.contains("--connect") } }
    var audioSwitches: [[String]] { commands.filter { $0.contains("-s") } }
}

func backend(_ fake: FakeRunner, audioTool: String? = "audio") -> BluetoothBackend {
    BluetoothBackend(runner: fake, blueutil: "blueutil", audioTool: audioTool, waitForConnection: {},
                     routeOutput: { fake.commands.append(["routing-owner", "-s", $0]) })
}

runAudioTests()

let config = BluetoothConfiguration(enabled: true, autoAddresses: [speaker.address], protectOtherAudio: true, switchAudioOutput: true)
expect(BluetoothPolicy.shouldPause(target: speaker, devices: [speaker, headphones], audioOutputs: [headphones.name]), "Connected headphones pause auto-connect")
expect(!BluetoothPolicy.shouldPause(target: speaker, devices: [speaker, keyboard], audioOutputs: [speaker.name]), "A keyboard does not block audio reconnect")
expect(BluetoothPolicy.shouldPause(target: speaker, devices: [speaker, keyboard], audioOutputs: nil), "No audio discovery protects all other connections")
expect(BluetoothPolicy.shouldPause(target: speaker, devices: [speaker, headphones], audioOutputs: [], knownAudioAddresses: [headphones.address]),
       "Known headphones are protected before their audio output is registered")

do {
    let fake = FakeRunner()
    let devices = try backend(fake).reconcile(config)
    expect(devices.first?.connected == true, "Selected disconnected device reconnects")
    expect(fake.connections.count == 1 && fake.connections[0].last == speaker.address, "Only selected device is probed")
    expect(fake.audioSwitches.count == 1, "Reconnected audio becomes output when safe")

    let headphoneCase = FakeRunner()
    headphoneCase.current.append(headphones)
    headphoneCase.audioOutputs.insert(headphones.name)
    _ = try backend(headphoneCase).reconcile(config)
    expect(headphoneCase.connections.isEmpty && headphoneCase.audioSwitches.isEmpty, "Headphones prevent connection and audio takeover")

    let keyboardCase = FakeRunner()
    keyboardCase.current.append(keyboard)
    _ = try backend(keyboardCase).reconcile(config)
    expect(keyboardCase.connections.count == 1, "Keyboard permits selected audio reconnection")

    let conservativeCase = FakeRunner()
    conservativeCase.current.append(keyboard)
    _ = try backend(conservativeCase, audioTool: nil).reconcile(config)
    expect(conservativeCase.connections.isEmpty, "Missing audio tool conservatively pauses")

    let race = FakeRunner()
    race.headphonesArrive = true
    _ = try backend(race).reconcile(config)
    expect(race.connections.count == 1 && race.audioSwitches.isEmpty, "Arriving headphones prevent post-connect output change")

    let alreadyConnected = FakeRunner()
    alreadyConnected.current = [BluetoothDevice(address: speaker.address, name: speaker.name, connected: true)]
    _ = try backend(alreadyConnected).reconcile(config)
    expect(alreadyConnected.connections.isEmpty && alreadyConnected.audioSwitches.isEmpty, "Already connected device is left alone")

    var pausedConfig = config
    pausedConfig.enabled = false
    let paused = FakeRunner()
    _ = try backend(paused).reconcile(pausedConfig)
    expect(paused.connections.isEmpty, "Global pause performs observation only")

    var emptyConfig = config
    emptyConfig.autoAddresses = []
    let empty = FakeRunner()
    _ = try backend(empty).reconcile(emptyConfig)
    expect(empty.connections.isEmpty, "Unselected devices are never probed")

    let failed = FakeRunner()
    failed.failConnect = true
    do { _ = try backend(failed).reconcile(config); expect(false, "Failed connection must throw") }
    catch { expect(failed.audioSwitches.isEmpty, "Failed connection never switches output") }

    let audioFailure = FakeRunner()
    audioFailure.failAudioObservation = true
    do { _ = try backend(audioFailure).reconcile(config); expect(false, "Failed audio observation must throw") }
    catch { expect(audioFailure.connections.isEmpty, "Failed audio observation aborts reconnection") }

    let deviceFailure = FakeRunner()
    deviceFailure.failDeviceObservation = true
    do { _ = try backend(deviceFailure).reconcile(config); expect(false, "Failed device observation must throw") }
    catch { expect(deviceFailure.connections.isEmpty, "Failed device observation aborts reconnection") }

    let manual = FakeRunner()
    _ = try backend(manual).setConnected(true, address: speaker.address)
    _ = try backend(manual).setConnected(false, address: speaker.address)
    expect(manual.current.first?.connected == false, "Manual connect/disconnect works without audio switching")
    expect(manual.audioSwitches.isEmpty, "Manual connection does not silently change audio")

    let multiple = FakeRunner()
    multiple.current.append(BluetoothDevice(address: headphones.address, name: headphones.name, connected: false))
    multiple.failedAddresses = [speaker.address]
    var multipleConfig = config
    multipleConfig.autoAddresses = [speaker.address, headphones.address]
    multipleConfig.switchAudioOutput = false
    let multipleDevices = try backend(multiple).reconcile(multipleConfig)
    expect(multipleDevices.first(where: { $0.address == headphones.address })?.connected == true,
           "An unreachable first target does not starve another available target")

    let poweredOff = FakeRunner()
    poweredOff.powerOn = false
    _ = try backend(poweredOff).reconcile(config)
    expect(poweredOff.connections.isEmpty, "A powered-off Bluetooth radio never starts connection attempts")
} catch { fputs("Unexpected failure: \(error)\n", stderr); exit(1) }

let testDomain = "better-macos.tests.\(UUID().uuidString)"
let testDefaults = UserDefaults(suiteName: testDomain)!
testDefaults.set([speaker.address], forKey: "bluetooth.autoAddresses")
testDefaults.set(false, forKey: "bluetooth.autoEnabled")
let moduleRunner = FakeRunner()
moduleRunner.current = [BluetoothDevice(address: speaker.address, name: speaker.name, connected: true)]
let testModule = BluetoothModule(defaults: testDefaults, backend: backend(moduleRunner), importLegacyConfiguration: false,
                                 authorizationProvider: { .allowedAlways })
func waitForModule() {
    let deadline = Date().addingTimeInterval(2)
    while testModule.isBusy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(!testModule.isBusy, "Background Bluetooth operation completed")
}
testModule.poll()
waitForModule()
testModule.toggleConnection(speaker.address)
waitForModule()
let selectionPreserved = testModule.autoAddresses.contains(speaker.address)
testModule.poll()
testModule.toggleConnection(speaker.address)
waitForModule()
let queuedClickConnected = testModule.devices.first(where: { $0.address == speaker.address })?.connected == true
testDefaults.removePersistentDomain(forName: testDomain)
expect(selectionPreserved, "Manual connection actions do not silently rewrite auto-reconnect choices")
expect(queuedClickConnected, "A manual Connect click during discovery is queued, never silently dropped")
let deniedRunner = FakeRunner()
let deniedModule = BluetoothModule(backend: backend(deniedRunner), importLegacyConfiguration: false, authorizationProvider: { .denied })
deniedModule.poll()
expect(deniedRunner.commands.isEmpty, "Denied GUI Bluetooth access never launches misleading blueutil queries")
expect(deniedModule.radioPoweredOn == nil && deniedModule.reconnectSummary.contains("Bluetooth access required"),
       "Permission denial is not misreported as a powered-off radio")
expect(CommandRunner.timeout(for: "/opt/homebrew/bin/blueutil", arguments: ["--connect", "fixture"]) > 15,
       "Bluetooth connection timeout permits the OS's normal page timeout")
do {
    let stdout = try CommandRunner().run("/usr/bin/python3", ["-c", "import sys; print('[1,2]'); print('warning on stderr', file=sys.stderr)"])
    expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "[1,2]", "Stderr warnings cannot corrupt successful JSON output")
} catch { expect(false, "Command output integration test failed: \(error)") }

_ = NSApplication.shared
expect(BluetoothPresentation.summary(enabled: true, selected: [], devices: [speaker]).contains("Choose devices"),
       "Enabled automation with no targets explicitly requests device selection")
expect(BluetoothPresentation.summary(enabled: false, selected: [speaker.address], devices: [speaker]).contains("Paused: Test speakers"),
       "Paused automation still shows selected device names")
let dashboardModel = DashboardModel()
dashboardModel.devices = [speaker]
var selectionAction: (String, Bool)?
var closeRequests = 0
dashboardModel.onAutoDeviceChanged = { selectionAction = ($0, $1) }
dashboardModel.onClose = { closeRequests += 1 }
let selectionBinding = dashboardModel.autoReconnectBinding(for: speaker.address)
selectionBinding.wrappedValue = true
expect(dashboardModel.selectedAddresses.contains(speaker.address) && selectionAction?.0 == speaker.address && selectionAction?.1 == true,
       "Device auto-reconnect switch updates policy independently of physical connection")
expect(dashboardModel.devices.first?.connected == false, "Selecting auto-reconnect does not pretend device is connected")
expect(closeRequests == 0, "Toggling auto-reconnect does not request dashboard dismissal")
selectionBinding.wrappedValue = false
expect(dashboardModel.selectedAddresses.isEmpty, "Turning a device rule off is explicit and reflected immediately")

func switchImage(isOn: Bool) -> Data? {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let view = NSHostingView(rootView: BlueSwitch(label: "Test switch", isOn: .constant(isOn)).frame(width: 80, height: 50))
    window.contentView = view
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
}
// Rendering creates WindowServer/CoreAnimation resources. Keep it opt-in while
// investigating the system rendering stall; the normal suite stays non-rendering.
if CommandLine.arguments.contains("--render-ui") {
    let enabled = switchImage(isOn: true), disabled = switchImage(isOn: false)
    expect(enabled != nil && disabled != nil && enabled != disabled,
           "Native switch renders distinct on/off states without overriding system accent or inactive appearance")
}

// The real user's geometry: middle Dell is main; laptop is below the left screen.
let topologyBaseline = [
    DisplayPosition(uuid: "A", x: -2560, y: 0, width: 2560, height: 1440),
    DisplayPosition(uuid: "B", x: 0, y: 0, width: 2560, height: 1440),
    DisplayPosition(uuid: "C", x: 2560, y: 0, width: 1920, height: 1200),
    DisplayPosition(uuid: "Mac", x: -2560, y: 1440, width: 1512, height: 982)
]
let withoutMiddle = DisplayTopology.plan(topologyBaseline, active: ["A", "C", "Mac"], anchor: "A")
expect(withoutMiddle == [
    DisplayPosition(uuid: "A", x: 0, y: 0, width: 2560, height: 1440),
    DisplayPosition(uuid: "C", x: 2560, y: 0, width: 1920, height: 1200),
    DisplayPosition(uuid: "Mac", x: 0, y: 1440, width: 1512, height: 982)
], "Removing middle/main B joins A–C and keeps the Mac directly below A")
let alternateAnchor = DisplayTopology.plan(topologyBaseline, active: ["A", "C", "Mac"], anchor: "C")
expect(alternateAnchor?.first(where: { $0.uuid == "A" })?.x == -2560 &&
       alternateAnchor?.first(where: { $0.uuid == "Mac" })?.x == -2560,
       "A different main display changes the origin without changing physical topology")
let restored = DisplayTopology.plan(topologyBaseline, active: ["A", "B", "C", "Mac"], anchor: "B")
expect(restored == topologyBaseline, "Restoring B restores exact original positions and main-screen origin")
let partial = DisplayTopology.plan(topologyBaseline, active: ["A", "B", "Mac"], anchor: "B")
expect(partial == topologyBaseline.filter { $0.uuid != "C" }, "Restoring B while C stays off recovers the original A–B/Mac topology")
let twoDisabled = DisplayTopology.plan(topologyBaseline, active: ["A", "Mac"], anchor: "A")
expect(twoDisabled?.first(where: { $0.uuid == "Mac" })?.y == 1440,
       "Sequential disabling retains the original laptop attachment")
let vertical = [DisplayPosition(uuid: "A", x: 0, y: 0, width: 1000, height: 800),
                DisplayPosition(uuid: "B", x: 0, y: 800, width: 1000, height: 800),
                DisplayPosition(uuid: "C", x: 100, y: 1600, width: 900, height: 700)]
let compactVertical = DisplayTopology.plan(vertical, active: ["A", "C"], anchor: "A")
expect(compactVertical?.last?.x == 100 && compactVertical?.last?.y == 800,
       "Vertical middle-screen removal preserves horizontal offset and closes the gap")
let offsetRow = [DisplayPosition(uuid: "A", x: 0, y: 0, width: 1000, height: 800),
                 DisplayPosition(uuid: "B", x: 1000, y: 100, width: 800, height: 700),
                 DisplayPosition(uuid: "C", x: 1800, y: 200, width: 1200, height: 600)]
expect(DisplayTopology.plan(offsetRow, active: ["A", "C"], anchor: "A")?.last?.y == 200,
       "Uneven top edges retain their vertical alignment when a row is compacted")
expect(DisplayTopology.plan(topologyBaseline, active: ["A", "Unknown"], anchor: "A") == nil,
       "An unfamiliar screen cannot be arranged using the saved topology")
expect(DisplayTopology.plan([DisplayPosition(uuid: "legacy", x: 0, y: 0)], active: ["legacy"], anchor: "legacy") == nil,
       "Legacy layouts without dimensions do not guess monitor sizes")
do {
    let persisted = try JSONEncoder().encode(topologyBaseline)
    let decoded = try JSONDecoder().decode([DisplayPosition].self, from: persisted)
    expect(DisplayTopology.plan(decoded, active: ["A", "C", "Mac"], anchor: "A") == withoutMiddle,
           "Fresh-process layout planning survives a saved-baseline round trip")
    let legacy = try JSONDecoder().decode([DisplayPosition].self, from: Data("[{\"uuid\":\"old\",\"x\":0,\"y\":0}]".utf8))
    expect(legacy[0].width == nil, "Previously saved recovery positions remain decodable")
} catch { expect(false, "Saved topology decode failed: \(error)") }

let safeSpaces = SpacesModule()
let moduleSettingsDomain = "better-macos.modules-test.\(UUID().uuidString)"
let modulePreferences = UserDefaults(suiteName: moduleSettingsDomain)!
let moduleSettings = ModuleSettings(defaults: modulePreferences)
expect(moduleSettings.enabled == Set(AppModule.allCases), "Modules are available by default")
modulePreferences.set(["remembered-device"], forKey: "bluetooth.autoAddresses")
moduleSettings.set(.bluetooth, enabled: false)
expect(!ModuleSettings(defaults: modulePreferences).enabled.contains(.bluetooth), "Disabled modules stay off across host recreation")
expect(modulePreferences.stringArray(forKey: "bluetooth.autoAddresses") == ["remembered-device"], "Unloading a module preserves its feature settings")
moduleSettings.set(.monitors, enabled: false)
expect(moduleSettings.needsDisplays, "Arrangement alone keeps shared display discovery available")
moduleSettings.set(.arrangement, enabled: false)
expect(moduleSettings.needsDisplays, "Window layouts retain display discovery")
moduleSettings.set(.windows, enabled: false)
expect(!moduleSettings.needsDisplays, "Shared display discovery unloads when all display consumers are off")
moduleSettings.set(.monitors, enabled: true)
expect(moduleSettings.needsDisplays && !moduleSettings.enabled.contains(.arrangement), "Monitor switching can run independently of arrangement")
modulePreferences.removePersistentDomain(forName: moduleSettingsDomain)

final class DelayedBluetoothRunner: CommandRunning {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let fake = FakeRunner()
    private var first = true
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        if first { first = false; entered.signal(); _ = resume.wait(timeout: .now() + 5) }
        return try fake.run(executable, arguments)
    }
}
let delayed = DelayedBluetoothRunner()
let stoppingDomain = "better-macos.stopping-test.\(UUID().uuidString)"
let stoppingPreferences = UserDefaults(suiteName: stoppingDomain)!
stoppingPreferences.set(true, forKey: "bluetooth.autoEnabled")
stoppingPreferences.set([speaker.address], forKey: "bluetooth.autoAddresses")
var stoppingModule: BluetoothModule? = BluetoothModule(defaults: stoppingPreferences,
    backend: BluetoothBackend(runner: delayed, blueutil: "blueutil", audioTool: nil),
    importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
weak var releasedModule = stoppingModule
stoppingModule?.poll()
expect(delayed.entered.wait(timeout: .now() + 2) == .success, "Bluetooth unload fixture has an in-flight command")
stoppingModule?.requestConnection(true, address: speaker.address)
var stoppedCallback = false
stoppingModule?.stop { stoppedCallback = true; stoppingModule = nil }
expect(!stoppedCallback, "Module stop waits for the in-flight OS command to finish")
delayed.resume.signal()
let stopDeadline = Date().addingTimeInterval(3)
while !stoppedCallback && Date() < stopDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
expect(stoppedCallback && releasedModule == nil, "Stopped Bluetooth module releases its instance after draining")
expect(delayed.fake.connections.isEmpty, "Module shutdown cancels queued manual and subsequent automatic connection attempts")
stoppingPreferences.removePersistentDomain(forName: stoppingDomain)
let draggedLaptop = DisplayTopology.snapped(topologyBaseline, moving: "Mac", to: CGPoint(x: 40, y: 1500))
expect(draggedLaptop?.first(where: { $0.uuid == "Mac" })?.x == 0 &&
       draggedLaptop?.first(where: { $0.uuid == "Mac" })?.y == 1440,
       "Dragging the Mac below B snaps both its top edge and left alignment")
expect(draggedLaptop.map(DisplayTopology.isValidArrangement) == true,
       "An edge-snapped laptop arrangement remains cursor-connected")
let disconnectedDraft = topologyBaseline.map { position in
    position.uuid == "Mac" ? DisplayPosition(uuid: "Mac", x: -8000, y: 8000, width: 1512, height: 982) : position
}
expect(!DisplayTopology.isValidArrangement(disconnectedDraft), "Disconnected draft layouts cannot be applied")
let overlappingDraft = topologyBaseline.map { position in
    position.uuid == "Mac" ? DisplayPosition(uuid: "Mac", x: 0, y: 0, width: 1512, height: 982) : position
}
expect(!DisplayTopology.isValidArrangement(overlappingDraft), "Overlapping draft screens cannot be applied")
expect(!DisplayTopology.isValidArrangement(topologyBaseline + [topologyBaseline[0]]), "Duplicate screen identities are rejected")
let translatedDraft = topologyBaseline.map { DisplayPosition(uuid: $0.uuid, x: $0.x + 100, y: $0.y - 300, width: $0.width, height: $0.height) }
expect(DisplayTopology.normalized(translatedDraft, anchor: "B") == topologyBaseline,
       "Applying a drag layout retains the original main-display identity at zero")
expect(DisplayTopology.snapped(topologyBaseline, moving: "Mac", to: CGPoint(x: CGFloat.nan, y: 0)) == nil,
       "Non-finite drag coordinates are rejected")
expect(!safeSpaces.isAvailable && !safeSpaces.isEnabled, "Gesture interception starts unavailable until the host authorizes it")
do { try safeSpaces.setEnabled(true); expect(false, "Space interception must remain blocked") }
catch { expect(!safeSpaces.isEnabled, "Attempting to enable Space interception fails closed") }
safeSpaces.stop()
let safeDisplaySuite = "better-macos.safe-display-controller.\(UUID().uuidString)"
let safeDisplayDefaults = UserDefaults(suiteName: safeDisplaySuite)!
let safeDisplays = try DisplayController(defaults: safeDisplayDefaults, legacyDefaults: nil, discoverDisplays: { _ in })
safeDisplayDefaults.removePersistentDomain(forName: safeDisplaySuite)
expect(!safeDisplays.canDisableDisplays, "Unsupervised display controllers cannot disable screens by default")
do { try safeDisplays.setEnabled(false, for: "fixture-not-a-real-display"); expect(false, "Display disabling must remain blocked") }
catch { expect(true, "Display disabling is rejected before starting a configuration transaction") }
safeDisplays.canDisableDisplays = true
do { try safeDisplays.setEnabled(false, for: "fixture-not-a-real-display"); expect(false, "An authorized controller must still validate the target") }
catch { expect(true, "Authorization does not bypass unavailable display-control support") }

var metadataReads = 0
let refreshGate = DisplayRefreshGate(delay: 0.02) { metadataReads += 1 }
for _ in 0..<100 { refreshGate.requestRefresh() }
expect(metadataReads == 0 && refreshGate.isSettling, "Display notification callbacks do not perform synchronous graphics reads")
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
expect(metadataReads == 1 && !refreshGate.isSettling, "A display-notification storm coalesces into one quiet-period refresh")
refreshGate.requestRefresh()
refreshGate.cancel()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
expect(metadataReads == 1, "Canceled display refresh cannot run during shutdown")
expect(!WatchdogPolicy.shouldStop(parentIsAlive: true, now: 100, heartbeat: 99, timeout: 8), "Fresh UI heartbeat does not trigger watchdog")
expect(WatchdogPolicy.shouldStop(parentIsAlive: true, now: 100, heartbeat: 90, timeout: 8), "Expired UI heartbeat triggers watchdog")
expect(!WatchdogPolicy.shouldStop(parentIsAlive: false, now: 100, heartbeat: 90, timeout: 8), "An exited/reparented process is never targeted")
for bundled in [false, true] { do {
    let domain = "better-macos.watchdog-tests.\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/better-macos-watchdog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = Process()
    let original = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    if bundled {
        let contents = root.appendingPathComponent("Fixture.app/Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: executable)
        let info: [String: String] = ["CFBundleIdentifier": domain, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        fixture.executableURL = executable
    } else { fixture.executableURL = original }
    fixture.arguments = ["--watchdog-fixture", domain, root.path]
    if bundled { fixture.arguments?.append("--expect-bundle") }
    try fixture.run()
    fixture.waitUntilExit()
    let terminatedByWatchdog = fixture.terminationReason == .uncaughtSignal && [SIGTERM, SIGKILL].contains(fixture.terminationStatus)
    let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    let tripRecorded = sessions.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tripped").path) }
    Thread.sleep(forTimeInterval: 1.2) // Let the orphaned test watchdog finish.
    UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
    try FileManager.default.removeItem(at: root)
    expect(terminatedByWatchdog && tripRecorded, "Watchdog initializes and terminates a stalled \(bundled ? "APP-BUNDLED" : "CLI") disposable child")
} catch { expect(false, "Watchdog fixture failed: \(error)") } }

if let index = CommandLine.arguments.firstIndex(of: "--preview"), index + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    dashboardModel.monitors = [
        Monitor(uuid: "fixture-main", name: "A very long external display name for wrapping and narrow-width checks", id: 101, enabled: true, isMain: true, disabledByApp: false),
        Monitor(uuid: "fixture-second", name: "Secondary display", id: 102, enabled: true, isMain: false, disabledByApp: false)
    ]
    dashboardModel.activeMonitorCount = 2
    dashboardModel.displaySupported = true
    dashboardModel.devices = [speaker, headphones, keyboard]
    dashboardModel.bluetoothAvailable = true
    dashboardModel.automaticReconnectEnabled = true
    dashboardModel.bluetoothSummary = BluetoothPresentation.summary(enabled: true, selected: [], devices: dashboardModel.devices)
    dashboardModel.watchdogReady = true
    dashboardModel.displaySettling = false
    dashboardModel.widgetLayout = .suggested(for: dashboardModel.enabledModules)
    func render(_ name: String, _ content: AnyView, width: CGFloat, height: CGFloat, dark: Bool = false) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: content.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light))
        window.contentView = view
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render preview") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }
    try render("widgets-light", AnyView(QuickActionsView(model: dashboardModel)), width: 430, height: dashboardModel.popupHeight)
    try render("widgets-dark", AnyView(QuickActionsView(model: dashboardModel)), width: 430, height: dashboardModel.popupHeight, dark: true)
    for group in SettingsGroup.allCases {
        dashboardModel.settingsGroup = group
        try render("settings-\(group.id)", AnyView(SettingsView(model: dashboardModel)), width: 860, height: 680)
    }
    let fixtureSuite = "better-macos.preview.\(UUID().uuidString)"
    let fixtureDefaults = UserDefaults(suiteName: fixtureSuite)!
    let setup = SetupDraft(current: dashboardModel, defaults: fixtureDefaults)
    for (name, step) in [("feature", SetupDraft.Step.feature(.windows)), ("configure-audio", .configure(.audio)), ("permissions", .permissions), ("widgets", .widgets), ("review", .review)] {
        setup.step = step
        try render("wizard-\(name)", AnyView(SetupWizard(model: dashboardModel, draft: setup, close: {})), width: 760, height: 700)
    }
    fixtureDefaults.removePersistentDomain(forName: fixtureSuite)
    dashboardModel.widgetLayout.entries.removeAll()
    try render("empty-home", AnyView(QuickActionsView(model: dashboardModel)), width: 430, height: 580)
    dashboardModel.countdowns = ["fixture-second": 12]
    dashboardModel.disabledMonitorCount = 1
    dashboardModel.clipboardStoragePending = true
    dashboardModel.keepAwakeCanStop = true
    try render("recovery-empty-home", AnyView(QuickActionsView(model: dashboardModel)), width: 430, height: 580)
    print("Fixture previews saved to \(directory.path)")
}

do {
    try DisplaySafety.validateDisable(1, activeIDs: [1, 2], mirroredIDs: [])
    expect(true, "An independent monitor may be disabled when another remains")
} catch { expect(false, "Safe independent monitor rejected") }
for (id, active, mirrors, label) in [
    (UInt32(1), [UInt32(1)], Set<UInt32>(), "Last usable screen is protected"),
    (UInt32(3), [UInt32(1), 2], Set<UInt32>(), "An inactive/mirror-slave screen is rejected"),
    (UInt32(1), [UInt32(1), 2], Set<UInt32>([1]), "Mirror SOURCES are rejected too")
] {
    do { try DisplaySafety.validateDisable(id, activeIDs: active, mirroredIDs: mirrors); expect(false, label) }
    catch { expect(true, label) }
}

let eventMask = strafe_tap_event_mask()
expect(eventMask & (1 << CGEventType.keyDown.rawValue) == 0 && eventMask & (1 << CGEventType.keyUp.rawValue) == 0,
       "Gesture event tap excludes keystrokes")
for (index, direction) in [(UInt32(0), SwitchDirection.left), (4, .right)] {
    let engine = GestureSwitchEngine(spaceInfo: {
        var info = StrafeInfo()
        info.currentIndex = index
        info.spaceCount = 5
        return info
    })
    do { try engine.switchSpace(direction); expect(false, "Space edge must block") }
    catch SwitchEngineError.atEdge { expect(true, "Space switching cannot overshoot an edge") }
    catch { expect(false, "Unexpected Space-switching error") }
}

final class RecordingEngine: SwitchEngine {
    var attempts = 0
    var atEdge = true
    func switchSpace(_ direction: SwitchDirection) throws {
        attempts += 1
        if atEdge { throw SwitchEngineError.atEdge }
    }
}

func gesture(_ phase: Int64) -> CGEvent {
    let event = CGEvent(source: nil)!
    for (field, value) in [(UInt32(55), Int64(30)), (110, 23), (123, 1), (132, phase)] {
        event.setIntegerValueField(CGEventField(rawValue: field)!, value: value)
    }
    event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.1)
    event.setDoubleValueField(CGEventField(rawValue: 129)!, value: 10)
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    return event
}

let recording = RecordingEngine()
let interceptor = SwipeInterceptor(engine: recording, isExposeActive: { false })
for phase: Int64 in [1, 2, 2, 4] {
    expect(interceptor.handle(type: CGEventType(rawValue: 30)!, event: gesture(phase)) == nil,
           "Blocked edge swipe suppresses phase \(phase)")
}
expect(recording.attempts == 1, "One physical gesture attempts only one Space switch")
recording.atEdge = false
_ = interceptor.handle(type: CGEventType(rawValue: 30)!, event: gesture(1))
_ = interceptor.handle(type: CGEventType(rawValue: 30)!, event: gesture(2))
expect(recording.attempts == 2, "A new gesture works after a blocked edge swipe")
interceptor.overrideEnabled = false
expect(interceptor.handle(type: CGEventType(rawValue: 30)!, event: gesture(1)) != nil,
       "Disabled Space interception passes gestures through")
let cursorWarpSource = ScreenEdgeController.makeWarpSource()
expect(cursorWarpSource != nil && cursorWarpSource!.localEventsSuppressionInterval == 0,
       "Cursor warps must not introduce the default 250ms local-input suppression")
let edgeLayout = [
    DisplayPosition(uuid: "A", x: -2560, y: 0, width: 2560, height: 1440),
    DisplayPosition(uuid: "Mac", x: -2560, y: 1440, width: 1512, height: 982)
]
for fraction: CGFloat in [0.001, 0.5, 0.999] {
    let x = -2560 + fraction * 2560
    let point = ScreenEdges.destination(from: CGPoint(x: x, y: 1435), to: CGPoint(x: x, y: 1439), delta: CGPoint(x: 0, y: 10), layout: edgeLayout)
    expect(point != nil && abs(point!.x - (-2558 + fraction * 1508)) < 0.01 && point!.y == 1442,
           "Full lower edge maps proportionally onto Mac at fraction \(fraction)")
}
let edgeUp = ScreenEdges.destination(from: CGPoint(x: -1804, y: 1444), to: CGPoint(x: -1804, y: 1438), delta: CGPoint(x: 0, y: -6), layout: edgeLayout)
expect(edgeUp == CGPoint(x: -1280, y: 1438), "Mac upper edge maps back to the larger display's center")
expect(ScreenEdges.destination(from: CGPoint(x: -100, y: 100), to: CGPoint(x: -100, y: 101), delta: CGPoint(x: 0, y: 1), layout: edgeLayout) == nil, "Interior mouse movement never warps")
expect(ScreenEdges.destination(from: CGPoint(x: -100, y: 1439), to: CGPoint(x: -100, y: 1438), delta: CGPoint(x: 0, y: -1), layout: edgeLayout) == nil, "Inward movement at an edge never warps")
let ambiguousEdges = edgeLayout + [DisplayPosition(uuid: "Other", x: -1048, y: 1440, width: 1048, height: 982)]
expect(ScreenEdges.destination(from: CGPoint(x: -100, y: 1435), to: CGPoint(x: -100, y: 1439), delta: CGPoint(x: 0, y: 10), layout: ambiguousEdges) == nil, "Split edges with multiple neighbors preserve native behavior")
expect(ScreenEdges.destination(from: CGPoint(x: -100, y: 1435), to: CGPoint(x: -100, y: 1439), delta: CGPoint(x: 0, y: 10), layout: [edgeLayout[0]]) == nil, "Removed neighbors cannot receive pointer warps")
let sideEdges = [DisplayPosition(uuid: "L", x: 0, y: 0, width: 2000, height: 1400), DisplayPosition(uuid: "R", x: 2000, y: 0, width: 1000, height: 900)]
let edgeRight = ScreenEdges.destination(from: CGPoint(x: 1995, y: 1300), to: CGPoint(x: 1999, y: 1300), delta: CGPoint(x: 8, y: 0), layout: sideEdges)
expect(edgeRight != nil && edgeRight!.x == 2002 && edgeRight!.y < 900, "Mismatched side edges map into the shorter neighbor")

let animationSuite = "better-macos.animation-tests.\(UUID().uuidString)"
let animationDefaults = UserDefaults(suiteName: animationSuite)!
var animationValues: [String: Any] = ["com.apple.dock/autohide-time-modifier": 0.25, "unrelated": "keep"]
var failAnimationWrites = false
let animationRead: (AnimationPreferences.Setting) -> Any? = { animationValues[$0.id] }
let animationWrite: (AnimationPreferences.Setting, Any?) throws -> Void = { setting, value in
    if failAnimationWrites && setting.key == "launchanim" { throw ToggleError(message: "Injected write failure") }
    animationValues[setting.id] = value
}
let animationSettings = AnimationPreferences(defaults: animationDefaults, read: animationRead, write: animationWrite)
try animationSettings.setEnabled(true)
expect(animationSettings.enabled && animationValues["com.apple.dock/autohide-time-modifier"] as? Double == 0, "Animation preset applies and remembers enabled choice")
let recreatedAnimations = AnimationPreferences(defaults: animationDefaults, read: animationRead, write: animationWrite)
try recreatedAnimations.setEnabled(true)
try recreatedAnimations.setEnabled(false, preserveChoice: true)
expect(recreatedAnimations.enabled && animationValues["com.apple.dock/autohide-time-modifier"] as? Double == 0.25, "Module suspension restores originals while preserving choice across recreation")
expect(animationValues["com.apple.dock/launchanim"] == nil && animationValues["unrelated"] as? String == "keep", "Animation restore preserves absent keys and unrelated preferences")
try recreatedAnimations.setEnabled(true)
failAnimationWrites = true
do { try recreatedAnimations.setEnabled(false); expect(false, "Failed restoration must throw") }
catch { expect(animationDefaults.data(forKey: "animations.originals") != nil, "Partial restoration retains durable backup for retry") }
failAnimationWrites = false
try recreatedAnimations.setEnabled(false)
expect(!recreatedAnimations.enabled && animationDefaults.data(forKey: "animations.originals") == nil, "Successful restoration clears backup and persists Off")
let legacyAnimationBackup: [String: [String: Any]] = ["com.apple.dock/autohide-time-modifier": ["value": 0.25]]
let legacyAnimationData = try PropertyListSerialization.data(fromPropertyList: legacyAnimationBackup, format: .binary, options: 0)
animationDefaults.set(legacyAnimationData, forKey: "animations.originals")
animationDefaults.set(true, forKey: "animations.enabled")
animationValues["com.apple.dock/autohide-time-modifier"] = 0.0
animationValues["com.apple.dock/mineffect"] = "genie"
expect(recreatedAnimations.needsUpdate, "Older animation presets detect new controls")
try recreatedAnimations.setEnabled(true)
expect(!recreatedAnimations.needsUpdate && animationValues["com.apple.dock/mineffect"] as? String == "scale", "Preset upgrade applies new controls and extends snapshot")
try recreatedAnimations.setEnabled(false)
expect(animationValues["com.apple.dock/autohide-time-modifier"] as? Double == 0.25 && animationValues["com.apple.dock/mineffect"] as? String == "genie", "Preset upgrade preserves old originals and captures new ones")
expect(animationValues["com.apple.WindowManager/DisableTilingAnimations"] == nil, "Experimental tiling preference restores original absence")
animationDefaults.set(legacyAnimationData, forKey: "animations.originals")
try recreatedAnimations.setEnabled(false)
expect(animationValues["com.apple.dock/mineffect"] as? String == "genie", "Disabling an old preset leaves never-managed keys untouched")
animationDefaults.removePersistentDomain(forName: animationSuite)

let spaceSuite = "better-macos.spaces-tests.\(UUID().uuidString)"
let spacePreferences = UserDefaults(suiteName: spaceSuite)!
spacePreferences.set(true, forKey: "spaces.enabled")
spacePreferences.set(TransitionSpeed.instant.rawValue, forKey: "spaces.speed")
let savedSpaces = SpacesModule(defaults: spacePreferences)
expect(savedSpaces.savedEnabled, "Creating Space module preserves saved enabled choice")
expect(!savedSpaces.isEnabled, "Saved preference does not start interception before readiness")
try savedSpaces.restoreSavedState()
expect(savedSpaces.needsStartupRestore, "Unavailable watchdog defers restoration")
savedSpaces.suspend()
expect(savedSpaces.savedEnabled, "Temporary suspension preserves enabled preference")
savedSpaces.stop()
let recreatedSpaces = SpacesModule(defaults: spacePreferences)
expect(recreatedSpaces.savedEnabled && recreatedSpaces.speed == .instant, "Module recreation preserves enabled choice and speed")
try recreatedSpaces.setEnabled(false)
expect(!recreatedSpaces.savedEnabled, "Explicit off persists disabled preference")
recreatedSpaces.isAvailable = true
try recreatedSpaces.restoreSavedState()
expect(!recreatedSpaces.isEnabled, "Explicit off prevents deferred startup activation")
recreatedSpaces.stop()
spacePreferences.removePersistentDomain(forName: spaceSuite)

// Host lifecycle regressions: these are the same reconciliation and helper
// entry points used by AppDelegate, with no live event taps or display commands.
var cursorActive = false
let lifecycle = SystemControlLifecycle(startCursor: { _ in cursorActive = true }, stopCursor: { cursorActive = false })
var controlState = SystemControlLifecycle.State(watchdogReady: true, displaySettling: false,
    layoutFresh: true, cursorRequested: true, arrangementEnabled: true, layout: edgeLayout)
try lifecycle.reconcile(controlState)
expect(cursorActive, "Settled host state starts requested screen-edge matching")
controlState.pendingConfirmation = true
try lifecycle.reconcile(controlState)
expect(!cursorActive, "Display confirmation pauses screen-edge matching")
controlState.pendingConfirmation = false
try lifecycle.reconcile(controlState)
expect(cursorActive, "Keeping a display change resumes matching without another display notification")
controlState.displaySettling = true
controlState.layoutFresh = false
try lifecycle.reconcile(controlState)
controlState.displaySettling = false
try lifecycle.reconcile(controlState)
expect(!cursorActive, "Debounce completion cannot restart matching against a stale layout")
controlState.layoutFresh = true
try lifecycle.reconcile(controlState)
expect(cursorActive, "Fresh display snapshot resumes matching")
controlState.watchdogReady = false
try lifecycle.reconcile(controlState)
expect(!cursorActive && controlState.recoveryReady, "Watchdog loss stops input features without blocking explicit display recovery")
controlState.arrangementEnabled = false
controlState.watchdogReady = true
try lifecycle.reconcile(controlState)
expect(!cursorActive, "Disabled arrangement module cannot restart its cursor handler")

let watchdogReviewDomain = "better-macos.watchdog-status.\(UUID().uuidString)"
let statusSupervisor = SafetySupervisor(domain: watchdogReviewDomain)
var statusReports = 0
var statusRefreshes = 0
let statusGate = DisplayRefreshGate(delay: 0.04) { statusRefreshes += 1 }
statusSupervisor.onStatusChanged = { _ in statusReports += 1; statusGate.requestRefresh() }
let repeatingStatus = Timer(timeInterval: 0.01, repeats: true) { _ in statusSupervisor.reportStatus("unavailable") }
RunLoop.main.add(repeatingStatus, forMode: .common)
RunLoop.main.run(until: Date().addingTimeInterval(0.12))
repeatingStatus.invalidate()
expect(statusReports == 1 && statusRefreshes == 1 && !statusGate.isSettling,
       "Repeated watchdog failure reports cannot starve the display debounce")
statusSupervisor.reportStatus("ready")
expect(statusReports == 2, "A changed watchdog status still reaches the host")
statusGate.cancel()
UserDefaults(suiteName: watchdogReviewDomain)?.removePersistentDomain(forName: watchdogReviewDomain)

let failedAnimationDomain = "better-macos.animation-recovery.\(UUID().uuidString)"
let failedAnimationDefaults = UserDefaults(suiteName: failedAnimationDomain)!
var failedAnimationValues: [String: Any] = [:]
var rejectAnimationWrite = true
let interruptedAnimations = AnimationPreferences(defaults: failedAnimationDefaults, read: { failedAnimationValues[$0.id] }, write: { setting, value in
    if rejectAnimationWrite && setting.key == "launchanim" {
        if value != nil { failedAnimationValues[setting.id] = value }
        throw ToggleError(message: "Injected sync and rollback failure")
    }
    failedAnimationValues[setting.id] = value
})
do { try interruptedAnimations.setEnabled(true); expect(false, "Failed enable must throw") }
catch { expect(interruptedAnimations.recoveryRequired && !interruptedAnimations.enabled && !failedAnimationValues.isEmpty,
               "Failed apply/rollback exposes recovery even when the toggle was never enabled") }
rejectAnimationWrite = false
let restartedAnimations = AnimationPreferences(defaults: failedAnimationDefaults, read: { failedAnimationValues[$0.id] }, write: { failedAnimationValues[$0.id] = $1 })
try restartedAnimations.recoverPendingRestore()
expect(failedAnimationValues.isEmpty && !restartedAnimations.recoveryRequired && !restartedAnimations.enabled,
       "Fresh-process recovery restores interrupted animation writes while the preset is Off")
failedAnimationDefaults.removePersistentDomain(forName: failedAnimationDomain)

for takeoverFails in [false, true] {
    let takeoverDomain = "better-macos.takeover-stop.\(UUID().uuidString)"
    let takeoverDefaults = UserDefaults(suiteName: takeoverDomain)!
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var takeoverModule: BluetoothModule? = BluetoothModule(defaults: takeoverDefaults, backend: backend(FakeRunner()),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, legacyServiceTakeover: {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            if takeoverFails { throw ToggleError(message: "Injected takeover failure") }
        })
    weak var takeoverReference = takeoverModule
    takeoverModule?.takeOverLegacyService()
    expect(entered.wait(timeout: .now() + 1) == .success, "Legacy takeover fixture starts")
    var stoppedTakeover = 0
    takeoverModule?.stop { stoppedTakeover += 1; takeoverModule = nil }
    release.signal()
    let deadline = Date().addingTimeInterval(2)
    while stoppedTakeover == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(stoppedTakeover == 1 && takeoverReference == nil && !takeoverDefaults.bool(forKey: "bluetooth.autoEnabled"),
           "Stopping during \(takeoverFails ? "failed" : "successful") takeover completes once without enabling automation")
    takeoverReference = nil
    takeoverDefaults.removePersistentDomain(forName: takeoverDomain)
}

final class RecordingPhases {
    private let lock = NSLock()
    private var phases: [Int64] = []
    let began = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func post(_ phase: Int64, _ progress: Double, _ velocity: Double) -> Bool {
        lock.lock(); phases.append(phase); lock.unlock()
        if phase == strafe_gesture_phase_began() { began.signal(); _ = release.wait(timeout: .now() + 3) }
        return true
    }
    var recorded: [Int64] { lock.lock(); defer { lock.unlock() }; return phases }
}
final class DrainCheckingRunner: CommandRunning {
    let phases: RecordingPhases
    init(_ phases: RecordingPhases) { self.phases = phases }
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        guard phases.recorded.last == strafe_gesture_phase_ended() else {
            throw ToggleError(message: "Display command started before the gesture ended")
        }
        return "drained"
    }
}
let phases = RecordingPhases()
let drainEngine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: phases.post)
let drainDomain = "better-macos.gesture-drain.\(UUID().uuidString)"
let drainDefaults = UserDefaults(suiteName: drainDomain)!
drainDefaults.set(TransitionSpeed.smooth.rawValue, forKey: "spaces.speed")
let drainingSpaces = SpacesModule(defaults: drainDefaults, engine: drainEngine)
try drainEngine.switchSpace(.right)
expect(phases.began.wait(timeout: .now() + 1) == .success, "Synthetic ramp fixture is in flight")
try drainEngine.switchSpace(.right) // Queued ramp must never begin after suspension.
let host = AppDelegate(commandRunner: DrainCheckingRunner(phases), spaces: drainingSpaces)
var commandFinished = false
var commandSucceeded = false
host.runDisplayCommand(executable: "fixture", arguments: []) { result in
    commandFinished = true
    commandSucceeded = (try? result.get()) == "drained"
}
expect(drainingSpaces.isDraining && !commandFinished, "Host defers display helpers while the active gesture drains")
phases.release.signal()
let drainDeadline = Date().addingTimeInterval(2)
while !commandFinished && Date() < drainDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
expect(commandSucceeded && !drainingSpaces.isDraining, "Actual AppDelegate helper path waits for terminal gesture phase")
expect(phases.recorded.count == TransitionSpeed.rampSteps + 2 && phases.recorded.filter { $0 == strafe_gesture_phase_began() }.count == 1,
       "Suspension finishes the active ramp and cancels the queued ramp")
drainingSpaces.stop()
drainDefaults.removePersistentDomain(forName: drainDomain)

let unloadPhases = RecordingPhases()
let unloadEngine = GestureSwitchEngine(spaceInfo: { nil }, postPhase: unloadPhases.post)
let unloadDomain = "better-macos.gesture-unload.\(UUID().uuidString)"
let unloadDefaults = UserDefaults(suiteName: unloadDomain)!
unloadDefaults.set(TransitionSpeed.quick.rawValue, forKey: "spaces.speed")
let unloadingSpaces = SpacesModule(defaults: unloadDefaults, engine: unloadEngine)
try unloadEngine.switchSpace(.left)
expect(unloadPhases.began.wait(timeout: .now() + 1) == .success, "Module unload fixture has an active gesture")
try unloadEngine.switchSpace(.left)
var unloadCompleted = false
unloadingSpaces.stop { unloadCompleted = true }
expect(!unloadCompleted && unloadingSpaces.isDraining, "Module shutdown waits rather than dropping the gesture's terminal event")
unloadPhases.release.signal()
let unloadDeadline = Date().addingTimeInterval(2)
while !unloadCompleted && Date() < unloadDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
expect(unloadCompleted && unloadPhases.recorded.last == strafe_gesture_phase_ended() && unloadPhases.recorded.count == TransitionSpeed.rampSteps + 2,
       "Module shutdown completes after one terminal event with queued work canceled")
unloadDefaults.removePersistentDomain(forName: unloadDomain)

let sourceRevision = String(repeating: "a", count: 40)
let newerRevision = String(repeating: "b", count: 40)
func comparisonJSON(_ status: String) -> Data {
    Data("{\"status\":\"\(status)\"}".utf8)
}
if case .available(let sha) = try SourceUpdateComparison.parse(comparisonJSON("ahead"), headRevision: newerRevision) {
    expect(sha == newerRevision, "Source update detection offers a newer descendant revision")
} else { expect(false, "Expected newer source revision") }
for status in ["identical", "behind"] {
    if case .current = try SourceUpdateComparison.parse(comparisonJSON(status), headRevision: newerRevision) {
        expect(true, "Source comparison \(status) does not offer a downgrade")
    } else { expect(false, "Unexpected source update") }
}
if case .diverged = try SourceUpdateComparison.parse(comparisonJSON("diverged"), headRevision: newerRevision) {
    expect(true, "Diverged source history is not treated as a normal update")
}
do { _ = try SourceUpdateComparison.parse(comparisonJSON("ahead"), headRevision: "bad;command"); expect(false, "Invalid revisions must fail") }
catch { expect(true, "Updater rejects malformed revisions before constructing an install URL") }
let managedInstallation = SourceInstallation(revision: sourceRevision,
    sourceDirectory: "/Users/test/Library/Application Support/Better macOS/source",
    destination: "/Users/test/Applications/Better macOS.app")
let installScript = try managedInstallation.updateScript(revision: newerRevision)
expect(installScript.contains("/\(newerRevision)/install.sh") && installScript.contains("set -euo pipefail"),
       "Update launcher pins the downloaded installer and preserves pipeline failures")
let quoteFixture = "path with spaces and 'quotes'; $(echo unsafe)"
let quotedResult = try CommandRunner().run("/bin/bash", ["-c", "printf %s \(SourceInstallation.shellQuote(quoteFixture))"])
expect(quotedResult == quoteFixture, "Installer path quoting cannot execute shell fragments")
do { _ = try SourceInstallation(revision: sourceRevision).updateScript(revision: newerRevision); expect(false, "Unmanaged build must not silently install elsewhere") }
catch { expect(true, "Unmanaged builds cannot invoke managed installation") }

final class UpdateURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var code = 200
    private static var requests = 0
    static func configure(body: Data, code: Int = 200) {
        lock.lock(); self.body = body; self.code = code; lock.unlock()
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.body, code = Self.code
        Self.requests += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = request.url!.path.hasSuffix("/commits/main") ? Data("{\"sha\":\"\(String(repeating: "b", count: 40))\"}".utf8) : body
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let updateDomain = "better-macos.updates-test.\(UUID().uuidString)"
let updateDefaults = UserDefaults(suiteName: updateDomain)!
let updateConfiguration = URLSessionConfiguration.ephemeral
updateConfiguration.protocolClasses = [UpdateURLProtocol.self]
let updateSession = URLSession(configuration: updateConfiguration)
let updater = SourceUpdater(installation: managedInstallation, defaults: updateDefaults, session: updateSession)
func finishUpdateCheck() {
    let deadline = Date().addingTimeInterval(2)
    while updater.isChecking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(!updater.isChecking, "Source update request completes without blocking the UI")
}
UpdateURLProtocol.configure(body: comparisonJSON("ahead"))
updater.check(force: true)
finishUpdateCheck()
expect(updater.availableRevision == newerRevision && updater.canInstall, "Source-managed install exposes an available update")
let requestsBeforeCache = UpdateURLProtocol.requestCount
updater.check()
expect(UpdateURLProtocol.requestCount == requestsBeforeCache && updater.canInstall, "Daily update throttle preserves the cached available revision")
UpdateURLProtocol.configure(body: comparisonJSON("identical"))
updater.check(force: true)
finishUpdateCheck()
expect(updater.availableRevision == nil && !updater.canInstall, "Current source clears a previously available update")
UpdateURLProtocol.configure(body: Data(), code: 404)
updater.check(force: true)
finishUpdateCheck()
expect(updater.status.contains("not published") && !updater.canInstall, "Unpublished development builds report status rather than offering a downgrade")
updater.stop()
updateSession.invalidateAndCancel()
updateDefaults.removePersistentDomain(forName: updateDomain)

let spacingDomain = "better-macos.spacing-test.\(UUID().uuidString)"
let spacingDefaults = UserDefaults(suiteName: spacingDomain)!
var spacingValues: [String: Any] = ["NSStatusItemSpacing": 12]
var failSpacingWrites = false
let spacing = MenuBarSpacing(defaults: spacingDefaults, read: { spacingValues[$0] }, write: { key, value in
    if failSpacingWrites { throw ToggleError(message: "Injected preference failure") }
    spacingValues[key] = value
})
try spacing.setEnabled(true)
expect(spacing.enabled && spacingValues["NSStatusItemSpacing"] as? Int == 4, "Compact spacing applies to an isolated preference backend")
try spacing.restore(preserveChoice: true)
expect(spacing.enabled && spacing.needsApply && spacingValues["NSStatusItemSpacing"] as? Int == 12,
       "Module suspension restores spacing while preserving the user's compact choice")
try spacing.setEnabled(true)
try spacing.setEnabled(true)
try spacing.setEnabled(false)
expect(spacingValues["NSStatusItemSpacing"] as? Int == 12 && spacingValues["NSStatusItemSelectionPadding"] == nil,
       "Repeated spacing enable retains originals and restores absent keys")
failSpacingWrites = true
do { try spacing.setEnabled(true); expect(false, "Spacing write should fail") }
catch { expect(spacing.recoveryRequired, "Failed spacing rollback retains durable recovery metadata") }
failSpacingWrites = false
let restartedSpacing = MenuBarSpacing(defaults: spacingDefaults, read: { spacingValues[$0] }, write: { spacingValues[$0] = $1 })
try restartedSpacing.restore()
expect(!restartedSpacing.recoveryRequired && !restartedSpacing.enabled && spacingValues["NSStatusItemSpacing"] as? Int == 12,
       "New spacing owner recovers failed writes using the durable snapshot")
try spacing.setEnabled(true)
failSpacingWrites = true
do { try spacing.setEnabled(false); expect(false, "Spacing restore should fail") }
catch { expect(spacing.enabled && spacing.recoveryRequired, "Failed spacing disable stays enabled with recovery available") }
failSpacingWrites = false
try spacing.restore()
spacingDefaults.removePersistentDomain(forName: spacingDomain)

var quitHold = QuitHoldState()
expect(quitHold.duration == 3, "Quit hold defaults to three seconds")
quitHold.duration = 2
expect(!quitHold.keyDown(12, quitChord: false, repeated: false, target: 101, now: 0),
       "Typing Q or using another modifier combination passes through")
expect(!quitHold.keyDown(12, quitChord: true, repeated: true, target: 101, now: 0),
       "A repeat already in flight when interception starts cannot initiate a quit")
expect(quitHold.keyDown(12, quitChord: true, repeated: false, target: 101, now: 1),
       "Initial Command Q is consumed rather than delivered to the app")
expect(quitHold.advance(now: 2.99, frontmost: 101, keysHeld: true) == nil,
       "Quit does not occur before the full hold duration")
expect(quitHold.keyDown(12, quitChord: true, repeated: true, target: 101, now: 2),
       "Autorepeat is consumed without restarting the countdown")
expect(quitHold.advance(now: 3, frontmost: 101, keysHeld: true) == 101,
       "A continuous two-second hold requests quit for the captured app")
expect(quitHold.advance(now: 4, frontmost: 101, keysHeld: true) == nil &&
       quitHold.keyDown(12, quitChord: true, repeated: true, target: 202, now: 4),
       "Completed hold cannot quit twice or leak repeats into the next app")
expect(quitHold.keyUp(12) && quitHold.key == nil, "Matching key-up is consumed and rearms the shortcut")
_ = quitHold.keyDown(12, quitChord: true, repeated: false, target: 101, now: 10)
_ = quitHold.keyUp(12)
expect(quitHold.advance(now: 13, frontmost: 101, keysHeld: false) == nil,
       "Releasing Q early cancels the quit")
_ = quitHold.keyDown(12, quitChord: true, repeated: false, target: 101, now: 20)
expect(quitHold.advance(now: 21, frontmost: 101, keysHeld: false) == nil && quitHold.target == nil,
       "Releasing Command or losing physical key state cancels the hold")
expect(quitHold.keyDown(12, quitChord: true, repeated: true, target: 101, now: 23) &&
       quitHold.advance(now: 24, frontmost: 101, keysHeld: true) == nil,
       "Re-pressing Command while Q remains held cannot resurrect a canceled quit")
quitHold.reset()
_ = quitHold.keyDown(12, quitChord: true, repeated: false, target: 101, now: 30)
expect(quitHold.advance(now: 32, frontmost: 202, keysHeld: true) == nil && quitHold.target == nil,
       "Switching foreground apps cancels rather than quitting either app")
quitHold.reset()
_ = quitHold.keyDown(12, quitChord: true, repeated: false, target: 101, now: 40)
expect(!quitHold.keyDown(53, quitChord: false, repeated: false, target: 101, now: 41) && quitHold.target == nil,
       "Another key cancels while passing that key through")
expect(quitHold.keyUp(12), "Canceled shortcut still consumes its matching release")
quitHold.duration = 3
_ = quitHold.keyDown(0, quitChord: true, repeated: false, target: 101, now: 50)
expect(quitHold.advance(now: 52, frontmost: 101, keysHeld: true) == nil &&
       quitHold.advance(now: 53, frontmost: 101, keysHeld: true) == 101,
       "Three-second option and layout-translated Q keycodes use the same hold contract")
quitHold.reset()
_ = quitHold.keyDown(12, quitChord: true, repeated: false, target: 101, now: 60)
quitHold.cancel()
expect(quitHold.advance(now: 64, frontmost: 101, keysHeld: true) == nil && quitHold.keyUp(12),
       "Sleep, clicks, tap interruption, and configuration changes can cancel without leaking Q")

let quitDefaultsDomain = "better-macos.quit-default-test.\(UUID().uuidString)"
let quitDefaults = UserDefaults(suiteName: quitDefaultsDomain)!
let guardDefaults = QuitGuard(defaults: quitDefaults)
expect(guardDefaults.duration == 3, "Fresh installations use a three-second quit hold")
guardDefaults.duration = 2
expect(QuitGuard(defaults: quitDefaults).duration == 2, "Explicit two-second preference survives recreation")
for seconds in [1.0, 15.0, 99.0] {
    guardDefaults.duration = seconds
    expect(QuitGuard(defaults: quitDefaults).duration == seconds, "Quit hold persists \(Int(seconds)) seconds within the 1–99 range")
}
guardDefaults.duration = 100
expect(guardDefaults.duration == 99, "Quit hold clamps values above 99 seconds")
guardDefaults.duration = 0
expect(guardDefaults.duration == 1, "Quit hold clamps values below one second")
guardDefaults.duration = .nan
expect(guardDefaults.duration == 3, "Non-finite quit duration falls back to the default")
quitDefaults.removePersistentDomain(forName: quitDefaultsDomain)
let initialQuitFrame = QuitProgressFrame(startedAt: 10, duration: 3, now: 10)
let lastQuitFrame = QuitProgressFrame(startedAt: 10, duration: 3, now: 13)
expect(initialQuitFrame.remainingDots(width: 272).count == 10 && lastQuitFrame.remainingDots(width: 272).isEmpty,
       "Pac-Man starts with ten dots and eats them all at the quit deadline")
let quitFrames = (0...360).map { QuitProgressFrame(startedAt: 10, duration: 3, now: 10 + Double($0) / 120) }
expect(zip(quitFrames, quitFrames.dropFirst()).allSatisfy { $0.centerX(width: 272) < $1.centerX(width: 272) },
       "Animation advances between input timer ticks, including 120 Hz display frames")
expect(zip(quitFrames, quitFrames.dropFirst()).allSatisfy { $1.remainingDots(width: 272).count <= $0.remainingDots(width: 272).count },
       "Eaten dots never reappear during a hold")
let beforeQuitFrame = QuitProgressFrame(startedAt: 10, duration: 3, now: 9)
let afterQuitFrame = QuitProgressFrame(startedAt: 10, duration: 3, now: 14)
expect(beforeQuitFrame.progress == 0 && afterQuitFrame.progress == 1,
       "Countdown drawing remains within its track before and after the hold")

final class FakePowerAssertions: PowerAssertionBackend {
    var entries: [IOPMAssertionID: (display: Bool, timeout: TimeInterval)] = [:]
    var nextID: IOPMAssertionID = 1
    var failCreate = false
    var failDisplayCreate = false
    var failTimeout = false
    var failTimeoutID: IOPMAssertionID?
    var failRelease: IOPMAssertionID?
    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID {
        if failCreate || (display && failDisplayCreate) { throw ToggleError(message: "Injected power creation failure") }
        let id = nextID
        nextID += 1
        entries[id] = (display, timeout)
        return id
    }
    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws {
        if failTimeout || failTimeoutID == id { throw ToggleError(message: "Injected timeout failure") }
        guard let entry = entries[id] else { throw ToggleError(message: "Unknown assertion") }
        entries[id] = (entry.display, seconds)
    }
    func release(_ id: IOPMAssertionID) throws {
        if id == failRelease { throw ToggleError(message: "Injected release failure") }
        entries.removeValue(forKey: id)
    }
}
// Setup replaces policy without replacing existing timed/app ownership.
for reason in ["timed", "app", "timed-paused"] {
    for releaseFails in [false, true] {
        let suite = "better-macos.setup-display-assertion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let power = FakePowerAssertions()
        var clock: TimeInterval = 100
        let apps = reason == "timed" ? [:] : ["fixture.app": "Fixture"]
        let module = KeepAwakeModule(defaults: defaults, backend: power, now: { clock }, automaticUpdates: false,
            runningApps: { apps }, processInstances: { ["fixture.app": [42]] })
        try module.configureForSetup(minutes: 30, display: true, apps: apps)
        module.activate()
        if reason == "timed-paused" { try module.stop() }
        if reason != "app" { try module.start() }
        clock += 12
        let remaining = module.remaining
        let paused = module.appsPaused
        let activeApps = module.activeAppNames
        let systemID = power.entries.first(where: { !$0.value.display })!.key
        let displayID = power.entries.first(where: { $0.value.display })!.key
        if releaseFails { power.failRelease = displayID }
        do {
            try module.configureForSetup(minutes: 45, display: false, apps: apps)
            expect(!releaseFails, "\(reason): failed display release must throw from setup reconciliation")
        } catch {
            expect(releaseFails, "\(reason): display policy reconciliation only throws the injected release failure")
        }
        expect(!module.keepDisplayAwake && module.selectedMinutes == 45 && module.selectedApps == apps,
               "\(reason): reviewed setup policy persists even when assertion removal needs retry")
        expect(module.remaining == remaining && module.appsPaused == paused && module.activeAppNames == activeApps,
               "\(reason): setup preserves existing deadline and app pause intent")
        expect(power.entries[systemID] != nil && power.entries.count == (releaseFails ? 2 : 1),
               "\(reason): display policy Off releases only the display assertion, retaining system ownership")
        if releaseFails {
            expect(module.protectionFailed && power.entries[displayID] != nil,
                   "\(reason): failed display release retains its exact ID and exposes protection failure")
            if case .failed = module.configurationOutcome {} else { expect(false, "failed removal must not report setup applied") }
            // Unchanged policy must still retry the failed release instead of early returning.
            do { try module.configureForSetup(minutes: 45, display: false, apps: apps); expect(false, "same-policy retry must attempt retained display ID") }
            catch {}
            power.failRelease = nil
            try module.configureForSetup(minutes: 45, display: false, apps: apps)
            expect(power.entries[displayID] == nil && power.entries[systemID] != nil && !module.protectionFailed,
                   "\(reason): successful same-policy retry removes retained display ID without replacing system ownership")
        }
        if case .applied = module.configurationOutcome {} else { expect(false, "successful removal must report setup applied") }
        expect(module.remaining == remaining && module.appsPaused == paused,
               "\(reason): retries do not grant a fresh timed duration or resume paused app rules")
        try module.deactivate()
    }
}

// Removing display policy must not depend on successful system-assertion renewal.
do {
    let suite = "better-macos.setup-independent-display.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let power = FakePowerAssertions()
    let module = KeepAwakeModule(defaults: defaults, backend: power, now: { 100 }, automaticUpdates: false,
        runningApps: { [:] }, processInstances: { [:] })
    try module.configureForSetup(minutes: 30, display: true, apps: [:])
    try module.start()
    let systemID = power.entries.first(where: { !$0.value.display })!.key
    let displayID = power.entries.first(where: { $0.value.display })!.key
    power.failTimeoutID = systemID
    do { try module.configureForSetup(minutes: 30, display: false, apps: [:]); expect(false, "system renewal failure remains visible") }
    catch {}
    expect(power.entries[displayID] == nil && power.entries[systemID] != nil,
           "display policy removal proceeds independently of failing system renewal")
    if case .failed = module.configurationOutcome {} else { expect(false, "system renewal failure cannot report setup applied") }
    power.failTimeoutID = nil
    try module.retry()
    try module.deactivate()
}

let awakeDomain = "better-macos.keep-awake-test.\(UUID().uuidString)"
let awakeDefaults = UserDefaults(suiteName: awakeDomain)!
let power = FakePowerAssertions()
var awakeTime: TimeInterval = 1000
let awake = KeepAwakeModule(defaults: awakeDefaults, backend: power, now: { awakeTime }, automaticUpdates: false)
expect(!awake.active && awake.selectedMinutes == 30 && !awake.keepDisplayAwake,
       "Keep awake starts idle with a thirty-minute choice and display sleep allowed")
try awake.start()
expect(awake.active && awake.remaining == 1800 && power.entries.count == 1 && power.entries.values.first?.display == false,
       "Timed session acquires only the requested system-idle assertion")
try awake.start()
expect(power.entries.count == 1, "Repeated Start cannot leak power assertions")
awakeTime += 120
try awake.extend()
expect(awake.remaining == 2580 && power.entries.values.first?.timeout == 2580,
       "Extend adds fifteen minutes to remaining time and updates the OS timeout")
try awake.setKeepDisplayAwake(true)
expect(power.entries.count == 2 && power.entries.values.contains { $0.display && $0.timeout == 2580 },
       "Display wake can join an active session with the same deadline")
try awake.setKeepDisplayAwake(false)
expect(power.entries.count == 1 && awake.active && !awake.keepDisplayAwake,
       "Turning display wake off retains the computer's awake session")
awakeTime += 2581
awake.tick()
expect(!awake.active && power.entries.isEmpty && awake.remaining == 0,
       "Deadline expiry after a sleep-sized clock jump releases the session")
try awake.extend()
expect(!awake.active && power.entries.isEmpty, "Extend cannot revive an expired session")
awake.selectedMinutes = 45
try awake.setKeepDisplayAwake(true)
let recreatedAwake = KeepAwakeModule(defaults: awakeDefaults, backend: power, now: { awakeTime }, automaticUpdates: false)
expect(!recreatedAwake.active && recreatedAwake.selectedMinutes == 45 && recreatedAwake.keepDisplayAwake,
       "Recreation preserves choices but does not resume an old awake session")
power.failDisplayCreate = true
do { try awake.start(); expect(false, "Display assertion creation should fail") }
catch { expect(!awake.active && power.entries.isEmpty, "Partial session creation releases its system assertion") }
power.failDisplayCreate = false
try awake.start()
let oldRemaining = awake.remaining
power.failTimeout = true
do { try awake.extend(); expect(false, "Timeout update should fail") }
catch { expect(awake.remaining == oldRemaining, "Failed extension does not claim a later deadline") }
power.failTimeout = false
let timeoutDisplayID = power.entries.first { $0.value.display }!.key
power.failTimeoutID = timeoutDisplayID
do { try awake.extend(); expect(false, "Second assertion timeout failure must throw") }
catch { expect(awake.remaining == oldRemaining && power.entries.values.first { !$0.display }?.timeout == oldRemaining,
               "Partial extension rolls successful system timeout back to the original deadline") }
power.failTimeoutID = nil
let failingPowerID = power.entries.first { $0.value.display }!.key
power.failRelease = failingPowerID
do { try awake.stop(); expect(false, "Release should fail") }
catch { expect(awake.active && power.entries.count == 1 && power.entries[failingPowerID] != nil,
               "Stop releases other assertions and retains failed ownership for retry") }
power.failRelease = nil
try awake.stop()
expect(!awake.active && power.entries.isEmpty, "Retrying Stop releases the remaining assertion")
var disposableAwake: KeepAwakeModule? = KeepAwakeModule(defaults: awakeDefaults, backend: power, now: { awakeTime }, automaticUpdates: false)
try disposableAwake?.start()
disposableAwake = nil
expect(power.entries.isEmpty, "Unloading an active owner releases both power assertions")
awake.selectedMinutes = 1440
try awake.start()
try awake.extend()
expect(awake.remaining == 86400, "Session extensions stay bounded at twenty-four hours")
try awake.stop()
awakeDefaults.removePersistentDomain(forName: awakeDomain)

let appAwakeDomain = "better-macos.app-awake-test.\(UUID().uuidString)"
let appAwakeDefaults = UserDefaults(suiteName: appAwakeDomain)!
let appPower = FakePowerAssertions()
var runningAwakeApps = ["test.one": "One"]
var appAwakeTime: TimeInterval = 0
var appProcessID: pid_t = 1
var extraAppProcess: pid_t?
let appAwake = KeepAwakeModule(defaults: appAwakeDefaults, backend: appPower,
    now: { appAwakeTime }, automaticUpdates: false, runningApps: { runningAwakeApps },
    processInstances: { runningAwakeApps.mapValues { _ in Set([appProcessID] + (extraAppProcess.map { [$0] } ?? [])) } })
try appAwake.setApp("test.one", name: "One", selected: true)
try appAwake.setApp("test.two", name: "Two", selected: true)
expect(!appAwake.active, "App rules wait for module activation")
appAwake.activate()
expect(appAwake.active && appAwake.activeAppNames == ["One"], "Activation discovers already-running selected apps")
appPower.failTimeout = true
do { try appAwake.start(); expect(false, "Failed overlapping Start must throw") }
catch { expect(appAwake.active && !appAwake.appsPaused && appAwake.remaining == 0,
               "Failed timed Start preserves independent app reason") }
appAwake.tick()
expect(appAwake.protectionFailed, "Failed lease maintenance is visible instead of claiming protection")
appPower.failTimeout = false
appAwake.tick()
expect(!appAwake.protectionFailed, "Successful retry clears failed protection status")
try appAwake.start()
runningAwakeApps = [:]
appAwake.tick()
expect(appAwake.active && appAwake.remaining == 1800, "App exit preserves overlapping timed reason")
runningAwakeApps = ["test.two": "Two"]
appAwakeTime = 1801
appAwake.tick()
expect(appAwake.active && appAwake.remaining == 0 && appAwake.activeAppNames == ["Two"], "Timer expiry preserves background app reason")
try appAwake.stop()
appAwake.tick()
expect(!appAwake.active && appAwake.appsPaused, "Stop pauses running app across subsequent reconciliation")
extraAppProcess = 3
appAwake.tick()
expect(!appAwake.active && appAwake.appsPaused, "Additional instance does not clear pause while stopped instance lives")
extraAppProcess = nil
appProcessID = 2
appAwake.tick()
expect(appAwake.active && !appAwake.appsPaused, "Rapid restart clears pause without an empty bundle snapshot")
try appAwake.stop()
try appAwake.resumeApps()
expect(appAwake.active && !appAwake.appsPaused, "Resume restores running app reason")
try appAwake.stop()
runningAwakeApps = [:]
appAwake.tick()
runningAwakeApps = ["test.two": "Two relaunched"]
appAwake.tick()
expect(appAwake.active && !appAwake.appsPaused, "Exit clears pause and bundle identity matches next launch")
let failingAppID = appPower.entries.keys.first!
appPower.failRelease = failingAppID
do { try appAwake.stop(); expect(false, "Injected app Stop failure must throw") }
catch { expect(appAwake.active, "Failed app release retains assertion ownership") }
appPower.failRelease = nil
appAwake.tick()
expect(!appAwake.active && appPower.entries.isEmpty, "Timer retries failed Stop without recreating paused app assertions")
try appAwake.resumeApps()
try appAwake.deactivate()
appAwake.tick()
expect(!appAwake.active && appPower.entries.isEmpty && appAwake.selectedApps.count == 2, "Disable releases assertions and keeps rules without reactivation")
var idlePublications = 0
appAwake.onChange = { idlePublications += 1 }
appAwake.tick()
appAwake.tick()
expect(idlePublications == 0, "Unchanged idle ticks do not publish redundant runtime preference writes")
appAwakeDefaults.removePersistentDomain(forName: appAwakeDomain)

let retryAwakeDomain = "better-macos.awake-scheduled-retry.\(UUID().uuidString)"
let retryAwakeDefaults = UserDefaults(suiteName: retryAwakeDomain)!
let retryPower = FakePowerAssertions()
let retryAwake = KeepAwakeModule(defaults: retryAwakeDefaults, backend: retryPower,
    runningApps: { [:] }, processInstances: { [:] })
try retryAwake.start()
retryPower.failRelease = retryPower.entries.keys.first!
do { try retryAwake.deactivate(); expect(false, "Failed timed-only deactivation must throw") }
catch { expect(retryAwake.active, "Failed disable retains owned assertion") }
retryAwake.activate() // Same recovery path used by the host; immediate retry still fails.
retryPower.failRelease = nil
let retryDeadline = Date().addingTimeInterval(2)
while retryAwake.active && Date() < retryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
expect(!retryAwake.active && retryPower.entries.isEmpty,
       "Scheduled timer retries failed timed-only disable without manual ticks or workspace events")
try retryAwake.deactivate()

let failedRulePower = FakePowerAssertions()
failedRulePower.failCreate = true
let failedRuleAwake = KeepAwakeModule(defaults: retryAwakeDefaults, backend: failedRulePower,
    automaticUpdates: false, runningApps: { ["test.failure": "Failure"] },
    processInstances: { ["test.failure": [42]] })
try failedRuleAwake.setApp("test.failure", name: "Failure", selected: true)
failedRuleAwake.activate()
expect(!failedRuleAwake.active && failedRuleAwake.canStop && failedRuleAwake.protectionFailed,
       "Pending app-only request exposes Stop even when no assertion could be created")
try failedRuleAwake.stop()
failedRulePower.failCreate = false
failedRuleAwake.tick()
expect(!failedRuleAwake.active && !failedRuleAwake.canStop && failedRuleAwake.appsPaused,
       "Stop pauses failed app request before backend recovery can activate it")
try failedRuleAwake.deactivate()
retryAwakeDefaults.removePersistentDomain(forName: retryAwakeDomain)

try testMouseControls()
print("\(checks) isolated checks passed; no Bluetooth, display, or real Space changes.")
