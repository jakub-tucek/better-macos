import AppKit
import CoreBluetooth
import SwiftUI

private struct Exit75AudioBackend: AudioRoutingBackend {
    func devices() throws -> [AudioDevice] { [] }
    func current(_ direction: AudioDirection) throws -> String? { nil }
    func select(_ uid: String, direction: AudioDirection) throws { fatalError("No live routing in diagnostic") }
}

// Production host callbacks/module/CommandRunner regression coverage,
// isolated defaults and an executable fixture; never invokes installed blueutil.
func runBluetoothErrorRecoveryTests() throws {
    try runBluetoothBlockedDisableTests()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-exit75-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("blueutil")
    let script = """
    #!/bin/sh
    cd "$(dirname "$0")" || exit 70
    echo "$*" >> calls
    case "$*" in
      '--power')
        if [ -f observation-failure ]; then
          case "$(cat observation-failure)" in
            signal) kill -TERM $$ ;;
            *) echo 'Synthetic observation failure' >&2; exit "$(cat observation-failure)" ;;
          esac
        fi
        if [ -f powered ]; then echo 1; else echo 0; fi ;;
      '--paired --format json')
        if [ -f bad-inventory ]; then printf 'SENTINEL_RAW_INVALID_JSON'; exit 0; fi
        if [ -f failed-inventory ]; then echo 'SENTINEL_HELPER_ERROR' >&2; exit 75; fi
        if [ -f empty-inventory ]; then printf '[]'; exit 0; fi
        if [ -f unmatched-inventory ]; then
          printf '[{"address":"f1-e2-d3-c4-b5-a6","name":"SENTINEL_OTHER_NAME","connected":true}]'; exit 0
        fi
        if [ -f full-inventory ]; then
          printf '[{"address":"fixture","name":"Fixture speaker","connected":true},{"address":"a1-b2-c3-d4-e5-f6","name":"SENTINEL_DISCOVERY_NAME","connected":true}]'; exit 0
        fi
        if [ -f connected ]; then state=true; else state=false; fi
        printf '[{"address":"fixture","name":"Fixture speaker","connected":%s}]\n' "$state" ;;
      '--connect fixture')
        if [ -f fail-connect ]; then echo 'Fixture connection unavailable' >&2; exit 75; fi
        touch connected ;;
      '--power 1')
        if [ -f succeed ]; then touch powered; else
          echo 'Failed to switch bluetooth power on in 10 seconds' >&2
          exit 75
        fi ;;
      *) echo 'Unexpected fixture command' >&2; exit 64 ;;
    esac
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let suite = "fix-mac-os.bluetooth-exit75.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let registeredDefaults = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
    defer { defaults.setVolatileDomain(registeredDefaults, forName: UserDefaults.registrationDomain) }
    defer { defaults.removePersistentDomain(forName: suite) }
    for feature in AppModule.allCases { ModuleSettings(defaults: defaults).set(feature, enabled: false) }
    defaults.set(true, forKey: "bluetooth.autoEnabled")
    defaults.set(true, forKey: "bluetooth.legacyTakenOver")
    let memory = MemoryDiagnosticSink()
    let logger = Diagnostics(sink: memory)
    let module = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: CommandRunner(diagnostics: logger), blueutil: executable.path, audioTool: nil, waitForConnection: {}),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways }, diagnostics: logger)
    let model = DashboardModel()
    model.enabledModules = []
    model.errorMessage = "Unrelated preexisting error"
    let audio = AudioModule(backend: Exit75AudioBackend(), defaults: defaults)
    let host = AppDelegate(model: model, preferences: defaults, makeAudio: { audio }, makeBluetooth: { module }, diagnostics: logger)
    defer { module.stop(); audio.stop(); withExtendedLifetime(host) {} }
    func wait() {
        let deadline = Date().addingTimeInterval(5)
        while module.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(!module.isBusy, "exit75 fixture completed before deadline")
    }
    func calls() throws -> String { try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8) }
    model.onModuleChanged(.bluetooth, true)
    wait()
    let initialCalls = try calls()
    expect(module.radioPoweredOn == false && !initialCalls.contains("--power 1"), "host activation with saved automatic reconnect does not power on Bluetooth")
    expect(model.errorMessage == "Unrelated preexisting error", "successful Bluetooth observation preserves unrelated global error")
    model.onAutoDeviceChanged("fixture", true)
    let cached = module.devices
    for failure in ["75", "134", "signal"] {
        try failure.write(to: root.appendingPathComponent("observation-failure"), atomically: true, encoding: .utf8)
        module.poll(); wait()
        expect(module.reconnectSummary.contains("Could not read Bluetooth status") && model.bluetoothSummary == module.reconnectSummary,
               "actual host projects failed observation instead of cached radio-off instruction")
        expect(module.devices == cached && model.devices == cached && model.selectedAddresses == ["fixture"] && module.radioPoweredOn == false,
               "failed observation preserves cached devices, target choice and last known radio state")
        expect(!model.bluetoothPermissionRequired && model.errorMessage == "Unrelated preexisting error",
               "helper failures neither invent denied authorization nor change global error ownership")
        expect(model.bluetoothObservationStale && !model.bluetoothCanOfferPowerOn && model.bluetoothEmptyMessage == "Paired devices could not be refreshed.",
               "UI marks cached observations stale and hides misleading power-on or empty-inventory guidance")
        try FileManager.default.removeItem(at: root.appendingPathComponent("observation-failure"))
        module.poll(); wait()
        expect(module.lastError == nil && model.bluetoothSummary.contains("Bluetooth is off"), "fresh observation restores truthful radio-off guidance")
        expect(!model.bluetoothObservationStale && model.bluetoothCanOfferPowerOn, "fresh snapshot alone restores nonstale power guidance")
    }
    model.onAutoDeviceChanged("fixture", false)
    model.onBluetoothPowerOn()
    wait()
    let exact = "blueutil failed (exit 75): Failed to switch bluetooth power on in 10 seconds"
    expect(module.lastError == exact && model.errorMessage == exact, "actual host manual action publishes exact screenshot error through real CommandRunner stderr/exit handling")
    let manualPublication = model.errorGeneration
    try "134".write(to: root.appendingPathComponent("observation-failure"), atomically: true, encoding: .utf8)
    module.poll(); wait()
    try FileManager.default.removeItem(at: root.appendingPathComponent("observation-failure"))
    module.poll(); wait()
    expect(model.errorMessage == exact && model.errorGeneration == manualPublication,
           "observation recovery cannot clear or replace the existing manual-error publication UUID")
    expect(logger.flushForTesting(), "Bluetooth host diagnostic events drain through test-only flush")
    let failedPublication = model.errorGeneration.uuidString
    let actionFailure = memory.records.last { $0["event"] as? String == "manual_action_finished" }
    expect(actionFailure?["operation"] as? String == failedPublication && actionFailure?["outcome"] as? String == "failure",
           "Bluetooth failure event correlates with the exact host-owned publication UUID")
    let commandFailure = memory.records.last { ($0["fields"] as? [String: String])?["exit_code"] == "75" }
    expect(commandFailure?["outcome"] as? String == "failure" && (commandFailure?["fields"] as? [String: String])?["action"] == "--power",
           "real fixture exit75 retains safe command action/result events")
    module.poll()
    wait()
    expect(module.lastError == nil && model.errorMessage == exact, "healthy discovery with radio still off does not dismiss the unresolved power-on failure")
    try "".write(to: root.appendingPathComponent("succeed"), atomically: true, encoding: .utf8)
    model.onBluetoothPowerOn()
    wait()
    expect(module.radioPoweredOn == true && module.lastError == nil && model.errorMessage == nil, "verified successful retry clears only its owned Bluetooth failure banner")
    expect(logger.flushForTesting(), "verified Bluetooth success diagnostics drain in test")
    let recovered = memory.records.last { $0["event"] as? String == "manual_action_finished" }
    expect(recovered?["operation"] as? String == failedPublication && recovered?["outcome"] as? String == "success"
           && (recovered?["fields"] as? [String: String])?["error_cleared"] == "true",
           "Bluetooth verified success reuses owned publication token and records actual clearance")
    func failAgain() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("succeed"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("powered"))
        module.poll(); wait()
        model.onBluetoothPowerOn(); wait()
        expect(model.errorMessage == exact && module.lastError == exact, "new failed power action still publishes the real exit75 error")
    }
    try failAgain()
    model.onBluetoothPowerOn(); wait()
    expect(model.errorMessage == exact && module.lastError == exact, "failed retry keeps its actionable Bluetooth failure")
    model.errorMessage = "Unrelated display recovery failure"
    try "".write(to: root.appendingPathComponent("succeed"), atomically: true, encoding: .utf8)
    model.onBluetoothPowerOn(); wait()
    expect(module.radioPoweredOn == true && model.errorMessage == "Unrelated display recovery failure", "successful Bluetooth retry preserves a newer unrelated error")
    try failAgain()
    // Identical text is still a new publication, not ownership of the old error.
    model.errorMessage = exact
    try "".write(to: root.appendingPathComponent("succeed"), atomically: true, encoding: .utf8)
    model.onBluetoothPowerOn(); wait()
    expect(module.radioPoweredOn == true && model.errorMessage == exact, "successful Bluetooth retry preserves newer identical-text error publication")
    expect(logger.flushForTesting(), "newer-publication Bluetooth diagnostic events drain in test")
    let preserved = memory.records.last { $0["event"] as? String == "manual_action_finished" }
    expect((preserved?["fields"] as? [String: String])?["error_cleared"] == "false",
           "Bluetooth success logs non-clearance when an identical-text error has a newer UUID")
    try "".write(to: root.appendingPathComponent("fail-connect"), atomically: true, encoding: .utf8)
    model.onManualConnection("fixture"); wait()
    let connectionError = model.errorMessage
    expect(connectionError?.contains("Fixture connection unavailable") == true, "manual connection failure uses the same owned host error callback")
    model.onBluetoothPowerOn(); wait()
    expect(model.errorMessage == connectionError, "successful power action cannot resolve a failed device connection")
    try FileManager.default.removeItem(at: root.appendingPathComponent("fail-connect"))
    model.onManualConnection("fixture"); wait()
    expect(module.devices.first?.connected == true && model.errorMessage == nil, "verified retry of the same device connection clears its owned failure")
    // Successful [] is a real discovery result, not a permission verdict or an
    // observation failure. Exercise production parsing, host projection and popup.
    model.onAutoDeviceChanged("fixture", true)
    model.onAutoDeviceChanged("a1-b2-c3-d4-e5-f6", true)
    let retained = model.selectedAddresses
    try Data().write(to: root.appendingPathComponent("empty-inventory"))
    module.poll(); wait()
    expect(model.bluetoothRadioOn == true && model.devices.isEmpty && model.selectedAddresses == retained && retained.count == 2,
           "radio-on exact empty JSON preserves both saved targets through actual host discovery")
    expect(module.lastError == nil && !model.bluetoothObservationStale && !model.bluetoothPermissionRequired,
           "successful empty discovery invents neither observation failure nor denied parent access")
    let unavailable = "Saved targets unavailable. Check Bluetooth status and access in Sound & connections."
    var labels = bluetoothPopupLabels(model)
    expect(labels.contains(unavailable) && labels.contains("2 chosen devices unavailable; targets are preserved.") && !labels.contains(where: { $0.contains("Choose targets") }),
           "native popup shows preserved unavailable targets without asking to choose them again")
    func discoveryEvents() -> [[String: String]] {
        expect(logger.flushForTesting(), "discovery state diagnostics drain through injected sink")
        return memory.records.filter { $0["event"] as? String == "discovery_state_changed" }.compactMap { $0["fields"] as? [String: String] }
    }
    var events = discoveryEvents()
    expect(events.last?["parsed_device_count"] == "0" && events.last?["saved_target_count"] == "2" && events.last?["matched_target_count"] == "0" && events.last?["radio_state"] == "on",
           "parsed empty state logs scalar counts and observed radio rather than device identities")
    expect(events.last?["parent_authorization"] == "allowed" && events.last?["helper_authorization"] == "unknown" && events.last?["helper_discovery_source"] == "unknown" && events.last?["command_outcome"] == "success" && events.last?["decode_outcome"] == "success",
           "empty success preserves explicit unknown helper authorization and discovery source")
    let unchanged = events.count
    for _ in 0..<3 { module.poll(); wait() }
    expect(discoveryEvents().count == unchanged, "unchanged successful empty polls do not spam discovery state events")
    try Data().write(to: root.appendingPathComponent("bad-inventory"))
    module.poll(); wait()
    events = discoveryEvents()
    expect(model.bluetoothObservationStale && model.bluetoothSummary.contains("Could not read Bluetooth status") && model.selectedAddresses == retained,
           "decode failure keeps existing observation-error precedence and saved choices")
    expect(events.last?["command_outcome"] == "success" && events.last?["decode_outcome"] == "failure" && events.last?["parsed_device_count"] == "unknown",
           "successful command with malformed JSON is logged as decode failure without raw output")
    let failed = events.count
    module.poll(); wait()
    expect(discoveryEvents().count == failed, "unchanged decode failure is deduplicated")
    try FileManager.default.removeItem(at: root.appendingPathComponent("bad-inventory"))
    try Data().write(to: root.appendingPathComponent("failed-inventory"))
    module.poll(); wait()
    events = discoveryEvents()
    expect(events.last?["command_outcome"] == "failure" && events.last?["decode_outcome"] == "not_attempted" && events.last?["read_stage"] == "paired",
           "paired command failure is distinct from JSON decode failure")
    try FileManager.default.removeItem(at: root.appendingPathComponent("failed-inventory"))
    module.poll(); wait()
    expect(discoveryEvents().count > failed && !model.bluetoothObservationStale && module.lastError == nil,
           "empty success after failure emits recovery without labeling the inventory denied or stale")
    model.onAutoDeviceChanged("fixture", false); model.onAutoDeviceChanged("a1-b2-c3-d4-e5-f6", false)
    labels = bluetoothPopupLabels(model)
    expect(labels.contains("Choose targets in Sound & connections.") && !labels.contains(unavailable),
           "native popup asks for targets only when none are saved")
    model.onAutoDeviceChanged("fixture", true); model.onAutoDeviceChanged("a1-b2-c3-d4-e5-f6", true)
    try FileManager.default.removeItem(at: root.appendingPathComponent("empty-inventory"))
    module.poll(); wait()
    labels = bluetoothPopupLabels(model)
    expect(labels.contains("Disconnect") && labels.contains("1 chosen devices unavailable; targets are preserved.") && !labels.contains(unavailable),
           "partial native discovery keeps matching-device actions and the truthful missing count")
    try Data().write(to: root.appendingPathComponent("unmatched-inventory"))
    module.poll(); wait()
    labels = bluetoothPopupLabels(model)
    expect(labels.contains(unavailable) && labels.contains("2 chosen devices unavailable; targets are preserved.") && !labels.contains("Disconnect"),
           "nonempty unmatched inventory does not masquerade as matching saved targets")
    try FileManager.default.removeItem(at: root.appendingPathComponent("unmatched-inventory"))
    try Data().write(to: root.appendingPathComponent("full-inventory"))
    module.poll(); wait()
    labels = bluetoothPopupLabels(model)
    events = discoveryEvents()
    expect(labels.contains("Disconnect") && !labels.contains(unavailable) && !labels.contains(where: { $0.contains("targets are preserved") }),
           "fully matching native inventory exposes actions without missing-target guidance")
    expect(events.last?["parsed_device_count"] == "2" && events.last?["matched_target_count"] == "2" && model.selectedAddresses == retained,
           "changed matching inventory emits updated counts without rewriting saved IDs")
    model.errorMessage = "Unrelated storage cleanup failure"
    let beforeDisable = try calls()
    model.onModuleChanged(.bluetooth, false)
    wait()
    let afterDisable = try calls()
    expect(model.errorMessage == "Unrelated storage cleanup failure" && afterDisable == beforeDisable, "feature disable neither clears unrelated errors nor mutates Bluetooth")
    expect(logger.flushForTesting(), "final Bluetooth diagnostic records drain in test")
    let encoded = memory.lines.map { String(decoding: $0, as: UTF8.self) }.joined()
    expect(!encoded.contains(exact) && !encoded.contains("Fixture speaker") && !encoded.contains("--connect fixture") && !encoded.contains(root.path) &&
           !encoded.contains("a1-b2-c3-d4-e5-f6") && !encoded.contains("f1-e2-d3-c4-b5-a6") && !encoded.contains("SENTINEL"),
           "host and command Bluetooth hooks omit raw error, device name/address and executable path")
}

// Native AX inspection of this fixture's production popup row only. SwiftUI
// nodes implement selectors without declaring NSAccessibilityProtocol adoption.
private func bluetoothPopupLabels(_ model: DashboardModel) -> [String] {
    _ = NSApplication.shared
    let attribute = "AXEnhancedUserInterface" as NSString
    let old = NSApp.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?.takeUnretainedValue()
    _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: attribute)
    defer { _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: old ?? NSNumber(value: false), with: attribute) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0
    let view = NSHostingView(rootView: QuickWidget(model: model, entry: WidgetEntry(.bluetooth)))
    window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    func labels() -> [String] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> [String] {
            guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            var result = [String]()
            for key in ["accessibilityLabel", "accessibilityValue"] where node.responds(to: NSSelectorFromString(key)) {
                if let text = node.value(forKey: key) as? String { result.append(text) }
            }
            if node.responds(to: NSSelectorFromString("accessibilityChildren")) {
                result += (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(walk)
            }
            return result
        }
        return walk(view)
    }
    let deadline = Date().addingTimeInterval(1)
    repeat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        view.layoutSubtreeIfNeeded(); window.display()
        let result = labels()
        if result.contains("Bluetooth") { return result }
    } while Date() < deadline
    return labels()
}

/// Real host callbacks and subprocess runner while a fixture helper is blocked.
/// The helper self-expires; no installed helper, radio or launch agent is touched.
private func runBluetoothBlockedDisableTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-drain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("blueutil")
    try """
    #!/bin/sh
    cd "$(dirname "$0")" || exit 70
    echo "$*" >> calls
    if [ -f gate ]; then
      touch entered
      count=0
      while [ -f gate ] && [ "$count" -lt 200 ]; do
        /bin/sleep 0.01
        count=$((count + 1))
      done
    fi
    case "$*" in
      '--power') echo 1 ;;
      '--paired --format json') echo '[{"address":"fixture","name":"Fixture","connected":false}]' ;;
      *) exit 64 ;;
    esac
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let suite = "fix-mac-os.bluetooth-drain.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
    defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain); defaults.removePersistentDomain(forName: suite) }
    for feature in AppModule.allCases { ModuleSettings(defaults: defaults).set(feature, enabled: false) }
    defaults.set(false, forKey: "bluetooth.autoEnabled")
    // This fixture tests that late injected takeover never commits this choice.
    // Automatic reconnect stays off, independent of ambient legacy-service state.
    defaults.set(false, forKey: "bluetooth.legacyTakenOver")
    defaults.set([], forKey: "bluetooth.autoAddresses")
    let logger = Diagnostics(sink: MemoryDiagnosticSink())
    let runner = CommandRunner(diagnostics: logger)
    let module = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: CommandRunner(diagnostics: logger), blueutil: executable.path, audioTool: nil, waitForConnection: {}),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways },
        legacyServiceTakeover: { _ = try runner.run(executable.path, ["--power"]) })
    let model = DashboardModel()
    let audio = AudioModule(backend: Exit75AudioBackend(), defaults: defaults)
    let host = AppDelegate(model: model, preferences: defaults, makeAudio: { audio }, makeBluetooth: { module }, diagnostics: logger)
    defer { module.stop(); audio.stop(); withExtendedLifetime(host) {} }
    func pump(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        expect(condition(), "blocked Bluetooth fixture reaches bounded main-loop condition")
    }
    func heartbeat(_ label: String, action: () -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        action()
        var beat = false
        DispatchQueue.main.async { beat = true }
        pump { beat }
        expect(ProcessInfo.processInfo.systemUptime - started < 0.25, "\(label) keeps the main queue responsive with helper blocked")
        expect(module.isBusy, "\(label) retains worker ownership until actual drain")
    }
    for _ in 0..<3 {
        try Data().write(to: root.appendingPathComponent("gate"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("entered"))
        model.onModuleChanged(.bluetooth, true)
        pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path) }
        heartbeat("automatic reconnection off") { model.onAutomaticReconnectChanged(false) }
        heartbeat("target uncheck") { model.onAutoDeviceChanged("fixture", false) }
        heartbeat("feature disable") { model.onModuleChanged(.bluetooth, false) }
        expect(model.stoppingModules.contains(.bluetooth), "host reports asynchronous Bluetooth drain")
        heartbeat("rapid re-enable refusal") { model.onModuleChanged(.bluetooth, true) }
        expect(!model.enabledModules.contains(.bluetooth), "host refuses re-enable until old owner drains")
        heartbeat("quit during feature drain") {
            expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "quit veto remains truthful during Bluetooth drain")
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("gate"))
        pump { !module.isBusy && !model.stoppingModules.contains(.bluetooth) }
        expect(!model.enabledModules.contains(.bluetooth), "late completion does not revive disabled Bluetooth")
    }
    // Explicit legacy-service takeover uses the same serial worker/drain path.
    // Inject a slow command instead of invoking launchctl or a real service.
    model.onModuleChanged(.bluetooth, true)
    pump { !module.isBusy }
    try Data().write(to: root.appendingPathComponent("gate"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("entered"))
    model.onTakeOverLegacy()
    pump { FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path) }
    heartbeat("disable during legacy takeover") { model.onModuleChanged(.bluetooth, false) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("gate"))
    pump { !module.isBusy && !model.stoppingModules.contains(.bluetooth) }
    expect(!defaults.bool(forKey: "bluetooth.legacyTakenOver") && !defaults.bool(forKey: "bluetooth.autoEnabled"), "late takeover completion cannot commit ownership or enable reconnection after disable")
    let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
    expect(!calls.contains("--connect") && !calls.contains("--disconnect") && !calls.contains("--power 1"), "disable fixtures never issue radio or connection mutations")
}
