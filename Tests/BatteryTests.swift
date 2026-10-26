import Foundation
import IOKit.ps

func runBatteryTests() {
    let now = Date(timeIntervalSince1970: 100)
    let source: [String: Any] = [kIOPSCurrentCapacityKey: 40.0, kIOPSMaxCapacityKey: 80.0,
        kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false,
        kIOPSIsChargedKey: false, kIOPSBatteryHealthKey: "Good"]
    let snapshot = BatterySnapshot.decode(source: source, properties: ["CycleCount": 321, "Temperature": 3031.5], now: now)
    expect(snapshot.percent == 50 && snapshot.cycles == 321 && snapshot.condition == "Good", "Battery normalizes OS charge capacity and decodes condition/cycles")
    expect(abs((snapshot.temperature ?? 0) - 30) < 0.01 && snapshot.sampledAt == now, "Battery converts tenths kelvin and timestamps the reading")
    expect(snapshot.status == "Not charging · Power adapter", "Battery does not invent a charge-limit reason when charging is paused")
    let malformed = BatterySnapshot.decode(source: [kIOPSCurrentCapacityKey: 90.0, kIOPSMaxCapacityKey: 0.0],
                                           properties: ["CycleCount": -1, "Temperature": Double.nan], now: now)
    expect(malformed.percent == nil && malformed.temperature == nil && malformed.cycles == nil && malformed.externalPower == nil,
           "Battery rejects invalid readings instead of showing zero or invented metrics")
    expect(BatterySnapshot(availability: .absent).status == "No built-in battery" && BatterySnapshot().status == "Battery information unavailable",
           "Battery distinguishes missing hardware from an unavailable read")
    var reads = 0
    var published = BatterySnapshot()
    let owner = BatteryModule(read: { reads += 1; return snapshot })
    owner.onChange = { published = $0 }
    owner.start(); owner.start()
    expect(reads == 1 && published == snapshot, "Battery starts with an injected read and repeated start does not duplicate monitoring")
    owner.stop()
    expect(published.availability == .unavailable, "Battery stop clears stale presentation")
    owner.start(); owner.stop()
    expect(reads == 2, "Battery can restart after disabling")
}
