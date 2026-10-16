import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { print("FAIL: \(message)"); exit(1) }
    print("PASS: \(message)")
}
try runBluetoothObservationTests()
print("\(checks) isolated Bluetooth observation checks passed; no live Bluetooth or profiler calls.")
