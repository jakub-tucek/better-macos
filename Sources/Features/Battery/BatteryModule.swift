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
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 5
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
                    LabeledContent("Battery condition", value: snapshot.condition ?? "Unavailable")
                    LabeledContent("Cycle count", value: snapshot.cycles.map(String.init) ?? "Unavailable")
                    LabeledContent("Battery temperature", value: snapshot.temperature.map { String(format: "%.1f °C", $0) } ?? "Unavailable")
                    if let date = snapshot.sampledAt {
                        Text("Updated \(date.formatted(date: .omitted, time: .shortened)) · refreshes every 30 seconds")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else { Text(snapshot.status).foregroundStyle(.secondary) }
            if expanded { Text("Read-only. Charging and power settings stay under macOS control.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
