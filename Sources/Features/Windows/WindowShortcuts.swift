import AppKit
import Carbon

/// First-party keyboard tiling. Key positions follow Rectangle's standard preset.
enum WindowShortcutAction: UInt32, CaseIterable, Identifiable {
    case left = 1, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, previousDisplay, nextDisplay, restore
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .left: return "Left half"
        case .right: return "Right half"
        case .top: return "Top half"
        case .bottom: return "Bottom half"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .previousDisplay: return "Previous display"
        case .nextDisplay: return "Next display"
        case .restore: return "Restore original size"
        }
    }
    var key: UInt32 {
        let code: Int
        switch self {
        case .left, .previousDisplay: code = kVK_LeftArrow
        case .right, .nextDisplay: code = kVK_RightArrow
        case .top: code = kVK_UpArrow
        case .bottom: code = kVK_DownArrow
        case .topLeft: code = kVK_ANSI_U
        case .topRight: code = kVK_ANSI_I
        case .bottomLeft: code = kVK_ANSI_J
        case .bottomRight: code = kVK_ANSI_K
        case .maximize: code = kVK_Return
        case .center: code = kVK_ANSI_C
        case .restore: code = kVK_Delete
        }
        return UInt32(code)
    }
    var modifiers: UInt32 {
        UInt32(controlKey | optionKey | ((self == .previousDisplay || self == .nextDisplay) ? cmdKey : 0))
    }
    var shortcut: String {
        let keyName: String
        switch self {
        case .left, .previousDisplay: keyName = "←"
        case .right, .nextDisplay: keyName = "→"
        case .top: keyName = "↑"
        case .bottom: keyName = "↓"
        case .topLeft: keyName = "U"
        case .topRight: keyName = "I"
        case .bottomLeft: keyName = "J"
        case .bottomRight: keyName = "K"
        case .maximize: keyName = "↩"
        case .center: keyName = "C"
        case .restore: keyName = "⌫"
        }
        return "⌃⌥" + ((self == .previousDisplay || self == .nextDisplay) ? "⌘" : "") + keyName
    }

    /// AX coordinates: origin at top left; bounds already exclude Dock/menu bar.
    func destination(for frame: CGRect, displays: [WindowDisplay], original: CGRect? = nil) -> CGRect? {
        func valid(_ rect: CGRect) -> Bool {
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
        }
        guard valid(frame), !displays.isEmpty, displays.allSatisfy({ valid($0.bounds) }) else { return nil }
        let ordered = displays.sorted {
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return $0.id < $1.id
        }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        guard let index = ordered.indices.max(by: { area(ordered[$0].bounds.intersection(frame)) < area(ordered[$1].bounds.intersection(frame)) }),
              ordered[index].bounds.intersects(frame) else { return nil }
        let bounds = ordered[index].bounds
        func fit(_ rect: CGRect, in target: CGRect) -> CGRect {
            let width = min(rect.width, target.width), height = min(rect.height, target.height)
            return CGRect(x: min(max(rect.minX, target.minX), target.maxX - width),
                          y: min(max(rect.minY, target.minY), target.maxY - height), width: width, height: height)
        }
        if self == .restore {
            guard let original, valid(original) else { return nil }
            let target = ordered.max { area($0.bounds.intersection(original)) < area($1.bounds.intersection(original)) }
            return fit(original, in: target.flatMap { $0.bounds.intersects(original) ? $0.bounds : nil } ?? bounds)
        }
        if self == .nextDisplay || self == .previousDisplay {
            guard ordered.count > 1 else { return nil }
            let target = ordered[(index + (self == .nextDisplay ? 1 : ordered.count - 1)) % ordered.count].bounds
            let moved = CGRect(x: target.minX + (frame.minX - bounds.minX) / bounds.width * target.width,
                               y: target.minY + (frame.minY - bounds.minY) / bounds.height * target.height,
                               width: frame.width, height: frame.height)
            return fit(moved, in: target)
        }
        if self == .center {
            return fit(CGRect(x: bounds.midX - frame.width / 2, y: bounds.midY - frame.height / 2,
                              width: frame.width, height: frame.height), in: bounds)
        }
        if self == .maximize { return bounds }
        let halfWidth = floor(bounds.width / 2), halfHeight = floor(bounds.height / 2)
        let right = [.right, .topRight, .bottomRight].contains(self)
        let bottom = [.bottom, .bottomLeft, .bottomRight].contains(self)
        let fullWidth = self == .top || self == .bottom
        let fullHeight = self == .left || self == .right
        return CGRect(x: right ? bounds.minX + halfWidth : bounds.minX,
                      y: bottom ? bounds.minY + halfHeight : bounds.minY,
                      width: fullWidth ? bounds.width : (right ? bounds.width - halfWidth : halfWidth),
                      height: fullHeight ? bounds.height : (bottom ? bounds.height - halfHeight : halfHeight))
    }
}

protocol WindowShortcutRegistering: AnyObject {
    func start(_ perform: @escaping (WindowShortcutAction) -> Void) -> Bool
    func stop()
}

/// Primitive resources only; preset ordering and rollback belong to registration.
protocol WindowShortcutNativeAccess: AnyObject {
    associatedtype Key
    associatedtype Handler
    func install(_ perform: @escaping (WindowShortcutAction) -> Void) -> (Bool, Handler?)
    func register(_ action: WindowShortcutAction) -> (Bool, Key?)
    func clearCallback()
    func unregister(_ key: Key)
    func remove(_ handler: Handler)
}

/// Registration is all-or-nothing, including resources returned on native failure.
final class WindowShortcutPresetRegistration<Native: WindowShortcutNativeAccess>: WindowShortcutRegistering {
    private let native: Native
    private var keys: [Native.Key] = []
    private var handler: Native.Handler?
    init(native: Native) { self.native = native }
    func start(_ perform: @escaping (WindowShortcutAction) -> Void) -> Bool {
        stop()
        let (installed, handler) = native.install(perform)
        self.handler = handler
        guard installed, handler != nil else { stop(); return false }
        for action in WindowShortcutAction.allCases {
            let (registered, key) = native.register(action)
            if let key { keys.append(key) }
            guard registered, key != nil else { stop(); return false }
        }
        return true
    }
    func stop() {
        native.clearCallback()
        keys.forEach { native.unregister($0) }; keys.removeAll()
        if let handler { native.remove(handler) }; handler = nil
    }
    deinit { stop() }
}

typealias WindowShortcutRegistration = WindowShortcutPresetRegistration<CarbonWindowShortcutAccess>
extension WindowShortcutPresetRegistration where Native == CarbonWindowShortcutAccess {
    convenience init() { self.init(native: CarbonWindowShortcutAccess()) }
}

/// Carbon decoding and C trampoline, without preset or rollback policy.
final class CarbonWindowShortcutAccess: WindowShortcutNativeAccess {
    private var perform: ((WindowShortcutAction) -> Void)?
    func install(_ perform: @escaping (WindowShortcutAction) -> Void) -> (Bool, EventHandlerRef?) {
        self.perform = perform
        var handler: EventHandlerRef?
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x57494E53, let action = WindowShortcutAction(rawValue: identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<CarbonWindowShortcutAccess>.fromOpaque(context).takeUnretainedValue().perform?(action)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return (status == noErr, handler)
    }
    func register(_ action: WindowShortcutAction) -> (Bool, EventHotKeyRef?) {
        var key: EventHotKeyRef?
        let status = RegisterEventHotKey(action.key, action.modifiers,
            EventHotKeyID(signature: 0x57494E53, id: action.rawValue), GetApplicationEventTarget(), 0, &key)
        return (status == noErr, key)
    }
    func clearCallback() { perform = nil }
    func unregister(_ key: EventHotKeyRef) { UnregisterEventHotKey(key) }
    func remove(_ handler: EventHandlerRef) { RemoveEventHandler(handler) }
}
