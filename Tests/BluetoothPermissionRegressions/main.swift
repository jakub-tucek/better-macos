import AppKit
import CoreBluetooth

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else { print("FAIL: \(label)"); exit(1) }
    print("PASS: \(label)")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("blueutil-permission-fixture-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let executable = root.appendingPathComponent("blueutil")
try """
#!/bin/sh
cd "$(dirname "$0")" || exit 70
echo "$*" >> calls
mode=$(cat mode)
case "$mode" in
  mid-abort|mid-signal)
    touch entered
    count=0
    while [ ! -f release ] && [ "$count" -lt 200 ]; do
      /bin/sleep 0.01
      count=$((count + 1))
    done
    if [ "$mode" = mid-signal ]; then kill -TERM $$; else exit 134; fi ;;
  abort) echo 'Synthetic access failure' >&2; exit 134 ;;
  signal) kill -TERM $$ ;;
  timeout) exit 75 ;;
  pipe)
    (
      count=0
      while [ ! -f release ] && [ "$count" -lt 200 ]; do
        /bin/sleep 0.01
        count=$((count + 1))
      done
    ) &
    echo 1
    exit 0 ;;
esac
case "$*" in
  '--power')
    if [ "$mode" = invalid-power ]; then printf 'SENTINEL_INVALID_POWER';
    elif [ "$mode" = off ]; then echo 0; else echo 1; fi ;;
  '--paired --format json')
    if [ "$mode" = connect-failure ]; then echo '[{"address":"fixture","name":"Fixture","connected":false}]'; else echo '[]'; fi ;;
  '--connect fixture') exit 75 ;;
  *) exit 64 ;;
esac
""".write(to: executable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
let suite = "fix-mac-os.permission-fixture.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
defer { defaults.setVolatileDomain(registered, forName: UserDefaults.registrationDomain); defaults.removePersistentDomain(forName: suite) }
defaults.set(true, forKey: "bluetooth.autoEnabled")
defaults.set([], forKey: "bluetooth.autoAddresses")
// Neutralize ambient legacy-service presence for this isolated reconnect policy.
defaults.set(true, forKey: "bluetooth.legacyTakenOver")
let diagnosticSink = PermissionDiscoveryDiagnostics()
let logger = Diagnostics(sink: diagnosticSink)
var authorization = CBManagerAuthorization.allowedAlways
let module = BluetoothModule(defaults: defaults,
    backend: BluetoothBackend(runner: CommandRunner(diagnostics: logger), blueutil: executable.path, audioTool: nil, waitForConnection: {}),
    importLegacyConfiguration: false, authorizationProvider: { authorization }, diagnostics: logger)
defer { module.stop() }
func mode(_ name: String) throws { try name.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func wait() {
    let deadline = Date().addingTimeInterval(5)
    while module.isBusy && Date() < deadline { pump(0.005) }
    check(!module.isBusy, "worker completes before fixture deadline")
}
func calls() -> Int {
    ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").count
}

try mode("off")
module.poll(); wait()
check(module.radioPoweredOn == false && !module.permissionRequired, "parent allowed plus successful zero power is represented as radio off")
check(logger.flushForTesting() && diagnosticSink.latestDiscovery?["radio_state"] == "off" && diagnosticSink.latestDiscovery?["parsed_device_count"] == "0",
      "successful exact radio-off/empty reads log observed scalar values")
try mode("abort")
module.poll(); wait()
check(module.lastError?.contains("134") == true && !module.permissionRequired, "child exit 134 does not falsely set parent authorization denied")
check(module.reconnectSummary.contains("Could not read Bluetooth status") && module.reconnectSummary.contains("134"), "new helper failure replaces stale radio-off guidance with observation error")
check(logger.flushForTesting() && diagnosticSink.latestDiscovery?["discovery_outcome"] == "command_failure" && diagnosticSink.latestDiscovery?["read_stage"] == "power" && diagnosticSink.latestDiscovery?["decode_outcome"] == "not_attempted",
      "power command failure is distinct from an unattempted paired decode")
check(diagnosticSink.latestDiscovery?["parent_authorization"] == "allowed" && diagnosticSink.latestDiscovery?["helper_authorization"] == "unknown",
      "helper exit 134 never becomes a diagnostic authorization verdict")
print("OBSERVED status=\(module.status); summary=\(module.reconnectSummary)")

for failure in ["signal", "timeout"] {
    try mode(failure)
    let before = calls()
    module.poll(); wait()
    check(module.lastError != nil && calls() == before + 1, "\(failure) fails one command without recursive retry")
    var beat = false
    DispatchQueue.main.async { beat = true }
    pump(0.02)
    check(beat, "\(failure) leaves main queue responsive")
}

for failure in ["mid-abort", "mid-signal"] {
    try? FileManager.default.removeItem(at: root.appendingPathComponent("release"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("entered"))
    try mode(failure)
    let before = calls()
    module.poll()
    let deadline = Date().addingTimeInterval(1)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path) && Date() < deadline { pump(0.005) }
    check(FileManager.default.fileExists(atPath: root.appendingPathComponent("entered").path), "\(failure) reaches active command gate")
    var beat = false
    DispatchQueue.main.async { beat = true }
    pump(0.02)
    check(beat && module.isBusy, "\(failure) does not block main while command is active")
    try Data().write(to: root.appendingPathComponent("release"))
    wait()
    check(module.lastError != nil && calls() == before + 1 && !module.permissionRequired,
          "\(failure) completes once without follow-on command or inferred parent denial")
}
try? FileManager.default.removeItem(at: root.appendingPathComponent("release"))

try mode("abort")
let beforeTimer = calls()
module.start(); wait()
pump(0.15)
check(calls() == beforeTimer + 1, "failure does not hot-loop helper launches")
pump(5.1); wait()
check(calls() == beforeTimer + 2, "persistent helper failure retries once on five-second timer")
module.stop()

try mode("pipe")
module.start()
pump(0.15)
let beforePipe = calls()
var beat = false
DispatchQueue.main.async { beat = true }
pump(0.02)
check(beat && module.isBusy, "exited helper with inherited pipe leaves worker busy but main queue responsive")
for _ in 0..<100 { module.poll() }
check(calls() == beforePipe, "busy inherited-pipe drain prevents overlapping helper launches")
var drained = 0
module.stop { drained += 1 }
check(drained == 0, "stop retains ownership until inherited pipe really closes")
try Data().write(to: root.appendingPathComponent("release"))
wait(); pump(0.02)
check(drained == 1, "inherited-pipe drain completes callback exactly once")

authorization = .denied
let beforeDenied = calls()
module.start(); pump(0.02)
check(module.permissionRequired && calls() == beforeDenied, "actual parent denial prevents new helper launches")
check(logger.flushForTesting() && diagnosticSink.latestDiscovery?["parent_authorization"] == "denied" && diagnosticSink.latestDiscovery?["discovery_outcome"] == "parent_access_required" && diagnosticSink.latestDiscovery?["helper_authorization"] == "unknown",
      "known parent denial is logged separately from unqueried helper authorization")
module.stop()
authorization = .allowedAlways
try mode("off")
module.start(); wait(); module.stop()
defaults.set(["fixture"], forKey: "bluetooth.autoAddresses")
defaults.set(false, forKey: "bluetooth.protectAudio")
defaults.set(false, forKey: "bluetooth.switchAudio")
try mode("connect-failure")
module.start(); wait()
check(!module.legacyServicePresent && module.lastError != nil && !module.reconnectSummary.contains("Could not read Bluetooth status") && !module.observationStale,
      "automatic connection failure is not mislabeled as failed initial discovery")
module.stop()
defaults.set([], forKey: "bluetooth.autoAddresses")
try mode("invalid-power")
module.start(); wait()
check(logger.flushForTesting() && diagnosticSink.latestDiscovery?["discovery_outcome"] == "invalid_power_state" && diagnosticSink.latestDiscovery?["command_outcome"] == "success" && diagnosticSink.latestDiscovery?["decode_outcome"] == "not_attempted",
      "invalid power readback is not mislabeled as a command exit or paired JSON failure")
check(module.observationStale && !module.permissionRequired, "invalid power observation preserves error precedence without inventing parent denial")
module.stop()
print("\(checks) focused permission-context checks passed; no live TCC or Bluetooth access.")
