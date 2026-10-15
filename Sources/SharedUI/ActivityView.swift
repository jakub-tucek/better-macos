import AppKit
import SwiftUI

/// Observed only by the activity window, not by every Dashboard consumer.
final class ActivityPresentation: ObservableObject {
    @Published private(set) var entries: [ActivityEntry]
    let journal: ActivityJournal

    init(journal: ActivityJournal) {
        self.journal = journal; entries = journal.entries
        journal.onChange = { [weak self] in
            guard let self else { return }
            entries = self.journal.entries
        }
    }
}

struct ActivityView: View {
    @ObservedObject var presentation: ActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear activity") { presentation.journal.clear() }
                    .disabled(presentation.entries.isEmpty)
            }
            Text("Recent activity from this app session. Cleared when the app quits. Keeps the latest 300 entries.")
                .font(.callout).foregroundStyle(.secondary)
            ActivityHistory(entries: presentation.entries)
        }.padding(24).frame(minWidth: 540, minHeight: 360)
    }
}

private struct ActivityHistory: NSViewRepresentable {
    let entries: [ActivityEntry]
    func makeNSView(context: Context) -> ActivityHistoryNativeView { ActivityHistoryNativeView() }
    func updateNSView(_ view: ActivityHistoryNativeView, context: Context) { view.update(entries) }
}

private final class ActivityDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct ActivityVisiblePosition {
    let id: ActivityOperationID
    /// Viewport top measured from this row's top; retained across height changes.
    let offset: CGFloat
}

/// Bounded, eagerly measured native rows avoid lazy SwiftUI estimates. Capture
/// geometry BEFORE mutation, lay out synchronously, then restore identity + offset.
/// No delayed dispatch, timers, or SwiftUI scroll-position heuristics participate.
final class ActivityHistoryNativeView: NSView {
    override var isFlipped: Bool { true }
    let scrollView = NSScrollView()
    let latestButton = NSButton(title: "Show latest", target: nil, action: nil)
    private let document = ActivityDocumentView()
    private let empty = NSTextField(labelWithString: "No activity recorded yet this session.")
    private(set) var orderedIDs: [ActivityOperationID] = []
    private var rows: [ActivityOperationID: ActivityNativeRow] = [:]
    private var boundsObserver: NSObjectProtocol?
    private var layingOut = false
    private var hasNewEntries = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        latestButton.target = self; latestButton.action = #selector(showLatest)
        latestButton.bezelStyle = .rounded
        latestButton.setAccessibilityLabel("Show latest activity")
        addSubview(latestButton); addSubview(scrollView)
        empty.textColor = .secondaryLabelColor
        document.addSubview(empty)
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            guard let self, !layingOut else { return }
            updateLatestButton()
        }
        updateLatestButton()
    }

    required init?(coder: NSCoder) { nil }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    var visiblePosition: ActivityVisiblePosition? {
        let top = scrollView.contentView.bounds.minY
        guard let id = orderedIDs.first(where: { (rows[$0]?.frame.maxY ?? 0) > top }) else { return nil }
        return ActivityVisiblePosition(id: id, offset: top - (rows[id]?.frame.minY ?? 0))
    }

    func rowFrame(_ id: ActivityOperationID) -> NSRect? { rows[id]?.frame }
    func detailsButton(_ id: ActivityOperationID) -> NSButton? { rows[id]?.disclosure }

    func update(_ entries: [ActivityEntry]) {
        let anchor = visiblePosition
        let oldOrder = orderedIDs
        let wasAtTop = scrollView.contentView.bounds.minY <= 1
        let nextIDs = entries.map(\.id)
        if !wasAtTop, orderedIDs.first != nextIDs.first { hasNewEntries = true }
        let retained = Set(nextIDs)
        for id in orderedIDs where !retained.contains(id) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for entry in entries {
            if let row = rows[entry.id] { row.update(entry) }
            else {
                let row = ActivityNativeRow(entry: entry)
                row.onToggle = { [weak self] in self?.toggleDetails(entry.id) }
                rows[entry.id] = row; document.addSubview(row)
            }
        }
        orderedIDs = nextIDs
        arrange(anchor: anchor, oldOrder: oldOrder, wasAtTop: wasAtTop)
    }

    override func layout() {
        super.layout()
        guard !layingOut else { return }
        arrange(anchor: visiblePosition, oldOrder: orderedIDs, wasAtTop: scrollView.contentView.bounds.minY <= 1)
    }

    private func toggleDetails(_ id: ActivityOperationID) {
        let anchor = visiblePosition
        let wasAtTop = scrollView.contentView.bounds.minY <= 1
        rows[id]?.toggle()
        arrange(anchor: anchor, oldOrder: orderedIDs, wasAtTop: wasAtTop)
    }

    private func arrange(anchor: ActivityVisiblePosition?, oldOrder: [ActivityOperationID], wasAtTop: Bool) {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        latestButton.frame = NSRect(x: 0, y: 0, width: 170, height: 28)
        scrollView.frame = NSRect(x: 0, y: 32, width: bounds.width, height: max(0, bounds.height - 32))
        let width = max(1, scrollView.contentSize.width)
        var y: CGFloat = 0
        for id in orderedIDs {
            guard let row = rows[id] else { continue }
            let height = row.measuredHeight(width: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            row.arrange(width: width)
            y += height
        }
        empty.isHidden = !orderedIDs.isEmpty
        empty.frame = NSRect(x: 4, y: 4, width: max(0, width - 8), height: 24)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scrollView.contentSize.height))
        var target: CGFloat = 0
        if !wasAtTop, let anchor {
            if let row = rows[anchor.id] {
                // A collapsed/shrunk anchor cannot retain an offset beyond its
                // new bottom. Keep that row, at the nearest remaining offset.
                target = row.frame.minY + min(anchor.offset, max(0, row.frame.height - 1))
            }
            else if let oldIndex = oldOrder.firstIndex(of: anchor.id) {
                // Eviction: prefer the nearest surviving older row, otherwise
                // the nearest surviving newer row, aligned to its top.
                let candidates = Array(oldOrder.dropFirst(oldIndex + 1)) + Array(oldOrder.prefix(oldIndex).reversed())
                if let surviving = candidates.first(where: { rows[$0] != nil }), let row = rows[surviving] { target = row.frame.minY }
            }
        }
        let limit = max(0, document.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, target))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateLatestButton()
    }

    @objc func showLatest() {
        hasNewEntries = false
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateLatestButton()
    }

    private func updateLatestButton() {
        let atTop = scrollView.contentView.bounds.minY <= 1
        if atTop { hasNewEntries = false }
        latestButton.isHidden = atTop
        latestButton.title = hasNewEntries ? "Show latest activity" : "Show latest"
    }
}

private final class ActivityNativeRow: NSView {
    override var isFlipped: Bool { true }
    let disclosure = NSButton(title: "Show details", target: nil, action: nil)
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let divider = NSBox()
    private var expanded = false
    var onToggle: (() -> Void)?

    init(entry: ActivityEntry) {
        super.init(frame: .zero)
        heading.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        heading.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        details.font = .systemFont(ofSize: NSFont.systemFontSize)
        for field in [heading, title, status, details] { field.isSelectable = true; addSubview(field) }
        disclosure.target = self; disclosure.action = #selector(toggleRequested)
        disclosure.bezelStyle = .disclosure
        addSubview(disclosure)
        divider.boxType = .separator; addSubview(divider)
        update(entry)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func toggleRequested() { onToggle?() }
    func toggle() { expanded.toggle(); disclosure.state = expanded ? .on : .off }

    func update(_ entry: ActivityEntry) {
        let time = entry.startedAt.formatted(.dateTime.hour().minute().second())
        let header = "\(time) · \(entry.event.feature) · \(entry.trigger.rawValue)"
        if heading.stringValue != header { heading.stringValue = header }
        heading.setAccessibilityLabel("\(entry.startedAt.formatted(date: .complete, time: .complete)) · \(entry.event.feature) · \(entry.trigger.rawValue)")
        if title.stringValue != entry.event.title { title.stringValue = entry.event.title }
        if status.stringValue != entry.status { status.stringValue = entry.status }
        if details.stringValue != entry.details { details.stringValue = entry.details }
        disclosure.setAccessibilityLabel("Details: \(entry.event.title)")
    }

    private func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)).height ?? 20)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let available = max(1, width - 34)
        let base = height(heading, width: available) + height(title, width: available) + height(status, width: available) + 28
        return base + (expanded ? height(details, width: available) + 8 : 0)
    }

    func arrange(width: CGFloat) {
        let available = max(1, width - 34)
        var y: CGFloat = 8
        for field in [heading, title, status] {
            let size = height(field, width: available)
            field.frame = NSRect(x: 26, y: y, width: available, height: size); y += size + 4
        }
        details.isHidden = !expanded
        if expanded { details.frame = NSRect(x: 26, y: y + 4, width: available, height: height(details, width: available)) }
        disclosure.frame = NSRect(x: 2, y: 8, width: 20, height: 20)
        divider.frame = NSRect(x: 4, y: bounds.height - 1, width: max(0, width - 8), height: 1)
    }
}
