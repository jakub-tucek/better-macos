import Foundation
import IOKit
import IOKit.ps
import SwiftUI

/// A current reading only. No history, charging writes, helpers or sleep assertions.
struct BatterySnapshot: Equatable {
    enum Availability { case available, absent, unavailable }
    var availability: Availability = .unavailable
    var percent: Int?
    var externalPower: Bool?
    var charging: Bool?
    var charged: Bool?
    var condition: String?
    var cycles: Int?
    var temperature: Double?
    var adapterWatts: Double?
    var adapterRatedWatts: Double?
    /// Positive into battery; negative out of battery. V × I, not charger rating.
    var batteryWatts: Double?
    var systemWatts: Double?
    var systemWattsDerived = false
    var voltage: Double?
    var amperage: Double?
    var sampledAt: Date?

    var status: String {
        guard availability == .available else {
            return availability == .absent ? "No built-in battery" : "Battery information unavailable"
        }
        if charging == true { return "Charging" }
        if externalPower == true { return charged == true ? "Fully charged · Power adapter" : "Not charging · Power adapter" }
        if externalPower == false { return "On battery" }
        return "Power source unavailable"
    }
    var chargeText: String { percent.map { "\($0)%" } ?? "—" }
    var symbol: String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case 0..<15: return "battery.0percent"
        case 15..<40: return "battery.25percent"
        case 40..<65: return "battery.50percent"
        case 65..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    static func watts(_ value: Double?) -> String { value.map { String(format: "%.1f W", abs($0)) } ?? "Unavailable" }
    var batteryFlow: String {
        guard let batteryWatts else { return "Flow unavailable" }
        if batteryWatts > 0.05 { return "Charging battery" }
        if batteryWatts < -0.05 { return "Battery supplying power" }
        return "Battery idle"
    }

    static func decode(source: [String: Any], properties: [String: Any], now: Date) -> BatterySnapshot {
        var result = BatterySnapshot(availability: .available, sampledAt: now)
        if let current = source[kIOPSCurrentCapacityKey] as? Double,
           let maximum = source[kIOPSMaxCapacityKey] as? Double,
           current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum {
            result.percent = Int((current / maximum * 100).rounded())
        }
        if let state = source[kIOPSPowerSourceStateKey] as? String {
            if state == kIOPSACPowerValue { result.externalPower = true }
            else if state == kIOPSBatteryPowerValue { result.externalPower = false }
        }
        result.charging = source[kIOPSIsChargingKey] as? Bool
        result.charged = source[kIOPSIsChargedKey] as? Bool
        result.condition = source[kIOPSBatteryHealthKey] as? String
        if let cycles = properties["CycleCount"] as? Int, cycles >= 0 { result.cycles = cycles }
        // AppleSmartBattery Temperature is reported in tenths of a kelvin.
        if let raw = properties["Temperature"] as? Double, raw.isFinite {
            let celsius = raw / 10 - 273.15
            if (-20...100).contains(celsius) { result.temperature = celsius }
        }
        func number(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        func milliwatts(_ value: Any?) -> Double? {
            guard let value = number(value), (0...1_000_000).contains(value) else { return nil }
            return value / 1000
        }
        if let mv = number(properties["Voltage"]), (1000...30_000).contains(mv) {
            result.voltage = mv / 1000
            // IOKit can bridge negative current as an unsigned two's-complement NSNumber.
            if let current = (properties["InstantAmperage"] ?? properties["Amperage"]) as? NSNumber,
               CFGetTypeID(current) != CFBooleanGetTypeID(), current.doubleValue.isFinite {
                let ma = current.int64Value
                if (-30_000...30_000).contains(ma) {
                    result.amperage = Double(ma) / 1000
                    result.batteryWatts = mv * Double(ma) / 1_000_000
                }
            }
        }
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        if result.externalPower == true {
            result.adapterWatts = milliwatts(telemetry["SystemPowerIn"])
            let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]
            if let watts = number(adapter["Watts"]), (1...1000).contains(watts) { result.adapterRatedWatts = watts }
        } else if result.externalPower == false {
            // Adapter telemetry may linger after unplugging. Never present it as live input.
            result.adapterWatts = 0
        }
        if result.externalPower == true { result.systemWatts = milliwatts(telemetry["SystemLoad"]) }
        if result.systemWatts == nil, let input = result.adapterWatts, let battery = result.batteryWatts {
            let consumption = input - battery
            if (0...1000).contains(consumption) {
                result.systemWatts = consumption
                result.systemWattsDerived = true
            }
        }
        return result
    }
}

enum BatteryReader {
    static func read() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return BatterySnapshot() }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if description[kIOPSIsPresentKey] as? Bool == false { continue }
            var properties: [String: Any] = [:]
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var values: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &values, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                    properties = values?.takeRetainedValue() as? [String: Any] ?? [:]
                }
            }
            return .decode(source: description, properties: properties, now: Date())
        }
        return BatterySnapshot(availability: .absent, sampledAt: Date())
    }
}

final class BatteryModule {
    private let read: () -> BatterySnapshot
    private var timer: Timer?
    private(set) var snapshot = BatterySnapshot()
    var onChange: (BatterySnapshot) -> Void = { _ in }
    init(read: @escaping () -> BatterySnapshot = BatteryReader.read) { self.read = read }
    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func refresh() { snapshot = read(); onChange(snapshot) }
    func stop() { timer?.invalidate(); timer = nil; snapshot = BatterySnapshot(); onChange(snapshot) }
    deinit { timer?.invalidate() }
}

struct BatteryStatusView: View {
    let snapshot: BatterySnapshot
    var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.availability == .available {
                HStack {
                    Text(snapshot.chargeText).font(.title2.monospacedDigit())
                    Spacer()
                    Text(snapshot.status).font(.callout).foregroundStyle(.secondary)
                }
                if let percent = snapshot.percent { ProgressView(value: Double(percent), total: 100).accessibilityLabel("Battery charge") }
                if expanded {
                    LabeledContent("Adapter input", value: BatterySnapshot.watts(snapshot.adapterWatts))
                    LabeledContent("Mac consumption · estimate", value: BatterySnapshot.watts(snapshot.systemWatts))
                    LabeledContent(snapshot.batteryFlow, value: BatterySnapshot.watts(snapshot.batteryWatts))
                    LabeledContent("Battery condition", value: snapshot.condition ?? "Unavailable")
                    LabeledContent("Cycle count", value: snapshot.cycles.map(String.init) ?? "Unavailable")
                    LabeledContent("Battery temperature", value: snapshot.temperature.map { String(format: "%.1f °C", $0) } ?? "Unavailable")
                    if let date = snapshot.sampledAt {
                        Text("Updated \(date.formatted(date: .omitted, time: .standard)) · refreshes every 5 seconds")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else { Text(snapshot.status).foregroundStyle(.secondary) }
            if expanded { Text("Read-only. Charging and power settings stay under macOS control.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct BatteryDetailsView: View {
    let snapshot: BatterySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if snapshot.availability == .available {
                HStack(spacing: 20) {
                    Image(systemName: snapshot.symbol).font(.system(size: 40, weight: .light)).foregroundStyle(snapshot.percent == nil ? Color.secondary : .green).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.chargeText).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                        Text(snapshot.status).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(snapshot.temperature.map { String(format: "%.1f °C", $0) } ?? "Temperature unavailable")
                        Text(snapshot.condition ?? "Condition unavailable").foregroundStyle(.secondary)
                    }.font(.callout)
                }
                if let percent = snapshot.percent { ProgressView(value: Double(percent), total: 100).tint(.green).accessibilityLabel("Battery charge") }
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Power flow").font(.headline)
                        Spacer()
                        Label(snapshot.sampledAt == nil ? "Readings unavailable" : "Updates · 5s", systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { adapter; connector((snapshot.adapterWatts ?? 0) > 0.05 ? "arrow.right" : "minus"); mac; connector(batteryArrow); battery }
                        VStack(spacing: 16) { adapter; mac; battery }
                    }
                    Text("Adapter input is live power delivered to the Mac, not the charger’s rated maximum. Readings are estimates and may update at different times.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(20).modifier(AppSurface())
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { health; electrical }
                    VStack(alignment: .leading, spacing: 20) { health; electrical }
                }
                if let date = snapshot.sampledAt {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard)) · Read-only; charging stays under macOS control.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(snapshot.status, systemImage: "battery.0percent").font(.title3)
                Text("Battery details appear when macOS reports a built-in battery. No charging or power settings are changed.")
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var adapter: some View {
        node("Power adapter", symbol: "powerplug", watts: snapshot.adapterWatts,
             detail: snapshot.externalPower == false ? "Disconnected" : snapshot.adapterRatedWatts.map { "\(Int($0)) W rated maximum" } ?? "Rating unavailable", color: .secondary)
    }
    private var mac: some View {
        node("Mac", symbol: "laptopcomputer", watts: snapshot.systemWatts,
             detail: snapshot.systemWattsDerived ? "Estimated from power balance" : "Estimated system consumption", color: .accentColor)
    }
    private var battery: some View {
        node("Battery", symbol: snapshot.symbol, watts: snapshot.batteryWatts, detail: snapshot.batteryFlow, color: snapshot.percent == nil ? .secondary : .green)
    }
    private var batteryArrow: String {
        guard let watts = snapshot.batteryWatts, abs(watts) > 0.05 else { return "minus" }
        return watts > 0 ? "arrow.right" : "arrow.left"
    }
    private func connector(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.tertiary).accessibilityHidden(true)
    }
    private func node(_ title: String, symbol: String, watts: Double?, detail: String, color: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(color).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium))
            Text(BatterySnapshot.watts(watts)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(minWidth: 145, maxWidth: .infinity).padding(.vertical, 12)
            .accessibilityElement(children: .combine)
    }
    private var health: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery health").font(.headline)
            LabeledContent("Condition", value: snapshot.condition ?? "Unavailable")
            LabeledContent("Cycles", value: snapshot.cycles.map(String.init) ?? "Unavailable")
            LabeledContent("Temperature", value: snapshot.temperature.map { String(format: "%.1f °C", $0) } ?? "Unavailable")
        }.frame(minWidth: 210, maxWidth: .infinity, alignment: .leading).padding(20).modifier(AppSurface())
    }
    private var electrical: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery electrical readings").font(.headline)
            LabeledContent("Voltage", value: snapshot.voltage.map { String(format: "%.2f V", $0) } ?? "Unavailable")
            LabeledContent("Current", value: snapshot.amperage.map { String(format: "%+.2f A", $0) } ?? "Unavailable")
            Text("Positive current charges the battery; negative current supplies the Mac.").font(.caption).foregroundStyle(.secondary)
        }.frame(minWidth: 210, maxWidth: .infinity, alignment: .leading).padding(20).modifier(AppSurface())
    }
}
