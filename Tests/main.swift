import AppKit
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

final class SwitchTarget: NSObject {
    var received: String?
    @objc func changed(_ sender: NSSwitch) { received = sender.identifier?.rawValue }
}

_ = NSApplication.shared
let target = SwitchTarget()
let row = MonitorRow(title: "A very long display name that should fit without overlapping the switch", subtitle: "Main display",
                     symbol: "display", isOn: true, canToggle: true, identifier: "test-device", target: target, action: #selector(SwitchTarget.changed(_:)))
row.layoutSubtreeIfNeeded()
expect(row.toggle.state == .on && row.toggle.isEnabled, "Native switch reflects enabled state")
expect(row.toggle.frame.maxX > 300 && row.toggle.frame.maxX <= row.bounds.maxX, "Native switch is right-aligned inside its row")
_ = row.toggle.sendAction(row.toggle.action, to: row.toggle.target)
expect(target.received == "test-device", "Switch action carries stable device identity")
let disabled = MonitorRow(title: "Last screen", subtitle: "On", symbol: "display", isOn: true, canToggle: false,
                          identifier: "last", target: target, action: #selector(SwitchTarget.changed(_:)))
expect(!disabled.toggle.isEnabled, "Unavailable/last-screen switch is disabled")

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
