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
    runBatteryPowerTests()
}

private func runBatteryPowerTests() {
    let now = Date(timeIntervalSince1970: 100)
    let ac: [String: Any] = [kIOPSPowerSourceStateKey: kIOPSACPowerValue]
    let dc: [String: Any] = [kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
    let readings: [String: Any] = ["Voltage": 12000, "InstantAmperage": 2000,
        "AdapterDetails": ["Watts": 65], "PowerTelemetryData": ["SystemPowerIn": 40000, "SystemLoad": 16000]]
    let charging = BatterySnapshot.decode(source: ac, properties: readings, now: now)
    expect(charging.adapterWatts == 40 && charging.adapterRatedWatts == 65 && charging.batteryWatts == 24 && charging.systemWatts == 16,
           "Battery distinguishes live adapter input, rated capacity, battery charging and system consumption")
    expect(charging.batteryFlow == "Charging battery" && !charging.systemWattsDerived,
           "Battery describes positive measured current as charging and uses reported system load")
    var fallback = readings
    fallback["PowerTelemetryData"] = ["SystemPowerIn": 40000]
    let estimated = BatterySnapshot.decode(source: ac, properties: fallback, now: now)
    expect(estimated.systemWatts == 16 && estimated.systemWattsDerived, "Battery derives system demand only when both power inputs are known")
    var discharge = readings
    discharge["InstantAmperage"] = NSNumber(value: UInt64.max - 999)
    let unplugged = BatterySnapshot.decode(source: dc, properties: discharge, now: now)
    expect(unplugged.batteryWatts == -12 && unplugged.adapterWatts == 0 && unplugged.adapterRatedWatts == nil && unplugged.systemWatts == 12,
           "Battery decodes unsigned negative current and discards stale adapter/system telemetry after unplugging")
    expect(unplugged.batteryFlow == "Battery supplying power", "Negative battery power supplies the Mac")
    let assisted = BatterySnapshot.decode(source: ac, properties: discharge, now: now)
    expect(assisted.adapterWatts == 40 && assisted.batteryWatts == -12,
           "Battery preserves simultaneous adapter input and battery discharge without inventing battery contribution from a load gap")
    let ratingOnly = BatterySnapshot.decode(source: ac, properties: ["AdapterDetails": ["Watts": 65]], now: now)
    expect(ratingOnly.adapterWatts == nil && ratingOnly.systemWatts == nil && ratingOnly.batteryWatts == nil,
           "Charger rating alone never masquerades as live consumption or zero battery power")
    let malformed = BatterySnapshot.decode(source: ac, properties: ["Voltage": 12000, "InstantAmperage": Double.infinity,
        "PowerTelemetryData": ["SystemPowerIn": -1, "SystemLoad": true]], now: now)
    expect(malformed.adapterWatts == nil && malformed.systemWatts == nil && malformed.batteryWatts == nil,
           "Battery rejects nonfinite current, negative input and boolean power telemetry")
    fallback["PowerTelemetryData"] = ["SystemPowerIn": 10000]
    expect(BatterySnapshot.decode(source: ac, properties: fallback, now: now).systemWatts == nil,
           "Contradictory power balance remains unavailable instead of reporting negative consumption")
    let idle = BatterySnapshot.decode(source: ac, properties: ["Voltage": 12000, "Amperage": 0], now: now)
    expect(idle.batteryWatts == 0 && idle.batteryFlow == "Battery idle" && idle.systemWatts == nil,
           "Measured idle battery is distinct from unavailable telemetry")
}
