import AppKit
import ApplicationServices

/// Compatibility entry point; all decisions live in the shared execution module.
final class AXWindowPositionBackend: WindowExecution<AXWindowNativeAccess> {
    init(permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         windowInfo: @escaping () -> [[String: Any]]? = { CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] }) {
        super.init(access: AXWindowNativeAccess(permissionCheck: permissionCheck, windowInfo: windowInfo))
    }
}

struct AXWindowNativeAccess: WindowNativeAccess {
    private let permissionCheck: () -> Bool
    private let windowInfo: () -> [[String: Any]]?
    init(permissionCheck: @escaping () -> Bool, windowInfo: @escaping () -> [[String: Any]]?) {
        self.permissionCheck = permissionCheck
        self.windowInfo = windowInfo
    }
    var permitted: Bool { permissionCheck() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }
    func requestPermission() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    func displays() -> [WindowDisplay] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let r = screen.visibleFrame
            return WindowDisplay(id: CFUUIDCreateString(nil, uuid) as String, bounds: CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height))
        }
    }
    func inventory() -> [[String: Any]]? { windowInfo() }
    func ownerPID(_ entry: [String: Any]) -> Int32? { entry[kCGWindowOwnerPID as String] as? Int32 }
    func bounds(_ entry: [String: Any]) -> CGRect? {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
    func layer(_ entry: [String: Any]) -> Int? { entry[kCGWindowLayer as String] as? Int }
    func applications() -> [WindowApplication] {
        NSWorkspace.shared.runningApplications.map { WindowApplication(pid: $0.processIdentifier, bundle: $0.bundleIdentifier) }
    }
    func frontmostApplication() -> WindowApplication? {
        NSWorkspace.shared.frontmostApplication.map { WindowApplication(pid: $0.processIdentifier, bundle: $0.bundleIdentifier) }
    }
    func application(_ pid: Int32) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func setTimeout(_ element: AXUIElement, seconds: Float) -> Bool {
        AXUIElementSetMessagingTimeout(element, seconds) == .success
    }
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }; return result
    }
    func windows(_ root: AXUIElement) -> [AXUIElement]? { value(root, kAXWindowsAttribute) as? [AXUIElement] }
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func string(_ element: AXUIElement, _ attribute: WindowStringAttribute) -> String? {
        value(element, attribute == .title ? kAXTitleAttribute : kAXSubroleAttribute) as? String
    }
    func bool(_ element: AXUIElement, _ attribute: WindowBoolAttribute) -> Bool? {
        value(element, attribute == .minimized ? kAXMinimizedAttribute : "AXFullScreen") as? Bool
    }
    func isSettable(_ element: AXUIElement, _ attribute: WindowGeometryAttribute) -> Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, key(attribute) as CFString, &settable)
        return settable.boolValue
    }
    func equal(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
    func focused(_ root: AXUIElement) -> CFTypeRef? { value(root, kAXFocusedWindowAttribute) }
    func focusEqual(_ focus: CFTypeRef, _ element: AXUIElement) -> Bool { CFEqual(focus, element) }
    struct WriteValues {
        var size: AXValue
        var position: AXValue
    }
    func writeValues(_ frame: CGRect) -> WriteValues? {
        var size = frame.size, point = frame.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &point) else { return nil }
        return WriteValues(size: s, position: p)
    }
    private func key(_ attribute: WindowGeometryAttribute) -> String {
        attribute == .position ? kAXPositionAttribute : kAXSizeAttribute
    }
    func write(_ element: AXUIElement, _ attribute: WindowGeometryAttribute, _ values: WriteValues) -> Bool {
        AXUIElementSetAttributeValue(element, key(attribute) as CFString, attribute == .position ? values.position : values.size) == .success
    }
}
