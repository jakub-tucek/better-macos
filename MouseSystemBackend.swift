import Foundation
import IOKit
import IOKit.hidsystem
import MouseHID

/// Narrow injectable boundary. No preference writes, generic pointer keys,
/// device heuristics, event taps or input posting are involved.
protocol MouseHIDAccess {
    func readLinear() throws -> Double
    func readTracking() throws -> Double
    func setLinear(_ value: Double) throws
    func setTracking(_ value: Double) throws
}

final class SystemMouseHIDAccess: MouseHIDAccess {
    private func connection<T>(_ operation: (io_connect_t) throws -> T) throws -> T {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { throw failure("IOHIDSystem discovery", kIOReturnNotFound) }
        defer { IOObjectRelease(service) }
        var handle: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 1, &handle) // kIOHIDParamConnectType
        guard result == kIOReturnSuccess else { throw failure("IOHIDSystem parameter connection", result) }
        defer { IOServiceClose(handle) }
        return try operation(handle)
    }
    private func failure(_ operation: String, _ result: IOReturn) -> Error {
        NSError(domain: "MouseHID", code: Int(result), userInfo: [NSLocalizedDescriptionKey:
            "\(operation) failed (IOKit \(String(format: "0x%08x", result))). No generic pointer fallback is used."])
    }
    func readLinear() throws -> Double {
        try connection { handle in
            var value: Unmanaged<CFTypeRef>?
            let result = IOHIDCopyCFTypeParameter(handle, "HIDUseLinearScalingMouseAcceleration" as CFString, &value)
            guard result == kIOReturnSuccess, let object = value?.takeRetainedValue() as? NSNumber,
                  object.doubleValue == 0 || object.doubleValue == 1 else {
                throw failure("Mouse linear-scaling read (requires an explicit restorable 0/1 value)", result)
            }
            return object.doubleValue
        }
    }
    func readTracking() throws -> Double {
        try connection { handle in
            var value = 0.0
            let result = MouseHIDGetAcceleration(handle, &value)
            guard result == kIOReturnSuccess, value.isFinite, (0...3).contains(value) else {
                throw failure("HIDMouseAcceleration read", result)
            }
            return value
        }
    }
    func setLinear(_ value: Double) throws {
        try connection { handle in
            let result = IOHIDSetCFTypeParameter(handle, "HIDUseLinearScalingMouseAcceleration" as CFString, NSNumber(value: value))
            guard result == kIOReturnSuccess else { throw failure("Mouse linear-scaling write", result) }
        }
    }
    func setTracking(_ value: Double) throws {
        try connection { handle in
            let result = MouseHIDSetAcceleration(handle, value)
            guard result == kIOReturnSuccess else { throw failure("HIDMouseAcceleration write", result) }
        }
    }
}

final class SystemMouseBackend: MouseSettingsBackend {
    let identifier = "iohid-mouse-v1"
    private let access: MouseHIDAccess
    init(access: MouseHIDAccess = SystemMouseHIDAccess()) { self.access = access }
    var available: Bool { (try? read()) != nil }
    func read() throws -> MouseOriginalSettings {
        let linear = try access.readLinear()
        let tracking = try access.readTracking()
        guard [0.0, 1.0].contains(linear), tracking.isFinite, (0...3).contains(tracking) else { throw MouseModule.unavailable }
        return MouseOriginalSettings(acceleration: .number(linear), speed: .number(tracking))
    }
    func apply(acceleration: Bool, speed: Double) throws {
        guard speed.isFinite, (0.1...3).contains(speed) else { throw MouseModule.unavailable }
        try access.setLinear(acceleration ? 0 : 1)
        try access.setTracking(speed)
        let actual = try read()
        guard actual.acceleration == .number(acceleration ? 0 : 1),
              case .number(let tracking) = actual.speed, abs(tracking - speed) < 1.0 / 65536 else {
            throw NSError(domain: "MouseHID", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mouse settings did not read back as requested; restoring originals."])
        }
    }
    func restore(_ original: MouseOriginalSettings) throws {
        // Runtime parameters cannot safely be deleted through this API. Refuse
        // absent or malformed snapshots instead of guessing an original default.
        guard case .number(let linear) = original.acceleration, [0.0, 1.0].contains(linear),
              case .number(let tracking) = original.speed, tracking.isFinite, (0...3).contains(tracking) else {
            throw MouseModule.unavailable
        }
        try access.setLinear(linear)
        try access.setTracking(tracking)
        let actual = try read()
        guard actual.acceleration == original.acceleration,
              case .number(let restored) = actual.speed, abs(restored - tracking) < 1.0 / 65536 else {
            throw NSError(domain: "MouseHID", code: 3, userInfo: [NSLocalizedDescriptionKey: "Original mouse runtime settings did not read back; recovery journal retained."])
        }
    }
}
