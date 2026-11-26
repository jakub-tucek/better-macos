import AppKit
import Carbon.HIToolbox

struct ShotHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var label: String

    static let defaultArea = ShotHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘3")
    static let defaultReopen = ShotHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧3")
    static let defaultFullscreen = ShotHotKey(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧1")

    /// Builds a shortcut from a key press; nil without a modifier other than Shift.
    static func from(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> ShotHotKey? {
        var mods: UInt32 = 0
        var label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        guard mods != 0, mods != UInt32(shiftKey) else { return nil }
        return ShotHotKey(keyCode: UInt32(keyCode), modifiers: mods, label: label + (characters ?? "?").uppercased())
    }
}

/// The three global shortcuts, keyed by their stored names.
enum ShotHotKeyAction: UInt32, CaseIterable {
    case area = 1, full, reopen
    var name: String { ["area", "full", "reopen"][Int(rawValue) - 1] }
    var title: String { ["Capture area", "Capture screen", "Reopen last capture"][Int(rawValue) - 1] }
    var fallback: ShotHotKey { [.defaultArea, .defaultFullscreen, .defaultReopen][Int(rawValue) - 1] }
}

/// Screenshot choices, namespaced under `screenshots.` in the host's preferences.
enum ShotPreferences {
    /// The owner points this at the host's (or a test's) preferences.
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    private static func key(_ name: String) -> String { "screenshots.\(name)" }

    static var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: key("saveFolder")) { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { defaults.set(newValue.path, forKey: key("saveFolder")) }
    }

    static var closeAfterCopy: Bool {
        get { defaults.object(forKey: key("closeAfterCopy")) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key("closeAfterCopy")) }
    }

    static var showThumbnail: Bool {
        get { defaults.object(forKey: key("showThumbnail")) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key("showThumbnail")) }
    }

    static var beautifyStyle: ShotBeautifyStyle {
        get {
            ShotBeautifyStyle(background: defaults.object(forKey: key("beautifyBackground")) as? Int ?? 1,
                              padding: defaults.object(forKey: key("beautifyPadding")) as? CGFloat ?? 48)
        }
        set {
            defaults.set(newValue.background, forKey: key("beautifyBackground"))
            defaults.set(newValue.padding, forKey: key("beautifyPadding"))
        }
    }

    static var copyOnCapture: Bool {
        get { defaults.bool(forKey: key("copyOnCapture")) }
        set { defaults.set(newValue, forKey: key("copyOnCapture")) }
    }

    static func hotKey(_ action: ShotHotKeyAction) -> ShotHotKey {
        guard let dict = defaults.dictionary(forKey: key("hotKey.\(action.name)")),
              let code = dict["code"] as? Int, let mods = dict["mods"] as? Int, let label = dict["label"] as? String
        else { return action.fallback }
        return ShotHotKey(keyCode: UInt32(code), modifiers: UInt32(mods), label: label)
    }

    static func setHotKey(_ action: ShotHotKeyAction, _ value: ShotHotKey) {
        defaults.set(["code": Int(value.keyCode), "mods": Int(value.modifiers), "label": value.label], forKey: key("hotKey.\(action.name)"))
    }

    static func timestampedName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
    }
}

/// Global shortcut registration. Tests inject a fake; the default goes through Carbon.
protocol ShotHotKeyBinding: AnyObject {
    /// Returns false if the combination could not be registered.
    func register(_ action: ShotHotKeyAction, key: ShotHotKey, handler: @escaping () -> Void) -> Bool
    func unregisterAll()
}

/// Accepts every shortcut without touching the system.
final class InertShotHotKeys: ShotHotKeyBinding {
    func register(_ action: ShotHotKeyAction, key: ShotHotKey, handler: @escaping () -> Void) -> Bool { true }
    func unregisterAll() {}
}

/// Carbon hot keys need no Accessibility permission. The handler claims only this feature's
/// signature, so Windows and Clipboard shortcuts on the same application target still arrive.
final class CarbonShotHotKeys: ShotHotKeyBinding {
    static let signature: OSType = 0x5348_5454 // 'SHTT'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    func register(_ action: ShotHotKeyAction, key: ShotHotKey, handler: @escaping () -> Void) -> Bool {
        guard installIfNeeded() else { return false }
        if let old = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(old) }
        handlers[action.rawValue] = handler
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[action.rawValue] = ref
        return true
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        handlers = [:]
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    func handle(_ id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature, let handler = handlers[id.id] else { return false }
        handler()
        return true
    }

    private func installIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  Unmanaged<CarbonShotHotKeys>.fromOpaque(context).takeUnretainedValue().handle(id) else {
                return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        return status == noErr
    }

    deinit { unregisterAll() }
}

/// Recent captures on disk: `<stamp>.png` holds the screenshot, and an optional `<stamp>.json` beside it holds the
/// annotations, crop and beautify settings. That keeps closed documents reopenable without keeping them in memory.
enum ShotRecentCaptures {
    private static let limit = 20
    private static let queue = DispatchQueue(label: "better-macos.screenshots.recent", qos: .utility)
    /// Tests point this at a scratch folder.
    nonisolated(unsafe) static var folderOverride: URL?

    static var folder: URL {
        folderOverride ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Better macOS/Screenshots/Recent", isDirectory: true)
    }

    private struct Record: Codable {
        struct Item: Codable {
            var kind: ShotAnnotation.Kind
            var start, end: CGPoint
            var points: [CGPoint]
            var color: ShotRGBA
            var width: CGFloat
            var text: String
            var fontSize: CGFloat
            var number: Int
            var imagePNG: Data?
        }
        var crop: CGRect
        var scale: CGFloat
        var beautify: ShotBeautifyStyle?
        var annotations: [Item]
    }

    private static func sidecar(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("json") }

    static func hasEdits(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: sidecar(for: url).path) }

    static func newURL() -> URL {
        var url = folder.appendingPathComponent(ShotPreferences.timestampedName())
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ShotPreferences.timestampedName().replacingOccurrences(of: ".png", with: " \(attempt).png"))
            attempt += 1
        }
        return url
    }

    /// Stores a new capture and returns where it will be.
    @discardableResult
    static func add(_ capture: ShotCapturedImage) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = newURL()
        FileManager.default.createFile(atPath: url.path, contents: nil) // Reserves the name
        let image = capture.image, scale = capture.scale
        queue.async {
            guard let data = ShotExporter.encode(image, scale: scale) else { return }
            try? data.write(to: url, options: .atomic)
            for old in list().dropFirst(limit) {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: sidecar(for: old))
            }
        }
        return url
    }

    /// Saves a document's edits. The screenshot is only rewritten if it changed, as a collage does.
    static func save(_ state: ShotDocumentState, to url: URL, writeBase: Bool) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queue.async {
            if writeBase, let data = ShotExporter.encode(state.base, scale: state.scale) {
                try? data.write(to: url, options: .atomic)
            }
            let items = state.annotations.map { a in
                Record.Item(kind: a.kind, start: a.start, end: a.end, points: a.points, color: a.color, width: a.width,
                            text: a.text, fontSize: a.fontSize, number: a.number,
                            imagePNG: a.image.flatMap { ShotExporter.encode($0) })
            }
            let record = Record(crop: state.crop, scale: state.scale, beautify: state.beautify, annotations: items)
            if let json = try? JSONEncoder().encode(record) { try? json.write(to: sidecar(for: url), options: .atomic) }
        }
    }

    /// Blocks until pending writes land, so a document can be read back right after closing.
    static func flush() { queue.sync {} }

    /// Loads a stored document, or any plain image, with its edits if it has them.
    static func load(_ url: URL) -> ShotDocumentState? {
        flush()
        guard let loaded = ShotExporter.load(url: url) else { return nil }
        var state = ShotDocumentState(base: loaded.image, scale: loaded.scale)
        guard let data = try? Data(contentsOf: sidecar(for: url)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return state }
        state.crop = record.crop
        state.scale = record.scale
        state.beautify = record.beautify
        state.annotations = record.annotations.map { item in
            var a = ShotAnnotation(kind: item.kind, start: item.start, end: item.end, color: item.color, width: item.width)
            a.points = item.points
            a.text = item.text
            a.fontSize = item.fontSize
            a.number = item.number
            a.image = item.imagePNG.flatMap { ShotExporter.load(data: $0)?.image }
            return a
        }
        return state
    }

    /// Newest first.
    static func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return files.filter { $0.pathExtension == "png" }.sorted { created($0) > created($1) }
    }
}
