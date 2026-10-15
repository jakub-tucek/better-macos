import AppKit
import CoreBluetooth

private struct Exit75AudioBackend: AudioRoutingBackend {
    func devices() throws -> [AudioDevice] { [] }
    func current(_ direction: AudioDirection) throws -> String? { nil }
    func select(_ uid: String, direction: AudioDirection) throws { fatalError("No live routing in diagnostic") }
}

// Production host callbacks/module/CommandRunner regression coverage,
// isolated defaults and an executable fixture; never invokes installed blueutil.
func runBluetoothErrorRecoveryTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-exit75-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("blueutil")
    let script = """
    #!/bin/sh
    cd "$(dirname "$0")" || exit 70
    echo "$*" >> calls
    case "$*" in
      '--power') if [ -f powered ]; then echo 1; else echo 0; fi ;;
      '--paired --format json')
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
    let module = BluetoothModule(defaults: defaults,
        backend: BluetoothBackend(runner: CommandRunner(), blueutil: executable.path, audioTool: nil, waitForConnection: {}),
        importLegacyConfiguration: false, authorizationProvider: { .allowedAlways })
    let model = DashboardModel()
    model.enabledModules = []
    model.errorMessage = "Unrelated preexisting error"
    let audio = AudioModule(backend: Exit75AudioBackend(), defaults: defaults)
    let host = AppDelegate(model: model, preferences: defaults, makeAudio: { audio }, makeBluetooth: { module })
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
    model.onBluetoothPowerOn()
    wait()
    let exact = "blueutil failed (exit 75): Failed to switch bluetooth power on in 10 seconds"
    expect(module.lastError == exact && model.errorMessage == exact, "actual host manual action publishes exact screenshot error through real CommandRunner stderr/exit handling")
    module.poll()
    wait()
    expect(module.lastError == nil && model.errorMessage == exact, "healthy discovery with radio still off does not dismiss the unresolved power-on failure")
    try "".write(to: root.appendingPathComponent("succeed"), atomically: true, encoding: .utf8)
    model.onBluetoothPowerOn()
    wait()
    expect(module.radioPoweredOn == true && module.lastError == nil && model.errorMessage == nil, "verified successful retry clears only its owned Bluetooth failure banner")
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
    try "".write(to: root.appendingPathComponent("fail-connect"), atomically: true, encoding: .utf8)
    model.onManualConnection("fixture"); wait()
    let connectionError = model.errorMessage
    expect(connectionError?.contains("Fixture connection unavailable") == true, "manual connection failure uses the same owned host error callback")
    model.onBluetoothPowerOn(); wait()
    expect(model.errorMessage == connectionError, "successful power action cannot resolve a failed device connection")
    try FileManager.default.removeItem(at: root.appendingPathComponent("fail-connect"))
    model.onManualConnection("fixture"); wait()
    expect(module.devices.first?.connected == true && model.errorMessage == nil, "verified retry of the same device connection clears its owned failure")
    model.errorMessage = "Unrelated storage cleanup failure"
    let beforeDisable = try calls()
    model.onModuleChanged(.bluetooth, false)
    wait()
    let afterDisable = try calls()
    expect(model.errorMessage == "Unrelated storage cleanup failure" && afterDisable == beforeDisable, "feature disable neither clears unrelated errors nor mutates Bluetooth")
}
