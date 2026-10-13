import AppKit
import SwiftUI
import CStrafe

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
    var failAudioObservation = false
    var failDeviceObservation = false

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        commands.append([executable] + arguments)
        switch arguments.first {
        case "--paired":
            if failDeviceObservation { throw ToggleError(message: "Observation failed") }
            let json = current.map { ["address": $0.address, "name": $0.name, "connected": $0.connected] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        case "--connect", "--disconnect":
            if failConnect { throw ToggleError(message: "Connection failed") }
            let address = arguments[1]
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
} catch { fputs("Unexpected failure: \(error)\n", stderr); exit(1) }

let testDomain = "mac-utils.tests.\(UUID().uuidString)"
let testDefaults = UserDefaults(suiteName: testDomain)!
testDefaults.set([speaker.address], forKey: "bluetooth.autoAddresses")
testDefaults.set(false, forKey: "bluetooth.autoEnabled")
let moduleRunner = FakeRunner()
moduleRunner.current = [BluetoothDevice(address: speaker.address, name: speaker.name, connected: true)]
let testModule = BluetoothModule(defaults: testDefaults, backend: backend(moduleRunner), importLegacyConfiguration: false)
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
testDefaults.removePersistentDomain(forName: testDomain)
expect(selectionPreserved, "Manual connection actions do not silently rewrite auto-reconnect choices")

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

let safeSpaces = SpacesModule()
expect(!safeSpaces.isAvailable && !safeSpaces.isEnabled, "Safety hold never starts gesture interception on initialization")
do { try safeSpaces.setEnabled(true); expect(false, "Space interception must remain blocked") }
catch { expect(!safeSpaces.isEnabled, "Attempting to enable Space interception fails closed") }
safeSpaces.stop()
let safeDisplays = DisplayController()
expect(!safeDisplays.canDisableDisplays, "Safety hold blocks new display disabling")
do { try safeDisplays.setEnabled(false, for: "fixture-not-a-real-display"); expect(false, "Display disabling must remain blocked") }
catch { expect(true, "Display disabling is rejected before starting a configuration transaction") }

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
