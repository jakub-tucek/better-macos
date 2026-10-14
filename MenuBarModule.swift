import AppKit

/// Owns only these two global preferences, including their original absence.
/// A durable snapshot precedes every write; failed restoration remains retryable.
final class MenuBarSpacing {
    static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    private let defaults: UserDefaults
    private let read: (String) -> Any?
    private let write: (String, Any?) throws -> Void
    var enabled: Bool { defaults.bool(forKey: "menuBar.compact") }
    var recoveryRequired: Bool { defaults.bool(forKey: "menuBar.spacingPending") }
    var needsApply: Bool { enabled && defaults.data(forKey: "menuBar.spacingOriginals") == nil }

    init(defaults: UserDefaults = .standard,
         read: @escaping (String) -> Any? = {
             CFPreferencesCopyValue($0 as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
         }, write: @escaping (String, Any?) throws -> Void = { key, value in
             CFPreferencesSetValue(key as CFString, value as CFPropertyList?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
             guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                 throw ToggleError(message: "Could not save menu-bar spacing.")
             }
         }) {
        self.defaults = defaults
        self.read = read
        self.write = write
    }

    func setEnabled(_ enabled: Bool) throws {
        if recoveryRequired { try restore() }
        if !enabled { try restore(); return }
        if defaults.data(forKey: "menuBar.spacingOriginals") == nil {
            let snapshot = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, read($0).map { ["value": $0] } ?? [:]) })
            defaults.set(try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0), forKey: "menuBar.spacingOriginals")
        }
        defaults.set(true, forKey: "menuBar.spacingPending")
        guard defaults.synchronize() else { throw ToggleError(message: "Could not back up menu-bar spacing.") }
        do {
            for key in Self.keys { try write(key, 4) }
        } catch {
            // Keep the snapshot and pending marker if rollback also fails.
            try restore()
            throw error
        }
        defaults.set(true, forKey: "menuBar.compact")
        defaults.set(false, forKey: "menuBar.spacingPending")
        defaults.synchronize()
    }

    func restore(preserveChoice: Bool = false) throws {
        if let data = defaults.data(forKey: "menuBar.spacingOriginals") {
            guard let snapshot = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
                  Self.keys.allSatisfy({ snapshot[$0] != nil }) else {
                throw ToggleError(message: "The original menu-bar spacing could not be read.")
            }
            defaults.set(true, forKey: "menuBar.spacingPending")
            guard defaults.synchronize() else { throw ToggleError(message: "Could not record spacing restoration.") }
            for key in Self.keys { try write(key, snapshot[key]?["value"]) }
        }
        if !preserveChoice { defaults.set(false, forKey: "menuBar.compact") }
        defaults.set(false, forKey: "menuBar.spacingPending")
        defaults.removeObject(forKey: "menuBar.spacingOriginals")
        defaults.synchronize()
    }
}

/// AppKit status items provide a user-positioned boundary. Expanding the boundary
/// consumes the available space to its left; no other app's items are modified.
final class MenuBarModule: NSObject {
    private var control: NSStatusItem?
    private var divider: NSStatusItem?
    private let defaults: UserDefaults
    private(set) var hidden = false
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var enabled: Bool { defaults.bool(forKey: "menuBar.hiding") }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }

    func start() { if enabled { createItems() } }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "menuBar.hiding")
        if enabled { createItems() } else { stop() }
        onChange?()
    }

    private func createItems() {
        guard control == nil else { return }
        let control = NSStatusBar.system.statusItem(withLength: 24)
        control.autosaveName = "FixMacOS.MenuBar.Toggle"
        control.button?.target = self
        control.button?.action = #selector(toggle)
        control.button?.setAccessibilityLabel("Show or hide extra menu-bar icons")
        self.control = control
        let divider = NSStatusBar.system.statusItem(withLength: 20)
        divider.autosaveName = "FixMacOS.MenuBar.Divider"
        divider.button?.title = "│"
        divider.button?.alignment = .right
        divider.button?.toolTip = "Command-drag extra icons to the left of this divider"
        self.divider = divider
        updateButton()
    }

    @objc func toggle() {
        guard let divider, let control else { return }
        if !hidden {
            guard let boundary = divider.button?.window?.frame, let toggle = control.button?.window?.frame,
                  boundary.maxX <= toggle.minX + 1, abs(boundary.midY - toggle.midY) < 2 else {
                onError?(ToggleError(message: "Hold ⌘ and drag the divider to the left of the menu-bar chevron, then try again."))
                return
            }
        }
        hidden.toggle()
        divider.length = hidden ? max(10000, NSScreen.screens.map { $0.frame.width }.max() ?? 0) : 20
        updateButton()
        onChange?()
    }

    private func updateButton() {
        control?.button?.image = NSImage(systemSymbolName: hidden ? "chevron.left" : "chevron.right", accessibilityDescription: hidden ? "Show extra icons" : "Hide extra icons")
        control?.button?.toolTip = hidden ? "Show extra icons" : "Hide extra icons"
    }

    func stop() {
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        if let control { NSStatusBar.system.removeStatusItem(control) }
        divider = nil
        control = nil
        hidden = false
    }
}
