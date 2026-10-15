import AppKit
import SwiftUI

enum SettingsGroup: String, CaseIterable, Identifiable {
    case general = "General", quickActions = "Quick actions", displays = "Displays"
    case sound = "Sound & connections", input = "Input", system = "System", clipboard = "Clipboard"
    var id: String { rawValue }
    var modules: [AppModule] {
        switch self {
        case .general, .quickActions: return []
        case .displays: return [.monitors, .arrangement, .windows]
        case .sound: return [.audio, .bluetooth]
        case .input: return [.quitGuard, .mouse]
        case .system: return [.spaces, .menuBar, .keepAwake]
        case .clipboard: return [.clipboard]
        }
    }
    static func forFeature(_ feature: DashboardTab) -> SettingsGroup {
        allCases.first { $0.modules.contains { $0.dashboardFeature == feature } } ?? .general
    }
}

enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case keepAwake, audio, displays, windows, clipboard, bluetooth
    var id: String { rawValue }
    var feature: DashboardTab {
        switch self {
        case .keepAwake: return .keepAwake
        case .audio: return .audio
        case .displays: return .monitors
        case .windows: return .windows
        case .clipboard: return .clipboard
        case .bluetooth: return .bluetooth
        }
    }
    var title: String { self == .displays ? "Displays" : self == .windows ? "Window layouts" : feature.rawValue }
    var detail: String {
        switch self {
        case .keepAwake: return "Start or stop an idle-sleep prevention session."
        case .audio: return "Switch output and microphone without opening Settings."
        case .displays: return "Switch monitors, arrange screens, and restore windows."
        case .windows: return "Restore named layouts on compatible displays."
        case .clipboard: return "Open private history; copied content is never previewed here."
        case .bluetooth: return "Connect chosen devices and see reconnect status."
        }
    }
    var module: AppModule {
        switch self {
        case .keepAwake: return .keepAwake
        case .audio: return .audio
        case .displays: return .monitors
        case .windows: return .windows
        case .clipboard: return .clipboard
        case .bluetooth: return .bluetooth
        }
    }
}

enum UILaunchRoute: Equatable {
    case home, settings(SettingsGroup), widget(WidgetKind)
    static func launch(arguments: [String]) -> UILaunchRoute {
        let navigation = DashboardNavigation.launch(arguments: arguments)
        guard let feature = navigation.feature else { return navigation.isSetup ? .settings(.general) : .home }
        if !navigation.isSetup, let widget = WidgetKind.allCases.first(where: { $0.feature == feature }) { return .widget(widget) }
        return .settings(SettingsGroup.forFeature(feature))
    }
}

struct WidgetEntry: Codable, Equatable, Identifiable {
    // Preserve unknown kinds during round trips rather than erasing newer layouts.
    var kind: String
    var expanded = false
    var windowLayoutID = ""
    var showWindows = true
    var id: String { kind }
    var known: WidgetKind? { WidgetKind(rawValue: kind) }
    init(_ kind: WidgetKind, expanded: Bool = false) { self.kind = kind.rawValue; self.expanded = expanded }
    private enum CodingKeys: String, CodingKey { case kind, expanded, windowLayoutID, showWindows }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        expanded = try values.decodeIfPresent(Bool.self, forKey: .expanded) ?? false
        windowLayoutID = try values.decodeIfPresent(String.self, forKey: .windowLayoutID) ?? ""
        showWindows = try values.decodeIfPresent(Bool.self, forKey: .showWindows) ?? true
    }
}

struct WidgetLayout: Codable, Equatable {
    var version = 1
    var entries: [WidgetEntry] = []
    static func suggested(for modules: Set<AppModule>) -> WidgetLayout {
        WidgetLayout(entries: [WidgetKind.keepAwake, .audio, .displays, .windows, .clipboard, .bluetooth]
            .filter { modules.contains($0.module) }.map { WidgetEntry($0) })
    }
    mutating func normalize() {
        var seen = Set<String>()
        entries = entries.filter { !$0.kind.isEmpty && seen.insert($0.kind).inserted }
    }
    mutating func add(_ kind: WidgetKind) {
        guard !entries.contains(where: { $0.kind == kind.rawValue }) else { return }
        entries.append(WidgetEntry(kind))
    }
    mutating func move(_ id: String, by distance: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + distance) else { return }
        entries.swapAt(index, index + distance)
    }
    mutating func move(_ id: String, before target: String) {
        guard id != target, let index = entries.firstIndex(where: { $0.id == id }),
              entries.contains(where: { $0.id == target }) else { return }
        let entry = entries.remove(at: index)
        if let destination = entries.firstIndex(where: { $0.id == target }) { entries.insert(entry, at: destination) }
    }
}

/// Production button actions share this session with the host. A rejected Done
/// keeps the draft (for example after a canceled asynchronous quit).
final class WidgetEditingSession: ObservableObject {
    @Published var draft: WidgetLayout?
    func begin(_ layout: WidgetLayout) { if draft == nil { draft = layout } }
    func cancel() { draft = nil }
    @discardableResult func done(save: (WidgetLayout) -> Bool) -> Bool {
        guard let draft, save(draft) else { return false }
        self.draft = nil; return true
    }
}

final class UISettingsStore {
    private let defaults: UserDefaults
    static let layoutKey = "ui.widgets.v1"
    static let completionKey = "ui.setup.version"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    // Inspect all established preferences, not just the newly introduced completion key.
    var isExistingInstall: Bool {
        defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix("modules.") || $0.hasPrefix("clipboard.") || $0.hasPrefix("audio.") ||
            $0.hasPrefix("keepAwake.") || $0.hasPrefix("mouse.") || $0.hasPrefix("bluetooth.") ||
            $0.hasPrefix("animations.") || $0.hasPrefix("menuBar.") || $0.hasPrefix("quitGuard.") ||
            $0.hasPrefix("windows.") || $0.hasPrefix("spaces.") || $0.hasPrefix("safety.") || $0.hasPrefix("updates.") ||
            ["displayRecords", "pendingArrangement", "arrangement.matchEdges", "monitors.confirmDisable", "savedLayout", "targetUUID", "disabledByApp", "transitionSpeed"].contains($0)
        } || defaults.object(forKey: Self.layoutKey) != nil || defaults.integer(forKey: Self.completionKey) > 0
    }
    func loadLayout(modules: Set<AppModule>, existing: Bool) -> WidgetLayout {
        if let data = defaults.data(forKey: Self.layoutKey), var value = try? JSONDecoder().decode(WidgetLayout.self, from: data) {
            value.normalize(); return value
        }
        let value = existing ? WidgetLayout.suggested(for: modules) : WidgetLayout()
        save(value); return value
    }
    func save(_ layout: WidgetLayout) {
        var value = layout; value.normalize()
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.layoutKey) }
    }
    func complete() { defaults.set(1, forKey: Self.completionKey) }
}

struct SafetyAlerts: View {
    @ObservedObject var model: DashboardModel
    var showAwakeSession = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.watchdogReady {
                Text(model.watchdogStatus).foregroundStyle(.orange)
                Button("Recovery diagnostics") { model.onOpenSettings(.general) }
            }
            if let message = model.errorMessage { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            if model.animationRecoveryRequired { Button("Restore original animations", action: model.onRestoreAnimations).disabled(model.animationsBusy) }
            if model.menuBarRecoveryRequired { Button("Restore menu-bar spacing", action: model.onRestoreMenuBarSpacing) }
            if model.mouseRecoveryRequired { Button("Retry mouse restoration", action: model.onRestoreMouse) }
            if model.clipboardStoragePending {
                Text("Clipboard disk cleanup/save pending. Old disk entries may remain; keep the feature enabled.").foregroundStyle(.orange)
                Button("Clipboard storage settings") { model.onOpenSettings(.clipboard) }
            }
            if model.disabledMonitorCount > 0 || model.pendingArrangement || !model.countdowns.isEmpty {
                ForEach(model.countdowns.keys.sorted(), id: \.self) { id in
                    Text("Restoring \(id == "layout" ? "layout" : model.monitors.first { $0.uuid == id }?.name ?? "display") in \(model.countdowns[id] ?? 0)s").foregroundStyle(.orange)
                    Button(id == "layout" ? "Keep layout" : "Keep disabled") {
                        if id == "layout" { model.onKeepArrangement() } else { model.onKeepDisabled(id) }
                    }.disabled(model.monitorBusy || (model.countdowns[id] ?? 0) <= 0)
                }
                Button("Restore displays now", action: model.onRestoreAll).disabled(model.monitorBusy || model.displaySettling)
            }
            if (showAwakeSession && model.keepAwakeCanStop) || model.keepAwakeProtectionFailed {
                HStack {
                    Text("Keep awake: \(AwakeSessionActions(model: model).status)").monospacedDigit()
                    Spacer()
                    Button("Stop", action: model.onKeepAwakeStop)
                }
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WidgetEditor: View {
    @Binding var layout: WidgetLayout
    @ObservedObject var model: DashboardModel
    var allowSettings = true
    var layouts: [WindowLayout]? = nil
    @StoredState private var gallery = false
    private var availableLayouts: [WindowLayout] { layouts ?? model.windowPositions?.layouts ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Removing a widget only changes this layout, never the feature, session, or history.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(layout.entries.enumerated()), id: \.element.id) { index, entry in
                DashboardCard {
                    HStack {
                        Image(systemName: "line.3.horizontal").accessibilityLabel("Drag to reorder")
                        Text(entry.known?.title ?? "Unavailable widget: \(entry.kind)").font(.headline)
                        Spacer()
                        Button { layout.move(entry.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).accessibilityLabel("Move \(entry.known?.title ?? entry.kind) up")
                        Button { layout.move(entry.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == layout.entries.count - 1).accessibilityLabel("Move \(entry.known?.title ?? entry.kind) down")
                        Button("Remove") { layout.entries.removeAll { $0.id == entry.id } }
                    }
                    if let kind = entry.known {
                        Text(kind.detail).font(.caption)
                        Toggle("Expanded", isOn: Binding(get: { entry.expanded }, set: { layout.entries[index].expanded = $0 }))
                        if kind == .displays { Toggle("Include window restore", isOn: Binding(get: { entry.showWindows }, set: { layout.entries[index].showWindows = $0 })) }
                        if kind == .windows || kind == .displays {
                            Picker("Default window layout", selection: Binding(get: { entry.windowLayoutID }, set: { layout.entries[index].windowLayoutID = $0 })) {
                                Text("Choose in widget").tag("")
                                ForEach(availableLayouts) { Text($0.name).tag($0.id) }
                                if !entry.windowLayoutID.isEmpty && !availableLayouts.contains(where: { $0.id == entry.windowLayoutID }) {
                                    Text("Unavailable saved layout").tag(entry.windowLayoutID)
                                }
                            }
                        }
                        if allowSettings { Button("Settings…") { model.onOpenSettings(SettingsGroup.forFeature(kind.feature)) } }
                    }
                }
                .onDrag { NSItemProvider(object: entry.id as NSString) }
                .dropDestination(for: String.self) { values, _ in
                    guard let id = values.first else { return false }; layout.move(id, before: entry.id); return true
                }
            }
            HStack {
                Button("Add widget") { gallery.toggle() }
                Button("Restore suggested") { layout = .suggested(for: model.enabledModules) }
            }
            if gallery || layout.entries.isEmpty {
                ForEach(WidgetKind.allCases.filter { kind in !layout.entries.contains { $0.kind == kind.rawValue } }) { kind in
                    DashboardCard {
                        Label(kind.title, systemImage: kind.feature.symbol).font(.headline)
                        Text(kind.detail).font(.caption)
                        Text(preview(kind)).font(.caption).foregroundStyle(.secondary)
                        Button("Add \(kind.title)") { layout.add(kind) }
                    }
                }
            }
        }
    }
    private func preview(_ kind: WidgetKind) -> String {
        switch kind {
        case .keepAwake: return "30 min · Start / Stop"
        case .audio: return "Output → device picker · Expanded adds microphone"
        case .displays: return "Display name · On / Off"
        case .windows: return "Layout name · Restore"
        case .clipboard: return "Open history · Recording paused"
        case .bluetooth: return "Chosen device · Connect / Disconnect"
        }
    }
}

/// Measure natural document height at the popup's constrained width, never derive
/// it from viewport height. Only the viewport is capped; long content stays intact.
struct PopupSizing: Equatable {
    static let width: CGFloat = 390
    let height: CGFloat
    let viewportHeight: CGFloat
    init(contentHeight: CGFloat, chromeHeight: CGFloat, availableHeight: CGFloat) {
        let limit = max(1, min(650, availableHeight.isFinite ? availableHeight : 650))
        let chrome = max(0, chromeHeight.isFinite ? chromeHeight : 0)
        let content = max(0, contentHeight.isFinite ? contentHeight : 0)
        height = min(limit, max(160, ceil(content + chrome)))
        viewportHeight = max(0, height - chrome)
    }
}

struct QuickActionsView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var editor: WidgetEditingSession
    @StoredState private var contentHeight: CGFloat = 0
    @StoredState private var headerHeight: CGFloat = 40
    @StoredState private var footerHeight: CGFloat = 38
    private let onResize: (NSSize) -> Void
    init(model: DashboardModel, onResize: @escaping (NSSize) -> Void = { _ in }) {
        self.model = model; self.editor = model.popupWidgetEditor; self.onResize = onResize
    }
    private var sizing: PopupSizing {
        PopupSizing(contentHeight: contentHeight, chromeHeight: headerHeight + footerHeight + 2, availableHeight: model.popupHeight)
    }
    private var entries: [WidgetEntry] {
        var entries = model.widgetLayout.entries.filter { $0.known != nil }
        if let launch = model.launchWidget {
            var opened = entries.first { $0.known == launch } ?? WidgetEntry(launch)
            opened.expanded = true
            entries.removeAll { $0.known == launch }
            entries.insert(opened, at: 0)
        }
        return entries
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fix macOS").font(.headline)
                Spacer()
                if editor.draft != nil {
                    Button("Cancel", action: editor.cancel)
                    Button("Done") { editor.done(save: model.onSaveWidgets) }
                } else { Button("Edit") { editor.begin(model.widgetLayout) } }
                Button { model.onOpenSettings(nil) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            Divider().frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SafetyAlerts(model: model, showAwakeSession: editor.draft != nil || !entries.contains { $0.known == .keepAwake && model.enabledModules.contains(.keepAwake) })
                        .padding(.horizontal, 14)
                    if editor.draft != nil {
                        WidgetEditor(layout: Binding(get: { editor.draft ?? model.widgetLayout }, set: { editor.draft = $0 }), model: model)
                            .padding(14)
                    } else {
                        if model.launchWidget != nil {
                            Button("Dismiss temporary launch action") { model.launchWidget = nil }.font(.caption)
                        }
                        ForEach(entries) { entry in
                            QuickWidget(model: model, entry: entry)
                            Divider().padding(.leading, 14)
                        }
                        if entries.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your quick actions, your choice.").font(.headline)
                                Button("Add quick actions") { editor.begin(model.widgetLayout) }
                                Button("Run setup", action: model.onRunSetup)
                            }.padding(14)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: sizing.viewportHeight)
            Divider().frame(height: 1)
            HStack { Spacer(); Button("Quit", action: model.onQuit).disabled(model.monitorBusy) }.padding(.horizontal, 14).padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
        }.frame(width: PopupSizing.width, height: sizing.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .controlSize(.small)
            .onExitCommand(perform: model.onClose)
            .onChange(of: sizing.height, initial: true) { _, height in
                onResize(NSSize(width: PopupSizing.width, height: height))
            }
    }
}

/// The owner bounds sessions at 24 hours. Reject invalid/out-of-domain values
/// before integer conversion; never show zero while any positive time remains.
enum AwakeCountdown {
    static func text(remaining: TimeInterval) -> String? {
        guard remaining.isFinite, remaining > 0, remaining <= 86400 else { return nil }
        let seconds = Int(ceil(remaining))
        if seconds >= 3600 {
            // Round up minutes at hour scale, including the final partial minute.
            let minutes = (seconds + 59) / 60
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
        }
        if seconds >= 60 {
            return String(format: "%d min %02d sec left", seconds / 60, seconds % 60)
        }
        return "\(seconds) sec left"
    }
}

/// The popup and its isolated tests use the same action seam. Feature callbacks
/// remain responsible for host admission, assertion ownership and recovery.
struct AwakeSessionActions {
    let model: DashboardModel
    static let presets = [15, 30, 45, 60, 120]
    var recentDuration: Int? {
        let minutes = model.keepAwakeMinutes
        return KeepAwakeModule.durationRange.contains(minutes) && !Self.presets.contains(minutes) ? minutes : nil
    }
    var status: String {
        if model.keepAwakeProtectionFailed { return "Protection needs retry" }
        if !model.keepAwakeActive {
            return model.keepAwakeRemaining > 0 ? "Session pending" : "Inactive"
        }
        if let countdown = AwakeCountdown.text(remaining: model.keepAwakeRemaining) { return countdown }
        return model.keepAwakeAppNames.isEmpty ? "Ending session" : "Active · app rules"
    }
    func start(minutes: Int) {
        guard model.enabledModules.contains(.keepAwake), !model.stoppingModules.contains(.keepAwake),
              KeepAwakeModule.durationRange.contains(minutes) else { return }
        model.onKeepAwakeMinutesChanged(minutes)
        model.onKeepAwakeStart()
    }
    func retry() {
        guard model.enabledModules.contains(.keepAwake), !model.stoppingModules.contains(.keepAwake) else { return }
        model.onKeepAwakeRetry()
    }
}

/// Keep raw edits separate from the persisted choice: invalid text never starts
/// the previously selected duration or changes an existing session.
struct AwakeDurationDraft {
    var text: String
    init(minutes: Int) { text = String(minutes) }
    var minutes: Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), KeepAwakeModule.durationRange.contains(value) else { return nil }
        return value
    }
    @discardableResult
    func commit(to model: DashboardModel, start: Bool = false) -> Bool {
        guard let minutes else { return false }
        if start { AwakeSessionActions(model: model).start(minutes: minutes) }
        else { model.onKeepAwakeMinutesChanged(minutes) }
        return true
    }
}

/// In-process hosts can invoke the rendered Start action without requiring an
/// ordered/key window. This bridge never owns or substitutes the editor's draft.
final class AwakeDurationEditorCommands {
    fileprivate var startAction: (() -> Void)?
    @discardableResult func start() -> Bool {
        guard let startAction else { return false }
        startAction()
        return true
    }
}

struct AwakeDurationEditor: View {
    @ObservedObject var model: DashboardModel
    var showsStart = false
    private let commands: AwakeDurationEditorCommands?
    @StoredState private var draft: AwakeDurationDraft
    @FocusState private var focused: Bool

    init(model: DashboardModel, showsStart: Bool = false, commands: AwakeDurationEditorCommands? = nil) {
        self.model = model
        self.showsStart = showsStart
        self.commands = commands
        _draft = State(initialValue: AwakeDurationDraft(minutes: model.keepAwakeMinutes))
    }

    private func start() { draft.commit(to: model, start: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Minutes", text: $draft.text)
                    .textFieldStyle(.roundedBorder).frame(width: 62)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .focused($focused)
                    .accessibilityLabel("Custom duration in minutes")
                    .onSubmit { draft.commit(to: model) }
                Text("min").foregroundStyle(.secondary)
                Stepper("Duration", value: Binding(get: { draft.minutes ?? model.keepAwakeMinutes }, set: {
                    draft = AwakeDurationDraft(minutes: $0)
                    draft.commit(to: model)
                }), in: KeepAwakeModule.durationRange, step: 5)
                    .labelsHidden().disabled(draft.minutes == nil)
                    .accessibilityLabel("Adjust duration by five minutes")
                Spacer(minLength: 0)
                if showsStart {
                    Button("Start", action: start)
                        .disabled(draft.minutes == nil)
                }
            }
            if draft.minutes == nil {
                Text("Enter a whole number from 1 to 1440.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .help("1–1440 whole minutes; step controls adjust by 5 minutes")
        .onAppear { if showsStart { commands?.startAction = start } }
        .onDisappear { commands?.startAction = nil }
        .onChange(of: focused) { _, value in if !value { draft.commit(to: model) } }
        .onChange(of: model.keepAwakeMinutes) { _, minutes in
            if !focused && draft.minutes != nil { draft = AwakeDurationDraft(minutes: minutes) }
        }
    }
}

struct AwakeSessionWidget: View {
    @ObservedObject var model: DashboardModel
    let expanded: Bool
    @StoredState private var custom = false
    private var actions: AwakeSessionActions { AwakeSessionActions(model: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(actions.status).monospacedDigit()
                    .foregroundStyle(model.keepAwakeProtectionFailed ? Color.orange : model.keepAwakeActive ? .blue : .secondary)
                    .accessibilityLabel("Keep awake: \(actions.status)")
                Spacer()
                if model.keepAwakeCanStop || model.keepAwakeProtectionFailed {
                    Button("End session", action: model.onKeepAwakeStop)
                        .buttonStyle(.borderedProminent).tint(.blue)
                        .accessibilityLabel("End keep awake session and pause current app rules")
                }
            }
            if model.keepAwakeRemaining > 0 {
                HStack {
                    Button("+15 min", action: model.onKeepAwakeExtend)
                        .disabled(model.keepAwakeRemaining >= 86400 || model.stoppingModules.contains(.keepAwake))
                    Spacer()
                    if model.keepAwakeProtectionFailed {
                        Button("Retry session", action: actions.retry)
                            .disabled(model.stoppingModules.contains(.keepAwake))
                    }
                }
            } else {
                HStack(spacing: 5) {
                    ForEach(AwakeSessionActions.presets, id: \.self) { minutes in
                        Button("\(minutes)") { actions.start(minutes: minutes) }
                            .accessibilityLabel("Start keep awake for \(minutes) minutes")
                            .help("Start a \(minutes)-minute session")
                    }
                    Text("min").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { custom.toggle() } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("Custom keep awake duration")
                }.disabled(model.stoppingModules.contains(.keepAwake))
                if let minutes = actions.recentDuration {
                    HStack {
                        Text("Last choice").font(.caption).foregroundStyle(.secondary)
                        Button("\(minutes) min") { actions.start(minutes: minutes) }
                            .accessibilityLabel("Start keep awake for \(minutes) minutes")
                        Spacer()
                    }.disabled(model.stoppingModules.contains(.keepAwake))
                }
                if custom || expanded {
                    AwakeDurationEditor(model: model, showsStart: true)
                        .disabled(model.stoppingModules.contains(.keepAwake))
                }
            }
            DashboardSwitchRow(title: "Keep display awake", isOn: Binding(get: { model.keepDisplayAwake }, set: model.onKeepDisplayAwakeChanged))
                .disabled(model.stoppingModules.contains(.keepAwake))
            if !model.keepAwakeAppNames.isEmpty {
                Text("Requested by: " + model.keepAwakeAppNames.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.keepAwakeAppsPaused {
                HStack {
                    Text("App rules paused").foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume", action: model.onKeepAwakeResume)
                        .accessibilityLabel("Resume keep awake app rules")
                        .disabled(model.stoppingModules.contains(.keepAwake))
                }
            }
        }
    }
}

struct QuickWidget: View {
    @ObservedObject var model: DashboardModel
    let entry: WidgetEntry
    @StoredState private var disconnect: BluetoothDevice?
    var body: some View {
        if let kind = entry.known {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: kind.feature.symbol).foregroundStyle(.blue).frame(width: 18)
                        Text(kind.title).font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    Button { model.onOpenSettings(SettingsGroup.forFeature(kind.feature)) } label: {
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("\(kind.title) settings")
                        .accessibilityLabel("\(kind.title) settings")
                }
                if !model.enabledModules.contains(kind.module) {
                    HStack {
                        Text("Feature is off").foregroundStyle(.secondary)
                        Spacer()
                        Button("Set up") { model.onOpenSettings(SettingsGroup.forFeature(kind.feature)) }
                    }
                } else {
                    switch kind {
                    case .keepAwake: awake
                    case .audio: audio
                    case .displays: displays
                    case .windows: windows
                    case .clipboard: clipboard
                    case .bluetooth: bluetooth
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .alert("Disconnect device?", isPresented: Binding(get: { disconnect != nil }, set: { if !$0 { disconnect = nil } })) {
                Button("Disconnect", role: .destructive) {
                    if let disconnect {
                        if model.automaticReconnectEnabled && model.selectedAddresses.contains(disconnect.address) { model.onAutoDeviceChanged(disconnect.address, false) }
                        model.onManualConnection(disconnect.address)
                    }; disconnect = nil
                }
                Button("Cancel", role: .cancel) { disconnect = nil }
            } message: { Text("Disconnect \(disconnect?.name ?? "device")? Its auto-reconnect rule will be turned off if active. Have another input device ready before disconnecting a keyboard or mouse.") }
        }
    }
    private var awake: some View {
        AwakeSessionWidget(model: model, expanded: entry.expanded)
    }
    private var audio: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entry.expanded ? AudioDirection.allCases : [.output], id: \.self) { direction in
                Picker(direction == .input ? "Microphone" : "Output", selection: Binding(get: { model.audioRoutes[direction] ?? "" }, set: { model.onAudioSelect($0, direction) })) {
                    Text("Unavailable").tag("")
                    ForEach(model.audioDevices.filter { $0.directions.contains(direction) }) { Text($0.name).tag($0.uid) }
                }
            }
            if entry.expanded {
                Text(model.audioStatus).font(.caption)
                if model.audioOverrides.values.contains(true) { Button("Resume preferred routes", action: model.onAudioResume) }
            }
        }
    }
    private var displays: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.monitors.isEmpty { Text("No displays available. Check connections or Displays settings.").font(.caption) }
            ForEach(model.monitors, id: \.uuid) { monitor in
                DashboardSwitchRow(title: monitor.name, isOn: Binding(get: { monitor.enabled }, set: { model.onMonitorChanged(monitor.uuid, $0) }))
                    .disabled(model.displaySettling || model.monitorBusy || !model.displaySupported || monitor.id == nil || (monitor.enabled && model.activeMonitorCount <= 1))
            }
            if model.monitorBusy || model.displaySettling { Text("Waiting for display operation…").font(.caption) }
            if entry.expanded {
                Button("Arrange displays…", action: model.onArrangeDisplays)
                    .disabled(!model.enabledModules.contains(.arrangement) || !model.displaySupported || model.monitorBusy || model.displaySettling || model.disabledMonitorCount > 0 || model.pendingArrangement || model.currentLayout.count < 2)
                if entry.showWindows { windows }
            }
        }
    }
    @ViewBuilder private var windows: some View {
        if model.enabledModules.contains(.windows), let module = model.windowPositions {
            WindowRestoreWidget(module: module, expanded: entry.expanded, target: entry.windowLayoutID)
        } else {
            Text("Window layouts are off.").font(.caption)
            Button("Set up window layouts") { model.onOpenSettings(.displays) }
        }
    }
    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Button("Open history", action: model.onClipboardOpen); Spacer(); Text("⌘⇧V").foregroundStyle(.secondary) }
            Text(model.clipboardRecording ? "Recording" : "Recording paused").font(.caption)
            if entry.expanded {
                Text("\(model.clipboardCount) entries · no previews here").font(.caption)
                Button(model.clipboardRecording ? "Pause recording" : "Resume recording") { model.onClipboardRecording(!model.clipboardRecording) }
            }
        }
    }
    private var bluetooth: some View {
        VStack(alignment: .leading, spacing: 8) {
            let selected = model.devices.filter { model.selectedAddresses.contains($0.address) }
            if selected.isEmpty { Text("No chosen devices available. Choose targets in Sound & connections.").font(.caption) }
            ForEach(selected, id: \.address) { device in
                HStack {
                    Text(device.name).lineLimit(2)
                    Spacer()
                    Button(device.connected ? "Disconnect" : "Connect") {
                        if device.connected { disconnect = device } else { model.onManualConnection(device.address) }
                    }.disabled(model.bluetoothPermissionRequired || model.bluetoothManualBusy || model.bluetoothRadioOn != true)
                }
                if entry.expanded { Text(model.bluetoothDeviceStates[device.address] ?? (device.connected ? "Connected" : "Disconnected")).font(.caption) }
            }
            let missing = model.selectedAddresses.subtracting(Set(model.devices.map(\.address)))
            if !missing.isEmpty { Text("\(missing.count) chosen devices unavailable; targets are preserved.").font(.caption) }
            if entry.expanded {
                Text(model.bluetoothSummary).font(.caption)
                Toggle("Automatic reconnect", isOn: Binding(get: { model.automaticReconnectEnabled }, set: model.onAutomaticReconnectChanged))
                    .disabled(!model.bluetoothAvailable || model.bluetoothPermissionRequired || model.legacyServicePresent)
            }
            if model.bluetoothPermissionRequired { Button("Set up Bluetooth access") { model.onOpenSettings(.sound) } }
        }
    }
}

struct WindowRestoreWidget: View {
    @ObservedObject var module: WindowPositions
    let expanded: Bool
    let target: String
    @StoredState private var choice = ""
    private var selected: String { target.isEmpty ? choice : target }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if module.layouts.isEmpty { Text("No saved layouts. Save one in Displays settings.").font(.caption) }
            if !target.isEmpty && !module.layouts.contains(where: { $0.id == target }) {
                Text("Chosen layout unavailable. Your target is preserved; choose another in Edit.").font(.caption)
            } else if expanded {
                ForEach(module.layouts) { layout in
                    HStack { Text(layout.name); Spacer(); Button("Restore") { module.restore(layout.id) }.disabled(!module.canRestore(layout.id)).accessibilityLabel("Restore \(layout.name)") }
                    if !module.canRestore(layout.id) { Text("Requires access and the saved display set, settled and confirmed.").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                if target.isEmpty {
                    Picker("Layout", selection: $choice) {
                        Text("Choose layout").tag("")
                        ForEach(module.layouts) { Text($0.name).tag($0.id) }
                    }
                } else { Text(module.layouts.first { $0.id == target }?.name ?? "Unavailable") }
                Button("Restore windows") { module.restore(selected) }.disabled(!module.canRestore(selected))
            }
            if !module.permitted { Text("Accessibility access required in Displays settings.").font(.caption) }
            else if !module.ready { Text("Waiting for stable, confirmed displays.").font(.caption) }
            Text(module.summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var widgetEditor: WidgetEditingSession
    init(model: DashboardModel) { self.model = model; self.widgetEditor = model.settingsWidgetEditor }
    var body: some View {
        HSplitView {
            List(SettingsGroup.allCases, selection: Binding<SettingsGroup?>(get: { model.settingsGroup }, set: { if let value = $0 { model.settingsGroup = value } })) { group in
                Text(group.rawValue).tag(group)
            }.listStyle(.sidebar).frame(minWidth: 175, idealWidth: 190, maxWidth: 240)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.settingsGroup.rawValue).font(.largeTitle)
                    SafetyAlerts(model: model)
                    if model.settingsGroup == .general { general }
                    else if model.settingsGroup == .quickActions { editor }
                    else {
                        ForEach(model.settingsGroup.modules) { module in
                            DashboardCard {
                                Toggle(module.title, isOn: Binding(get: { model.enabledModules.contains(module) }, set: { model.onModuleChanged(module, $0) }))
                                    .disabled(model.stoppingModules.contains(module) || ((module == .monitors || module == .arrangement) && model.monitorBusy))
                                Text(module.detail).font(.caption).foregroundStyle(.secondary)
                                if model.stoppingModules.contains(module) { Text("Finishing recovery before stopping…").foregroundStyle(.orange) }
                            }
                        }
                        ForEach(features, id: \.self) { feature in DashboardView(model: model, feature: feature).id(feature) }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.id(model.settingsGroup).frame(minWidth: 440, idealWidth: 620)
        }.frame(minWidth: 680, minHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private var features: [DashboardTab] {
        var seen = Set<DashboardTab>()
        return model.settingsGroup.modules.map(\.dashboardFeature).filter { seen.insert($0).inserted }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if widgetEditor.draft != nil {
                HStack {
                    Button("Cancel", action: widgetEditor.cancel)
                    Button("Done") { widgetEditor.done(save: model.onSaveWidgets) }
                }
                WidgetEditor(layout: Binding(get: { widgetEditor.draft ?? model.widgetLayout }, set: { widgetEditor.draft = $0 }), model: model)
            } else {
                Text("Choose, order, and resize the actions shown in the menu-bar popup.")
                Button("Edit quick actions") { widgetEditor.begin(model.widgetLayout) }
                ForEach(model.widgetLayout.entries) { Text($0.known?.title ?? $0.kind) }
            }
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardCard {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.onLoginChanged))
                Button("Run setup again…", action: model.onRunSetup)
                Text("Setup starts from your current settings. Nothing is applied until Finish.").font(.caption)
            }
            DashboardCard {
                Text("Updates").font(.headline)
                Text(model.updateStatus)
                Button("Check for updates", action: model.onCheckUpdates).disabled(model.updateChecking)
                if model.updateAvailable { Button("Install update…", action: model.onInstallUpdate) }
            }
            DisclosureGroup("Diagnostics") { Text(model.watchdogStatus).textSelection(.enabled) }
        }
    }
}
