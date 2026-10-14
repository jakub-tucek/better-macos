import Foundation

private final class FakeAudio: AudioRoutingBackend {
    var available: [AudioDevice] = []
    var routes: [AudioDirection: String] = [:]
    var writes: [(String, AudioDirection)] = []
    var fail = false
    func devices() throws -> [AudioDevice] {
        if fail { throw ToggleError(message: "Discovery failed") }
        return available
    }
    func current(_ direction: AudioDirection) throws -> String? { routes[direction] }
    func select(_ uid: String, direction: AudioDirection) throws {
        guard available.contains(where: { $0.uid == uid && $0.directions.contains(direction) }) else { throw ToggleError(message: "Missing device") }
        writes.append((uid, direction)); routes[direction] = uid
    }
}

func runAudioTests() {
    let domain = "audio.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let builtIn = AudioDevice(uid: "builtin", name: "Built-in", directions: [.input, .output], bluetooth: false)
    let usb = AudioDevice(uid: "usb", name: "Duplicate", directions: [.input, .output], bluetooth: false)
    let monitor = AudioDevice(uid: "monitor", name: "Duplicate", directions: [.output], bluetooth: false)
    let headset = AudioDevice(uid: "headset", name: "Headset", directions: [.input, .output], bluetooth: true)
    let fake = FakeAudio()
    fake.available = [builtIn, usb, monitor]
    fake.routes = [.input: builtIn.uid, .output: builtIn.uid]
    let module = AudioModule(backend: fake, defaults: defaults)
    module.automaticAllowed = true
    module.start()
    defer { module.stop() }
    expect(!module.automatic && fake.writes.isEmpty, "Audio starts observation-only")
    module.select(monitor.uid, direction: .output)
    expect(fake.routes[.output] == monitor.uid && fake.routes[.input] == builtIn.uid, "Manual output uses UID despite duplicate names and leaves input unchanged")
    module.setPreferences([usb.uid, monitor.uid, usb.uid], direction: .output)
    module.setPreferences([builtIn.uid], direction: .input)
    module.setFallback(builtIn.uid, direction: .output)
    let recreated = AudioModule(backend: fake, defaults: defaults)
    expect(recreated.preferences(.output) == [usb.uid, monitor.uid] && recreated.fallback(.output) == builtIn.uid, "Ordered UID preferences and fallback persist without duplicates")
    module.automatic = true
    expect(fake.routes[.output] == usb.uid && fake.routes[.input] == builtIn.uid, "Automatic rules independently choose output and built-in microphone")
    module.select(monitor.uid, direction: .output)
    module.poll()
    expect(fake.routes[.output] == monitor.uid && module.isOverridden(.output), "Manual override survives unchanged topology")
    let inputOnly = AudioDevice(uid: "mic", name: "Mic", directions: [.input], bluetooth: false)
    fake.available.append(inputOnly); module.poll()
    expect(module.isOverridden(.output), "Input-only arrival does not clear output override")
    fake.available.removeAll { $0.uid == usb.uid }; module.poll()
    expect(fake.routes[.output] == monitor.uid && !module.isOverridden(.output), "USB unplug clears relevant override and chooses next preference")
    fake.available.removeAll { $0.uid == monitor.uid }; module.poll()
    expect(fake.routes[.output] == builtIn.uid, "Missing preferences use explicit fallback")
    fake.available.append(monitor); module.poll()
    expect(fake.routes[.output] == monitor.uid, "Monitor wake restores available preference")
    fake.available.append(usb); module.poll()
    expect(fake.routes[.output] == usb.uid, "Reconnected stable UID returns to top preference")
    fake.routes[.output] = monitor.uid; module.poll()
    expect(module.isOverridden(.output), "External route changes establish manual overrides")
    module.resume()
    expect(fake.routes[.output] == usb.uid, "Explicit Resume applies preferences")
    fake.available.append(headset); fake.routes[.output] = headset.uid; module.poll()
    expect(fake.routes[.output] == headset.uid, "Connected Bluetooth output is never stolen by automatic rules")
    module.select(usb.uid, direction: .output)
    expect(fake.routes[.output] == usb.uid, "Explicit user choice can leave protected Bluetooth output")
    module.bluetoothProtection = { true }; module.setPreferences([monitor.uid], direction: .output); module.resume()
    expect(fake.routes[.output] == usb.uid, "Known connected headphones veto automatic takeover even when not current")
    module.bluetoothProtection = { false }
    module.setPreferences(["missing"], direction: .output); module.setFallback("", direction: .output); module.resume()
    expect(fake.routes[.output] == usb.uid, "No available preference or fallback preserves current route")
    let count = fake.writes.count
    fake.fail = true; module.resume()
    expect(fake.writes.count == count && module.status == "Discovery failed", "Failed observation never writes a route")
    fake.fail = false
    module.automatic = false
    module.bluetoothConnected(name: "Duplicate")
    expect(fake.writes.count == count, "Ambiguous Bluetooth names never select a guessed UID")
    module.stop(); module.select(builtIn.uid, direction: .output); module.poll(); module.resume()
    expect(fake.writes.count == count, "Stopped routing owner rejects manual and automatic work")
}
