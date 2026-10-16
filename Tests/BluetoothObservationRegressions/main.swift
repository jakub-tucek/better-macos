import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { print("FAIL: \(message)"); exit(1) }
    print("PASS: \(message)")
}
if CommandLine.arguments.contains("--automatic") { try runBluetoothAutomaticPresentationTests() }
else if CommandLine.arguments.contains("--identity") { try runBluetoothIdentityTests() }
else if CommandLine.arguments.contains("--merged-admission") { try runBluetoothMergedAdmissionTests() }
else if CommandLine.arguments.contains("--merged-manual") { try runBluetoothMergedManualTests() }
else if let index = CommandLine.arguments.firstIndex(of: "--process-repeat"), CommandLine.arguments.count > index + 1,
        let count = Int(CommandLine.arguments[index + 1]), (1...100).contains(count) {
    try runBluetoothProfilerProcessFixtures(repetitions: count)
}
else { try runBluetoothObservationTests() }
print("\(checks) isolated Bluetooth observation checks passed; no live Bluetooth or profiler calls.")
