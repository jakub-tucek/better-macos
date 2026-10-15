import AppKit
import Carbon
import ImageIO

enum ClipboardPresentation {
    static func preview(_ entry: ClipboardEntry) -> String {
        guard let text = entry.text else {
            return "PNG image · " + ByteCountFormatter.string(fromByteCount: Int64(entry.image?.count ?? 0), countStyle: .file)
        }
        return String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(240))
    }
    static func rows(_ entries: [ClipboardEntry], query: String) -> [ClipboardEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
        return matches.filter(\.pinned) + matches.filter { !$0.pinned }
    }
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}

/// Only visible rows request a decode. ImageIO downsamples before allocating pixels.
final class ClipboardThumbnails {
    private let cache = NSCache<NSUUID, NSImage>()
    private var failed = Set<UUID>()
    private var known = Set<UUID>()
    private(set) var decodes = 0
    init() { cache.countLimit = 48; cache.totalCostLimit = 48 * 96 * 96 * 4 }
    func image(for entry: ClipboardEntry) -> NSImage? {
        guard let data = entry.image else { return nil }
        known.insert(entry.id)
        if let image = cache.object(forKey: entry.id as NSUUID) { return image }
        guard !failed.contains(entry.id) else { return nil }
        decodes += 1
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { failed.insert(entry.id); return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: entry.id as NSUUID, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
    func retain(_ ids: Set<UUID>) {
        for id in known.subtracting(ids) { cache.removeObject(forKey: id as NSUUID); failed.remove(id) }
        known.formIntersection(ids)
    }
    func clear() { cache.removeAllObjects(); failed.removeAll(); known.removeAll() }
}

private final class ClipboardRowView: NSTableCellView {
    init(entry: ClipboardEntry, thumbnail: NSImage?) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = thumbnail ?? NSImage(systemSymbolName: entry.text == nil ? "photo" : "doc.text", accessibilityDescription: entry.text == nil ? "PNG image" : "Text")
        icon.imageScaling = .scaleProportionallyUpOrDown
        if thumbnail == nil { icon.contentTintColor = .secondaryLabelColor }
        let preview = NSTextField(labelWithString: ClipboardPresentation.preview(entry))
        preview.font = .systemFont(ofSize: 13, weight: .medium)
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 1
        let metadata = NSTextField(labelWithString: (entry.pinned ? "Pinned · " : "") + ClipboardPresentation.age(entry.created) + " · " + entry.source)
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [preview, metadata])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        let pin = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")!)
        pin.contentTintColor = .secondaryLabelColor; pin.isHidden = !entry.pinned
        for view in [icon, text, pin] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: pin.leadingAnchor, constant: -8),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 12), pin.heightAnchor.constraint(equalToConstant: 12),
            preview.widthAnchor.constraint(equalTo: text.widthAnchor), metadata.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel((entry.text == nil ? "Image, " : "Text, ") + preview.stringValue + ", " + metadata.stringValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SystemClipboard: ClipboardAccess {
    private var board: NSPasteboard { .general }
    var changeCount: Int { board.changeCount }
    var markedPrivate: Bool {
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        return (board.types ?? []).contains { blocked.contains($0.rawValue) }
    }
    func text() -> String? { board.string(forType: .string) }
    func image() -> Data? { board.data(forType: .png) }
    func write(_ entry: ClipboardEntry) -> Bool {
        board.clearContents()
        if let text = entry.text { return board.setString(text, forType: .string) }
        if let image = entry.image { return board.setData(image, forType: .png) }
        return false
    }
}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

private final class ClipboardPanelContent: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class ClipboardTable: NSTableView {
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onCopy() }
        else if event.keyCode == 53 { onClose() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return super.menu(for: event)
    }
}

final class ClipboardModule: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let history: ClipboardHistory
    private let defaults: UserDefaults
    private var timer: Timer?
    private var ageTimer: Timer?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: NSPanel?
    let search = NSSearchField()
    let table = ClipboardTable()
    private(set) var rows: [ClipboardEntry] = []
    let thumbnails = ClipboardThumbnails()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear history…", target: nil, action: nil)
    var acceptsActions: () -> Bool = { true }
    var onChange: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    // The switch reflects user intent even while startup recovery is pending.
    var persistence: Bool { history.requestedPersistence }
    var days: Int { history.ageDays }
    var exclusions: String { history.exclusions.sorted().joined(separator: ", ") }

    init(defaults: UserDefaults = .standard, history: ClipboardHistory? = nil) {
        self.defaults = defaults
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fix macOS/Clipboard", isDirectory: true)
        self.history = history ?? ClipboardHistory(board: SystemClipboard(), archive: ClipboardArchive(directory: directory),
                                   source: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
        super.init()
        self.history.onChange = { [weak self] in self?.reload(); self?.onChange() }
        self.history.onError = { [weak self] in self?.onError("Clipboard history could not be saved.") }
    }
    func start() {
        setExclusions(defaults.string(forKey: "clipboard.exclusions") ?? "")
        do {
            try history.configurePersistence(defaults.bool(forKey: "clipboard.persistence"),
                ageDays: defaults.object(forKey: "clipboard.days") as? Int ?? 7, load: true)
        } catch { onError("Clipboard archive could not be loaded or cleaned up.") }
        // Recording is an explicit per-launch opt-in, never restored from defaults.
        resumeMonitoring()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                identifier.signature == 0x434C4950, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<ClipboardModule>.fromOpaque(context).takeUnretainedValue().show()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr || registered != noErr {
            if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
            if let handler { RemoveEventHandler(handler) }; handler = nil
            onError("Clipboard shortcut unavailable; use Open history.")
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        ageTimer?.invalidate(); ageTimer = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        panel?.orderOut(nil); panel = nil; thumbnails.clear()
        history.stop()
    }
    func resumeMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.history.poll() }
    }
    func prepareTermination() -> Bool {
        ageTimer?.invalidate(); ageTimer = nil
        panel?.orderOut(nil)
        timer?.invalidate(); timer = nil
        history.setRecording(false)
        return history.flushPendingStorage()
    }
    func setPersistence(_ enabled: Bool, days: Int? = nil) {
        // Deliberate Disable revokes disk persistence even when cleanup fails.
        // Keep that intent across a later module reload/app restart too.
        if !enabled { defaults.set(false, forKey: "clipboard.persistence") }
        do {
            try history.configurePersistence(enabled, ageDays: days ?? history.ageDays)
            defaults.set(enabled, forKey: "clipboard.persistence")
            defaults.set(history.ageDays, forKey: "clipboard.days")
        } catch { onError("Clipboard archive could not be saved or removed.") }
        onChange()
    }
    func setRetentionDays(_ days: Int) { setPersistence(persistence, days: days) }
    func setExclusions(_ value: String) {
        let values = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        defaults.set(value, forKey: "clipboard.exclusions")
        history.setExclusions(values)
    }
    func clear() {
        guard acceptsActions() else { return }
        do { try history.clear() } catch { onError("Clipboard disk history could not be removed. Retry Clear.") }
    }
    func show() {
        guard acceptsActions() else { return }
        _ = makePanel()
        search.stringValue = ""; reload(resetSelection: true)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(search)
        ageTimer?.invalidate()
        ageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] timer in
            guard let self, self.panel?.isVisible == true else { timer.invalidate(); return }
            self.reload()
        }
        // Nonactivating panel takes keyboard input without activating this app.
    }
    /// Builds the same native surface for isolated fixtures without displaying history.
    @discardableResult func makePanel() -> NSPanel {
        if let panel { return panel }
        let window = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 450),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Clipboard history"
        window.isReleasedWhenClosed = false; window.level = .floating
        let content = ClipboardPanelContent(frame: NSRect(x: 0, y: 0, width: 560, height: 450))
        search.frame = NSRect(x: 16, y: 402, width: 528, height: 28)
        search.placeholderString = "Search clipboard history"; search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search clipboard history")
        content.addSubview(search)
        status.frame = NSRect(x: 18, y: 376, width: 524, height: 18)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        content.addSubview(status)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 50, width: 536, height: 318))
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")); column.width = 516
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 56
        table.style = .fullWidth; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Clipboard entries, pinned first")
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(copySelected)
        table.onCopy = { [weak self] in self?.copySelected() }
        table.onClose = { [weak self] in self?.panel?.orderOut(nil) }
        let menu = NSMenu()
        for definition in [("Copy", #selector(copySelected)), ("Pin", #selector(pinSelected)), ("Delete", #selector(deleteSelected))] {
            let item = NSMenuItem(title: definition.0, action: definition.1, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        table.menu = menu
        scroll.documentView = table; content.addSubview(scroll)
        empty.frame = NSRect(x: 60, y: 170, width: 440, height: 100)
        empty.alignment = .center; empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
        content.addSubview(empty)
        let hint = NSTextField(labelWithString: "↑↓ Select   ↩ Copy   esc Close")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 18, y: 17, width: 255, height: 18); content.addSubview(hint)
        clearButton.frame = NSRect(x: 305, y: 10, width: 145, height: 30)
        clearButton.bezelStyle = .rounded; clearButton.target = self; clearButton.action = #selector(confirmClear)
        copyButton.frame = NSRect(x: 454, y: 10, width: 90, height: 30)
        copyButton.bezelStyle = .rounded; copyButton.target = self; copyButton.action = #selector(copySelected)
        content.addSubview(clearButton); content.addSubview(copyButton)
        window.contentView = content; panel = window; reload(resetSelection: true)
        return window
    }
    private func reload(resetSelection: Bool = false) {
        let previous = selected
        let query = search.stringValue
        let currentIDs = Set(history.entries.map(\.id))
        thumbnails.retain(currentIDs)
        rows = ClipboardPresentation.rows(history.entries, query: query)
        table.reloadData()
        if let index = ClipboardSelection.index(previous: previous, entries: rows, reset: resetSelection) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            // An expired/deleted target must not silently redirect the next action.
            table.deselectAll(nil)
        }
        updateControls()
    }
    private func updateControls() {
        let allowed = acceptsActions()
        copyButton.isEnabled = allowed && selected != nil
        clearButton.isEnabled = allowed && (!history.entries.isEmpty || history.storagePending)
        search.isEnabled = allowed
        status.stringValue = "\(rows.count) of \(history.entries.count) entries · " + (history.recording ? "Recording" : "Recording paused") + (history.storagePending ? " · Storage needs attention" : "")
        empty.isHidden = !rows.isEmpty
        if !allowed { empty.stringValue = "Clipboard history is unavailable while the app is shutting down." }
        else if !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            empty.stringValue = "No matching entries\nTry another search or clear the search field."
        } else if history.recording {
            empty.stringValue = "No clipboard history yet\nNew text and PNG copies will appear here."
        } else {
            empty.stringValue = "Recording is paused\nStart recording explicitly from the Clipboard widget or Settings."
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        return ClipboardRowView(entry: rows[row], thumbnail: thumbnails.image(for: rows[row]))
    }
    func controlTextDidChange(_ obj: Notification) { reload(resetSelection: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): copySelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): panel?.orderOut(nil); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = table.selectedRow < 0 ? (delta > 0 ? 0 : rows.count - 1) : max(0, min(rows.count - 1, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row); return true
        default: return false
        }
    }
    private var selected: UUID? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil }
    @objc private func copySelected() {
        guard acceptsActions() else { updateControls(); return }
        if let selected, history.copy(selected) { panel?.orderOut(nil) }
    }
    @objc private func pinSelected() { if acceptsActions(), let selected { history.pin(selected) } }
    @objc private func deleteSelected() { if acceptsActions(), let selected { history.delete(selected) } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(pinSelected) {
            menuItem.title = rows.first(where: { $0.id == selected })?.pinned == true ? "Unpin" : "Pin"
        }
        return acceptsActions() && selected != nil
    }
    @objc private func confirmClear() {
        guard acceptsActions(), let panel else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes all entries, including pins, from memory and saved history. Your current clipboard is not changed."
        alert.addButton(withTitle: "Clear history"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.clear() }
        }
    }
}
