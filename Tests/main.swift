import AppKit
import SwiftUI
import CStrafe
import CoreBluetooth

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

final class FakeRunner: CommandRunning {
    var current: [BluetoothDevice] = [speaker]
    var audioOutputs = Set([speaker.name])
    var commands: [[String]] = []
    var headphonesArrive = false
    var failConnect = false
    var failedAddresses = Set<String>()
    var powerOn = true
    var failAudioObservation = false
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
            return audioOutputs.sorted().joined(separator: "\n")
        case "-t": return ""
        default: throw ToggleError(message: "Unexpected command")
        }
    }

    var connections: [[String]] { commands.filter { $0.contains("--connect") } }
    var audioSwitches: [[String]] { commands.filter { $0.contains("-s") } }
}

func backend(_ fake: FakeRunner, audioTool: String? = "audio") -> BluetoothBackend {
    BluetoothBackend(runner: fake, blueutil: "blueutil", audioTool: audioTool, waitForConnection: {})
}

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

let testDomain = "mac-utils.tests.\(UUID().uuidString)"
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

func bluePixels(isOn: Bool) -> Int {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let view = NSHostingView(rootView: BlueSwitch(label: "Test switch", isOn: .constant(isOn)).frame(width: 80, height: 50))
    window.contentView = view
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var pixels = 0
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.blueComponent > 0.5, color.blueComponent > color.redComponent * 1.5, color.blueComponent > color.greenComponent * 1.2 {
                pixels += 1
            }
        }
    }
    return pixels
}
// Rendering creates WindowServer/CoreAnimation resources. Keep it opt-in while
// investigating the system rendering stall; the normal suite stays non-rendering.
if CommandLine.arguments.contains("--render-ui") {
    expect(bluePixels(isOn: true) > 100, "Enabled switch actually renders blue even in an inactive window")
    expect(bluePixels(isOn: false) == 0, "Disabled switch renders gray, not blue")
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
expect(!safeSpaces.isAvailable && !safeSpaces.isEnabled, "Gesture interception starts unavailable until the host authorizes it")
do { try safeSpaces.setEnabled(true); expect(false, "Space interception must remain blocked") }
catch { expect(!safeSpaces.isEnabled, "Attempting to enable Space interception fails closed") }
safeSpaces.stop()
let safeDisplays = DisplayController()
expect(!safeDisplays.canDisableDisplays, "Unsupervised display controllers cannot disable screens by default")
do { try safeDisplays.setEnabled(false, for: "fixture-not-a-real-display"); expect(false, "Display disabling must remain blocked") }
catch { expect(true, "Display disabling is rejected before starting a configuration transaction") }
safeDisplays.canDisableDisplays = true
do { try safeDisplays.setEnabled(false, for: "fixture-not-a-real-display"); expect(false, "An authorized controller must still validate the target") }
catch { expect(true, "Authorization does not bypass display identity validation") }

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
    let domain = "mac-utils.watchdog-tests.\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/mac-utils-watchdog-\(UUID().uuidString)", isDirectory: true)
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
        Monitor(uuid: "fixture-main", name: "Main display", id: 101, enabled: true, isMain: true, disabledByApp: false),
        Monitor(uuid: "fixture-second", name: "Secondary display", id: 102, enabled: true, isMain: false, disabledByApp: false)
    ]
    dashboardModel.activeMonitorCount = 2
    dashboardModel.displaySupported = true
    dashboardModel.devices = [speaker, headphones, keyboard]
    dashboardModel.bluetoothAvailable = true
    dashboardModel.automaticReconnectEnabled = true
    dashboardModel.bluetoothSummary = BluetoothPresentation.summary(enabled: true, selected: [], devices: dashboardModel.devices)
    for tab in DashboardTab.allCases {
        dashboardModel.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let view = NSHostingView(rootView: DashboardView(model: dashboardModel))
        window.contentView = view
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render preview") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(tab.rawValue.lowercased()).png"))
    }
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
print("\(checks) isolated checks passed; no Bluetooth, display, or real Space changes.")
