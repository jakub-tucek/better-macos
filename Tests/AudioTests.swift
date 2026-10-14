import Foundation

private final class FakeAudio: AudioRoutingBackend {
    var available: [AudioDevice] = []
    var routes: [AudioDirection: String] = [:]
    var writes: [(String, AudioDirection)] = []
    var fail = false
    var failCurrent = false
    var failedWrites = Set<AudioDirection>()
    func devices() throws -> [AudioDevice] {
        if fail { throw ToggleError(message: "Discovery failed") }
        return available
    }
    func current(_ direction: AudioDirection) throws -> String? {
        if failCurrent { throw ToggleError(message: "Route observation failed") }
        return routes[direction]
    }
    func select(_ uid: String, direction: AudioDirection) throws {
        if failedWrites.contains(direction) { throw ToggleError(message: "Transient route failure") }
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
    module.bluetoothProtection = { AudioProtectionSnapshot(ready: true, protectedDeviceNames: ["Headset"]) }; module.setPreferences([monitor.uid], direction: .output); module.resume()
    expect(fake.routes[.output] == usb.uid, "Known connected headphones veto automatic takeover even when not current")
    module.bluetoothProtection = { .clear }
    module.poll()
    expect(fake.routes[.output] == monitor.uid, "Deferred preference retries when Bluetooth observation/protection clears")
    module.automaticAllowed = false
    module.setPreferences([usb.uid], direction: .output); module.poll()
    expect(fake.routes[.output] == monitor.uid, "Disabling Audio routing leaves the shared Bluetooth owner observation-only")
    module.automaticAllowed = true; module.poll()
    expect(fake.routes[.output] == usb.uid, "Re-enabling Audio applies saved routing without requiring a topology change")
    module.setPreferences(["missing"], direction: .output); module.setFallback("", direction: .output); module.resume()
    expect(fake.routes[.output] == usb.uid, "No available preference or fallback preserves current route")
    let count = fake.writes.count
    fake.fail = true; module.resume()
    expect(fake.writes.count == count && module.status == "Discovery failed", "Failed observation never writes a route")
    fake.fail = false
    module.automatic = false
    module.bluetoothConnected(name: "Duplicate")
    expect(fake.writes.count == count, "Ambiguous Bluetooth names never select a guessed UID")
    fake.available.removeAll { $0.uid == monitor.uid }; module.poll()
    fake.fail = true
    module.bluetoothConnected(name: "Duplicate")
    expect(fake.writes.count == count, "Bluetooth request cannot use stale discovery after observation fails")
    fake.fail = false
    module.suspendRouting = true; module.select(builtIn.uid, direction: .output); module.bluetoothConnected(name: "Duplicate")
    expect(fake.writes.count == count, "Hardware-test suspension prevents both manual and Bluetooth writes")
    module.suspendRouting = false
    fake.failCurrent = true; module.bluetoothConnected(name: "Duplicate")
    expect(fake.writes.count == count, "Failed current-route observation rejects Bluetooth routing")
    fake.failCurrent = false
    module.setPreferences([usb.uid], direction: .input)
    module.setPreferences([builtIn.uid], direction: .output)
    fake.failedWrites = [.input]; module.automatic = true
    expect(fake.routes[.output] == builtIn.uid && fake.routes[.input] == builtIn.uid, "Input write failure does not starve independent output routing")
    fake.failedWrites = []; module.poll()
    expect(fake.routes[.input] == usb.uid, "Transient write failure retries without another device change")
    let stoppedCount = fake.writes.count
    module.stop(); module.select(builtIn.uid, direction: .output); module.poll(); module.resume()
    expect(fake.writes.count == stoppedCount, "Stopped routing owner rejects manual and automatic work")
    runBluetoothAudioIntegrationTests()
}

private func runBluetoothAudioIntegrationTests() {
    let domain = "audio.integration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set(true, forKey: "bluetooth.legacyTakenOver")
    defaults.set([speaker.address], forKey: "bluetooth.autoAddresses")
    defaults.set(true, forKey: "bluetooth.autoEnabled")
    defaults.set(true, forKey: "audio.automatic")
    let fake = FakeAudio()
    fake.available = [AudioDevice(uid: "builtin", name: "Built-in", directions: [.output], bluetooth: false),
                      AudioDevice(uid: "speaker", name: speaker.name, directions: [.output], bluetooth: false)]
    fake.routes = [.output: "builtin"]
    let runner = FakeRunner()
    let bluetooth = BluetoothModule(defaults: defaults, backend: backend(runner), importLegacyConfiguration: false,
                                    authorizationProvider: { .allowedAlways })
    let audio = AudioModule(backend: fake, defaults: defaults)
    audio.automaticAllowed = true
    audio.setPreferences(["speaker"], direction: .output)
    audio.bluetoothProtection = { bluetooth.audioProtection }
    audio.bluetoothRequestIsCurrent = { bluetooth.audioRequestIsCurrent(name: $0) }
    audio.start()
    expect(fake.writes.isEmpty && !bluetooth.audioProtection.ready, "Saved routing waits for Bluetooth startup observation")
    var callbacks = 0
    bluetooth.onAudioOutputRequested = { name in
        callbacks += 1
        expect(!bluetooth.isBusy && bluetooth.audioProtection.ready, "Bluetooth forwards routing only after publishing a successful protection snapshot")
        audio.bluetoothConnected(name: name)
    }
    bluetooth.start()
    let deadline = Date().addingTimeInterval(2)
    while bluetooth.isBusy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    audio.poll()
    expect(callbacks == 1 && fake.writes.count == 1 && fake.routes[.output] == "speaker", "Bluetooth callback and Audio preferences share a single route owner")
    audio.automatic = false
    fake.routes[.output] = "builtin"; audio.resume()
    runner.current = [speaker]
    fake.failCurrent = true
    bluetooth.poll()
    let legacyDeadline = Date().addingTimeInterval(2)
    while bluetooth.isBusy && Date() < legacyDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(callbacks == 2 && fake.routes[.output] == "builtin", "Integrated legacy request defers after a failed current-route read")
    fake.failCurrent = false; audio.poll()
    expect(fake.routes[.output] == "speaker", "Legacy post-connect intent retries after observation recovers without reconnecting")
    fake.routes[.output] = "builtin"; audio.resume()
    fake.failedWrites = [.output]
    audio.bluetoothConnected(name: speaker.name)
    expect(fake.routes[.output] == "builtin", "Failed legacy write preserves current route")
    fake.failedWrites = []; audio.poll()
    expect(fake.routes[.output] == "speaker", "Legacy write retries after transient failure")
    fake.routes[.output] = "builtin"; audio.resume()
    fake.failedWrites = [.output]; audio.bluetoothConnected(name: speaker.name)
    audio.select("builtin", direction: .output)
    fake.failedWrites = []; audio.poll()
    expect(fake.routes[.output] == "builtin", "Manual intent cancels queued legacy writes even if the manual write fails")
    fake.failedWrites = [.output]; audio.bluetoothConnected(name: speaker.name)
    bluetooth.switchAudioOutput = false
    fake.failedWrites = []; audio.poll()
    expect(fake.routes[.output] == "builtin", "Bluetooth policy changes cancel queued legacy routing")
    audio.select("builtin", direction: .output)
    audio.automatic = false
    expect(audio.isOverridden(.output), "Turning automatic routing off preserves manual override")
    bluetooth.switchAudioOutput = true; bluetooth.poll()
    let policyDeadline = Date().addingTimeInterval(2)
    while bluetooth.isBusy && Date() < policyDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(bluetooth.audioRequestIsCurrent(name: speaker.name), "Retained-owner override regression has an eligible Bluetooth routing request")
    audio.automaticAllowed = false; audio.poll()
    audio.bluetoothConnected(name: speaker.name)
    expect(audio.isOverridden(.output) && fake.routes[.output] == "builtin", "Audio disable with retained owner preserves manual output across Bluetooth requests")
    audio.automaticAllowed = true; audio.poll()
    expect(audio.isOverridden(.output), "Re-enable schedules rules without clearing manual overrides")
    bluetooth.stop(); audio.stop()
    defaults.set(true, forKey: "bluetooth.switchAudio")

    let discoveryRunner = FakeRunner()
    discoveryRunner.failPostConnectAudioObservation = true
    let discoveryBluetooth = BluetoothModule(defaults: defaults, backend: backend(discoveryRunner), importLegacyConfiguration: false,
                                              authorizationProvider: { .allowedAlways })
    let discoveryAudio = AudioModule(backend: fake, defaults: defaults)
    discoveryAudio.bluetoothProtection = { discoveryBluetooth.audioProtection }
    discoveryAudio.bluetoothRequestIsCurrent = { discoveryBluetooth.audioRequestIsCurrent(name: $0) }
    discoveryAudio.start()
    var discoveryCallbacks = 0
    discoveryBluetooth.onAudioOutputRequested = { name in
        discoveryCallbacks += 1
        discoveryAudio.bluetoothConnected(name: name)
    }
    discoveryBluetooth.start()
    let discoveryDeadline = Date().addingTimeInterval(2)
    while discoveryBluetooth.isBusy && Date() < discoveryDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(discoveryRunner.current.first?.connected == true && discoveryCallbacks == 0 && discoveryBluetooth.lastError != nil,
           "Post-connect discovery failure retains successful connection and performs no unsafe routing")
    discoveryRunner.failPostConnectAudioObservation = false
    discoveryRunner.current.append(headphones)
    discoveryRunner.audioOutputs.insert(headphones.name)
    discoveryBluetooth.poll()
    let discoveryRetryDeadline = Date().addingTimeInterval(2)
    while discoveryBluetooth.isBusy && Date() < discoveryRetryDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(discoveryCallbacks == 0 && fake.routes[.output] == "builtin", "Deferred post-connect routing rechecks arriving headphones before forwarding")
    discoveryRunner.current.removeAll { $0.address == headphones.address }
    discoveryBluetooth.poll()
    let unprotectedDeadline = Date().addingTimeInterval(2)
    while discoveryBluetooth.isBusy && Date() < unprotectedDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(discoveryCallbacks == 1 && fake.routes[.output] == "speaker" && discoveryRunner.connections.count == 1,
           "Recovered post-connect discovery forwards retained intent without reconnecting")
    fake.routes[.output] = "builtin"; discoveryAudio.resume()
    discoveryRunner.current = [speaker]; discoveryRunner.failPostConnectAudioObservation = true
    discoveryBluetooth.poll()
    let failureAgainDeadline = Date().addingTimeInterval(2)
    while discoveryBluetooth.isBusy && Date() < failureAgainDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    discoveryBluetooth.switchAudioOutput = false
    discoveryBluetooth.switchAudioOutput = true
    discoveryRunner.failPostConnectAudioObservation = false
    discoveryBluetooth.poll()
    let toggleDeadline = Date().addingTimeInterval(2)
    while discoveryBluetooth.isBusy && Date() < toggleDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(discoveryCallbacks == 1 && fake.routes[.output] == "builtin", "Output policy off/on before polling cannot resurrect deferred routing intent")
    discoveryBluetooth.stop(); discoveryAudio.stop()

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let canceledRunner = FakeRunner()
    var canceledBackend = backend(canceledRunner)
    canceledBackend.waitForConnection = { entered.signal(); _ = release.wait(timeout: .now() + 2) }
    let canceled = BluetoothModule(defaults: defaults, backend: canceledBackend, importLegacyConfiguration: false,
                                   authorizationProvider: { .allowedAlways })
    var canceledCallbacks = 0
    canceled.onAudioOutputRequested = { _ in canceledCallbacks += 1 }
    canceled.start()
    expect(entered.wait(timeout: .now() + 2) == .success, "Cancellation fixture reaches an in-flight Bluetooth connection")
    var drained = false
    canceled.stop { drained = true }; release.signal()
    let cancelDeadline = Date().addingTimeInterval(2)
    while !drained && Date() < cancelDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(drained && canceledCallbacks == 0, "Bluetooth unload cancels routing callbacks before delivery")

    let policyEntered = DispatchSemaphore(value: 0)
    let policyRelease = DispatchSemaphore(value: 0)
    let policyRunner = FakeRunner()
    var policyBackend = backend(policyRunner)
    policyBackend.waitForConnection = { policyEntered.signal(); _ = policyRelease.wait(timeout: .now() + 2) }
    let policyModule = BluetoothModule(defaults: defaults, backend: policyBackend, importLegacyConfiguration: false,
                                      authorizationProvider: { .allowedAlways })
    var policyCallbacks = 0
    policyModule.onAudioOutputRequested = { _ in policyCallbacks += 1 }
    policyModule.start()
    expect(policyEntered.wait(timeout: .now() + 2) == .success, "Policy cancellation fixture blocks before connected progress delivery")
    policyModule.switchAudioOutput = false; policyModule.switchAudioOutput = true
    policyRelease.signal()
    let staleProgressDeadline = Date().addingTimeInterval(2)
    while policyModule.isBusy && Date() < staleProgressDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    policyModule.poll()
    let afterProgressDeadline = Date().addingTimeInterval(2)
    while policyModule.isBusy && Date() < afterProgressDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(policyCallbacks == 0 && policyRunner.connections.count == 1, "Canceled-cycle connected progress cannot recreate cleared routing intent")
    policyModule.stop()
}
