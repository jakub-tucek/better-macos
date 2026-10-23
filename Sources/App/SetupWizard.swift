import AppKit
import SwiftUI

/// Only configuration is checkpointed: never clipboard contents, window captures,
/// permission grants, running sessions, or an Apply request.
struct SetupConfiguration: Codable, Equatable {
    var audioAutomatic: Bool
    var outputPreferences: [String]
    var inputPreferences: [String]
    var outputFallback: String
    var inputFallback: String
    var bluetoothAutomatic: Bool
    var bluetoothTargets: Set<String>
    var protectAudio: Bool
    var switchAudio: Bool
    var protectedTargets: Set<String>
    var confirmDisplays: Bool
    var matchEdges: Bool
    var quitGuard: Bool
    var quitDuration: Double
    var animations: Bool
    var spaces: Bool
    var speed: Int
    var compactMenu: Bool
    var hideMenu: Bool
    var awakeMinutes: Int
    var displayAwake: Bool
    var awakeApps: [String: String]
    var clipboardPersistence: Bool
    var clipboardDays: Int
    var clipboardExclusions: String
    var windowsAutomatic: Bool
    var windowsPaused: Bool
    var windowsSelected: String
    var windowsExclusions: String
    var mouseAcceleration: Bool
    var mouseTracking: Double

    init(_ model: DashboardModel) {
        audioAutomatic = model.audioAutomatic
        outputPreferences = model.audioPreferences[.output] ?? []
        inputPreferences = model.audioPreferences[.input] ?? []
        outputFallback = model.audioFallbacks[.output] ?? ""
        inputFallback = model.audioFallbacks[.input] ?? ""
        bluetoothAutomatic = model.automaticReconnectEnabled
        bluetoothTargets = model.selectedAddresses
        protectAudio = model.protectOtherAudio; switchAudio = model.switchAudioOutput
        protectedTargets = model.protectedAudioAddresses
        confirmDisplays = model.confirmMonitorDisable; matchEdges = model.matchScreenEdges
        quitGuard = model.quitGuardEnabled; quitDuration = model.quitGuardDuration
        animations = model.animationsEnabled; spaces = model.spacesEnabled; speed = model.spacesSpeed.rawValue
        compactMenu = model.compactMenuBar; hideMenu = model.menuBarHiding
        awakeMinutes = model.keepAwakeMinutes; displayAwake = model.keepDisplayAwake; awakeApps = model.keepAwakeApps
        clipboardPersistence = model.clipboardPersistence; clipboardDays = model.clipboardDays; clipboardExclusions = model.clipboardExclusions
        windowsAutomatic = model.windowPositions?.automatic ?? false
        windowsPaused = model.windowPositions?.paused ?? false
        windowsSelected = model.windowPositions?.selected ?? ""
        windowsExclusions = model.windowPositions?.exclusions ?? ""
        mouseAcceleration = model.mouseAcceleration; mouseTracking = model.mouseTracking
    }

    /// Disabled modules don't publish their saved settings. Read preferences, not
    /// backends, to preserve those choices when repeating setup.
    mutating func readSaved(_ defaults: UserDefaults) {
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        audioAutomatic = bool("audio.automatic", audioAutomatic)
        outputPreferences = defaults.stringArray(forKey: "audio.output.preferences") ?? outputPreferences
        inputPreferences = defaults.stringArray(forKey: "audio.input.preferences") ?? inputPreferences
        outputFallback = defaults.string(forKey: "audio.output.fallback") ?? outputFallback
        inputFallback = defaults.string(forKey: "audio.input.fallback") ?? inputFallback
        bluetoothAutomatic = bool("bluetooth.autoEnabled", bluetoothAutomatic)
        bluetoothTargets = Set(defaults.stringArray(forKey: "bluetooth.autoAddresses") ?? Array(bluetoothTargets))
        protectAudio = bool("bluetooth.protectAudio", protectAudio); switchAudio = bool("bluetooth.switchAudio", switchAudio)
        protectedTargets = Set(defaults.stringArray(forKey: "bluetooth.protectedAudioAddresses") ?? Array(protectedTargets))
        confirmDisplays = bool("monitors.confirmDisable", confirmDisplays); matchEdges = bool("arrangement.matchEdges", matchEdges)
        quitGuard = bool("quitGuard.enabled", quitGuard)
        quitDuration = defaults.object(forKey: "quitGuard.duration") as? Double ?? quitDuration
        animations = bool("animations.enabled", animations); spaces = bool("spaces.enabled", spaces)
        speed = defaults.object(forKey: "spaces.speed") as? Int ?? speed
        compactMenu = bool("menuBar.compact", compactMenu); hideMenu = bool("menuBar.hiding", hideMenu)
        awakeMinutes = defaults.object(forKey: "keepAwake.minutes") as? Int ?? awakeMinutes
        displayAwake = bool("keepAwake.display", displayAwake)
        awakeApps = defaults.dictionary(forKey: "keepAwake.apps") as? [String: String] ?? awakeApps
        clipboardPersistence = bool("clipboard.persistence", clipboardPersistence)
        clipboardDays = defaults.object(forKey: "clipboard.days") as? Int ?? clipboardDays
        clipboardExclusions = defaults.string(forKey: "clipboard.exclusions") ?? clipboardExclusions
        windowsAutomatic = bool("windows.auto", windowsAutomatic); windowsPaused = bool("windows.paused", windowsPaused)
        windowsSelected = defaults.string(forKey: "windows.selected") ?? windowsSelected
        windowsExclusions = defaults.string(forKey: "windows.exclusions") ?? windowsExclusions
        normalize()
    }
    mutating func normalize() {
        quitDuration = QuitGuard.normalizedDuration(quitDuration.isFinite ? quitDuration : 3)
        awakeMinutes = min(1440, max(1, awakeMinutes))
        clipboardDays = min(365, max(1, clipboardDays))
        speed = TransitionSpeed.from(rawValue: speed).rawValue
        mouseTracking = mouseTracking.isFinite ? min(SystemMouseBackend.trackingRange.upperBound, max(SystemMouseBackend.trackingRange.lowerBound, mouseTracking)) : 1
    }
    func install(in model: DashboardModel) {
        model.audioAutomatic = audioAutomatic
        model.audioPreferences = [.input: inputPreferences, .output: outputPreferences]
        model.audioFallbacks = [.input: inputFallback, .output: outputFallback]
        model.automaticReconnectEnabled = bluetoothAutomatic; model.selectedAddresses = bluetoothTargets
        model.protectOtherAudio = protectAudio; model.switchAudioOutput = switchAudio; model.protectedAudioAddresses = protectedTargets
        model.confirmMonitorDisable = confirmDisplays; model.matchScreenEdges = matchEdges
        model.quitGuardEnabled = quitGuard; model.quitGuardDuration = quitDuration
        model.animationsEnabled = animations; model.spacesEnabled = spaces; model.spacesSpeed = TransitionSpeed.from(rawValue: speed)
        model.compactMenuBar = compactMenu; model.menuBarHiding = hideMenu
        model.keepAwakeMinutes = awakeMinutes; model.keepDisplayAwake = displayAwake; model.keepAwakeApps = awakeApps
        model.clipboardPersistence = clipboardPersistence; model.clipboardDays = clipboardDays; model.clipboardExclusions = clipboardExclusions
        model.mouseAcceleration = mouseAcceleration; model.mouseTracking = mouseTracking
    }

    /// Preferences only, for an owner which is not enabled yet. Recovery journals
    /// and module admission are deliberately excluded. The host stages every new
    /// owner before activating any of them (Audio can also be owned by Bluetooth).
    func inactivePreferences(for module: AppModule) -> [String: Any] {
        switch module {
        case .audio: return ["audio.automatic": audioAutomatic, "audio.output.preferences": outputPreferences,
            "audio.input.preferences": inputPreferences, "audio.output.fallback": outputFallback, "audio.input.fallback": inputFallback]
        case .bluetooth: return ["bluetooth.autoEnabled": bluetoothAutomatic, "bluetooth.autoAddresses": bluetoothTargets.sorted(),
            "bluetooth.protectAudio": protectAudio, "bluetooth.switchAudio": switchAudio, "bluetooth.protectedAudioAddresses": protectedTargets.sorted()]
        case .keepAwake: return ["keepAwake.minutes": awakeMinutes, "keepAwake.display": displayAwake, "keepAwake.apps": awakeApps]
        case .menuBar: return ["menuBar.compact": compactMenu, "menuBar.hiding": hideMenu]
        case .quitGuard: return ["quitGuard.enabled": quitGuard, "quitGuard.duration": quitDuration]
        case .spaces: return ["animations.enabled": animations, "spaces.enabled": spaces, "spaces.speed": speed]
        case .clipboard: return ["clipboard.persistence": clipboardPersistence, "clipboard.days": clipboardDays, "clipboard.exclusions": clipboardExclusions]
        case .windows: return ["windows.auto": windowsAutomatic, "windows.paused": windowsPaused, "windows.selected": windowsSelected, "windows.exclusions": windowsExclusions]
        case .monitors: return ["monitors.confirmDisable": confirmDisplays]
        case .arrangement: return ["arrangement.matchEdges": matchEdges]
        case .mouse: return [:]
        }
    }
}

struct SetupCheckpoint: Codable {
    var version = 1
    var selected: [String]
    var configuration: SetupConfiguration
    var widgets: WidgetLayout
}

final class SetupDraft: ObservableObject {
    enum Step: Hashable { case welcome, selection, configure(SettingsGroup), permissions, widgets, review, results }
    @Published var selected: Set<AppModule>
    @Published var step: Step = .welcome
    @Published var widgets: WidgetLayout
    @Published var results: [String] = []
    @Published var outcomes: [AppModule: FeatureSetupOutcome] = [:]
    @Published var applying = false
    @Published var discoveryStatus = ""
    @Published var windowsAutomatic: Bool
    @Published var windowsPaused: Bool
    @Published var windowsSelected: String
    @Published var windowsExclusions: String
    let controls = DashboardModel()
    let initialSelection: Set<AppModule>
    let initialConfiguration: SetupConfiguration
    let savedWindowLayouts: [WindowLayout]
    private let defaults: UserDefaults
    private static let checkpointKey = "ui.setup.draft.v1"
    private var widgetsVisited = false
    private var checkpointing = false
    private let suggestWidgetsOnFirstVisit: Bool
    var onDiscover: (SetupDraft) -> Void = { _ in }
    var onBluetoothPermission: () -> Void = {}
    var onRetryPermissions: () -> Void = {}
    @Published var accessibilityGranted = false
    @Published var bluetoothGranted = false

    init(current: DashboardModel, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = current.enabledModules; initialSelection = current.enabledModules
        widgets = current.widgetLayout
        suggestWidgetsOnFirstVisit = current.widgetLayout.entries.isEmpty && current.enabledModules.isEmpty
        var configuration = SetupConfiguration(current); configuration.readSaved(defaults)
        initialConfiguration = configuration
        savedWindowLayouts = current.windowPositions?.layouts ?? defaults.data(forKey: "windows.layouts").flatMap { try? JSONDecoder().decode([WindowLayout].self, from: $0) } ?? []
        windowsAutomatic = configuration.windowsAutomatic; windowsPaused = configuration.windowsPaused
        windowsSelected = configuration.windowsSelected; windowsExclusions = configuration.windowsExclusions
        configuration.install(in: controls)
        copyDiscovery(current)
        // Shared controls operate on an isolated model; no host callbacks are copied.
        controls.onAudioAutomatic = { [weak controls] in controls?.audioAutomatic = $0 }
        controls.onAudioPreferences = { [weak controls] values, direction in controls?.audioPreferences[direction] = values }
        controls.onAudioFallback = { [weak controls] uid, direction in controls?.audioFallbacks[direction] = uid }
        controls.onAutomaticReconnectChanged = { [weak controls] in controls?.automaticReconnectEnabled = $0 }
        controls.onAutoDeviceChanged = { [weak controls] address, value in
            if value { controls?.selectedAddresses.insert(address) } else { controls?.selectedAddresses.remove(address) }
        }
        controls.onProtectAudioChanged = { [weak controls] in controls?.protectOtherAudio = $0 }
        controls.onSwitchAudioChanged = { [weak controls] in controls?.switchAudioOutput = $0 }
        controls.onProtectedDeviceChanged = { [weak controls] address, value in
            if value { controls?.protectedAudioAddresses.insert(address) } else { controls?.protectedAudioAddresses.remove(address) }
        }
        controls.onMonitorDisableModeChanged = { [weak controls] in controls?.confirmMonitorDisable = $0 }
        controls.onMatchScreenEdgesChanged = { [weak controls] in controls?.matchScreenEdges = $0 }
        controls.onQuitGuardChanged = { [weak controls] in controls?.quitGuardEnabled = $0 }
        controls.onQuitGuardDurationChanged = { [weak controls] in controls?.quitGuardDuration = QuitGuard.normalizedDuration($0) }
        controls.onAnimationsChanged = { [weak controls] in controls?.animationsEnabled = $0 }
        controls.onSpacesChanged = { [weak controls] in controls?.spacesEnabled = $0 }
        controls.onSpeedChanged = { [weak controls] in controls?.spacesSpeed = $0 }
        controls.onCompactMenuBarChanged = { [weak controls] in controls?.compactMenuBar = $0 }
        controls.onMenuBarHidingChanged = { [weak controls] in controls?.menuBarHiding = $0 }
        controls.onKeepAwakeMinutesChanged = { [weak controls] in
            guard KeepAwakeModule.durationRange.contains($0) else { return }
            controls?.keepAwakeMinutes = $0
        }
        controls.onKeepDisplayAwakeChanged = { [weak controls] in controls?.keepDisplayAwake = $0 }
        controls.onKeepAwakeRemoveApp = { [weak controls] in controls?.keepAwakeApps.removeValue(forKey: $0) }
        controls.onClipboardPersistence = { [weak controls] in controls?.clipboardPersistence = $0 }
        controls.onClipboardDays = { [weak controls] in controls?.clipboardDays = min(365, max(1, $0)) }
        controls.onClipboardExclusions = { [weak controls] in controls?.clipboardExclusions = $0 }
        syncSelection()
    }
    var configuration: SetupConfiguration {
        var value = SetupConfiguration(controls)
        value.windowsAutomatic = windowsAutomatic; value.windowsPaused = windowsPaused
        value.windowsSelected = windowsSelected; value.windowsExclusions = windowsExclusions
        value.normalize(); return value
    }
    var steps: [Step] {
        [.welcome, .selection] + SettingsGroup.allCases.filter { !selected.isDisjoint(with: $0.modules) }.map(Step.configure) + [.permissions, .widgets, .review]
    }
    var needsAccessibility: Bool { !selected.isDisjoint(with: [.arrangement, .windows, .quitGuard, .spaces]) }
    var unresolvedPermissions: [String] {
        (needsAccessibility && !accessibilityGranted ? ["Accessibility: later setup may be required for selected controls."] : []) +
        (selected.contains(.bluetooth) && !bluetoothGranted ? ["Bluetooth: access is unresolved; device controls may be unavailable."] : [])
    }
    func syncSelection() { controls.enabledModules = selected }
    func setSelected(_ module: AppModule, enabled: Bool) {
        guard !applying else { return }
        if enabled { selected.insert(module) } else { selected.remove(module) }
        syncSelection()
    }
    @discardableResult func finish(using apply: (SetupDraft, @escaping ([String]) -> Void) -> Void) -> Bool {
        guard step == .review, !applying else { return false }
        applying = true
        apply(self) { [self] result in results = result; applying = false; step = .results }
        return true
    }
    @discardableResult func cancel() -> Bool {
        guard !applying else { return false }
        discardCheckpoint(); return true
    }
    func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        if step == .welcome { checkpointing = true }
        if step == .permissions && !widgetsVisited {
            if suggestWidgetsOnFirstVisit { widgets = .suggested(for: selected) }
            widgetsVisited = true
        }
        step = steps[index + 1]
    }
    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }; step = steps[index - 1]
    }
    func copyDiscovery(_ model: DashboardModel) {
        controls.audioDevices = model.audioDevices; controls.audioRoutes = model.audioRoutes
        controls.devices = model.devices; controls.bluetoothRadioOn = model.bluetoothRadioOn
        controls.bluetoothControlsAvailable = model.bluetoothControlsAvailable
        controls.bluetoothObservationSource = model.bluetoothObservationSource
        controls.bluetoothAvailable = true; controls.bluetoothPermissionRequired = false
        controls.legacyServicePresent = model.legacyServicePresent
        controls.spacesAvailable = true; controls.spacesPermission = model.spacesPermission
        controls.audioStatus = "Draft preferences — routes change only after Finish if automatic routing is enabled."
        controls.bluetoothSummary = "Draft reconnect policy — no connection commands during setup."
    }
    var hasCheckpoint: Bool { checkpoint != nil }
    private var checkpoint: SetupCheckpoint? {
        guard let data = defaults.data(forKey: Self.checkpointKey), let value = try? JSONDecoder().decode(SetupCheckpoint.self, from: data), value.version == 1 else { return nil }
        return value
    }
    func saveCheckpoint() {
        let value = SetupCheckpoint(selected: selected.map(\.rawValue), configuration: configuration, widgets: widgets)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.checkpointKey) }
    }
    func autosaveCheckpoint() {
        guard checkpointing, !applying, step != .results else { return }
        saveCheckpoint()
    }
    func resumeCheckpoint() {
        guard var saved = checkpoint else { return }
        saved.configuration.normalize(); saved.widgets.normalize()
        selected = Set(saved.selected.compactMap(AppModule.init(rawValue:)))
        saved.configuration.install(in: controls)
        windowsAutomatic = saved.configuration.windowsAutomatic; windowsPaused = saved.configuration.windowsPaused
        windowsSelected = saved.configuration.windowsSelected; windowsExclusions = saved.configuration.windowsExclusions
        widgets = saved.widgets; widgetsVisited = true; checkpointing = true; syncSelection(); step = .selection
    }
    func discardCheckpoint() { checkpointing = false; defaults.removeObject(forKey: Self.checkpointKey) }
    static func clearCheckpoint(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: checkpointKey) }
}

struct WindowPolicyControls: View {
    @Binding var automatic: Bool
    @Binding var paused: Bool
    @Binding var selected: String
    @Binding var exclusions: String
    var layouts: [WindowLayout]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Restore after reconnect or wake", isOn: $automatic)
            Toggle("Pause automatic restoration", isOn: $paused)
            Picker("Automatic layout", selection: $selected) {
                Text("Use unique matching layout").tag("")
                ForEach(layouts) { Text($0.name).tag($0.id) }
                if !selected.isEmpty && !layouts.contains(where: { $0.id == selected }) { Text("Unavailable saved layout").tag(selected) }
            }
            Text("With several layouts for the same displays, choose one for automatic restore. Pause does not block manual Restore.").font(.caption)
            TextField("Excluded bundle IDs, comma separated", text: $exclusions)
            Text("Exact app and window-title matches only. Ambiguous, untitled, and unsupported windows are skipped.").font(.caption)
        }
    }
}

struct SetupWizard: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var draft: SetupDraft
    let close: () -> Void
    @StoredState private var confirmFinish = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(AppStyle.title).accessibilityAddTraits(.isHeader); Spacer(); if draft.applying { ProgressView().controlSize(.small) } }.padding(24)
            Divider()
            stepContent
            Divider()
            HStack {
                if draft.step != .results {
                    Button("Cancel") { if draft.cancel() { close() } }
                    if draft.step != .welcome { Button("Back") { draft.back() } }
                    Button("Save draft & close") { draft.saveCheckpoint(); close() }
                }
                Spacer()
                if draft.step == .results { Button("Close", action: close) }
                else if draft.step == .review { Button("Finish") { confirmFinish = true }.buttonStyle(.borderedProminent) }
                else if draft.step != .welcome { Button(draft.step == .permissions ? "Continue / do later" : "Continue") { draft.next() }.buttonStyle(.borderedProminent) }
            }.padding(16).disabled(draft.applying)
        }.frame(minWidth: 640, minHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: draft.selected) { _, _ in draft.autosaveCheckpoint() }
            .onChange(of: draft.widgets) { _, _ in draft.autosaveCheckpoint() }
            .onChange(of: draft.step) { _, _ in draft.autosaveCheckpoint() }
            .onChange(of: draft.windowsAutomatic) { _, _ in draft.autosaveCheckpoint() }
            .onChange(of: draft.windowsPaused) { _, _ in draft.autosaveCheckpoint() }
            .onChange(of: draft.windowsSelected) { _, _ in draft.autosaveCheckpoint() }
            .onChange(of: draft.windowsExclusions) { _, _ in draft.autosaveCheckpoint() }
            .onReceive(draft.controls.objectWillChange) { _ in
                DispatchQueue.main.async { draft.autosaveCheckpoint() }
            }
            .interactiveDismissDisabled(draft.applying)
            .alert("Apply these choices?", isPresented: $confirmFinish) {
                Button("Finish") {
                    draft.finish(using: model.onFinishSetup)
                }
                Button("Back to review", role: .cancel) {}
            } message: { Text("Only Finish applies feature and configuration changes. Results are reported independently; failures do not roll back successful features. See the review for side effects.") }
    }
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.id(draft.step).disabled(draft.applying)
    }
    private var title: String {
        switch draft.step {
        case .welcome: return "Welcome to Better macOS"
        case .selection: return "Choose improvements"
        case .configure(let group): return "Configure · \(group.rawValue)"
        case .permissions: return "Access when you need it"
        case .widgets: return "Choose quick actions"
        case .review: return "Review and finish"
        case .results: return "Setup results"
        }
    }
    @ViewBuilder private var content: some View {
        switch draft.step {
        case .welcome:
            Text("Choose the improvements you want. Selections and configuration remain a draft until Finish. You can repeat setup from General settings.")
            Text("Existing settings and running sessions are not reset by opening or canceling setup.").font(.caption)
            Button("Set up") { draft.next() }.buttonStyle(.borderedProminent)
            Button("Skip for now", action: model.onSkipSetup)
            if draft.hasCheckpoint {
                DashboardCard {
                    Text("A saved draft is available. It is not applied automatically.")
                    Button("Resume saved draft") { draft.resumeCheckpoint() }
                    Button("Discard saved draft") { draft.discardCheckpoint(); draft.objectWillChange.send() }
                }
            }
        case .selection:
            ForEach(SettingsGroup.allCases.filter { !$0.modules.isEmpty }) { group in
                Text(group.rawValue).font(.headline)
                ForEach(group.modules) { module in
                    DashboardCard {
                        Toggle(module.title, isOn: Binding(get: { draft.selected.contains(module) }, set: { value in
                            draft.setSelected(module, enabled: value)
                        }))
                        Text(module.detail).font(.caption)
                        if [.arrangement, .windows, .quitGuard, .spaces].contains(module) { Label("Accessibility for supported controls", systemImage: "hand.raised").font(.caption) }
                        if module == .bluetooth { Text("Bluetooth access · device availability varies").font(.caption) }
                        if [.spaces, .menuBar, .mouse].contains(module) { Text("Experimental / hardware-dependent").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        case .configure(let group):
            Text("Draft only. Configure selected improvements; permission grants are handled next. Operational actions remain in Settings after Finish.").font(.caption)
            if group == .sound {
                Button("Refresh available devices") { draft.onDiscover(draft) }
                Text(draft.discoveryStatus).font(.caption)
            }
            ForEach(selectedFeatures(group), id: \.self) { feature in
                DashboardView(model: draft.controls, feature: feature, draftMode: true)
                if feature == .windows {
                    WindowPolicyControls(automatic: $draft.windowsAutomatic, paused: $draft.windowsPaused, selected: $draft.windowsSelected, exclusions: $draft.windowsExclusions, layouts: draft.savedWindowLayouts)
                }
                if feature == .keepAwake {
                    Text("Enabling Keep awake may activate saved app rules for apps already running. Finish never starts a timed session.").font(.caption)
                }
            }
        case .permissions:
            Text("macOS controls access. A request is not a guarantee. Grants remain in macOS even if you cancel setup.")
            if draft.needsAccessibility {
                DashboardCard {
                    Text("Accessibility permits supported window, keyboard, screen-edge, and desktop-switching controls.")
                    Text(draft.accessibilityGranted ? "Access currently granted" : "Access not confirmed").font(.caption)
                    Button("Open Accessibility settings", action: model.onAccessibilitySettings)
                }
            }
            if draft.selected.contains(.bluetooth) {
                DashboardCard {
                    Text("Bluetooth access allows paired-device discovery and connection controls.")
                    Text(draft.bluetoothGranted ? "Access currently granted" : "Access not confirmed").font(.caption)
                    Button("Request / open Bluetooth access", action: draft.onBluetoothPermission)
                }
            }
            if !draft.needsAccessibility && !draft.selected.contains(.bluetooth) { Text("No extra access step for your selection. Some hardware controls can still be unavailable.") }
            Button("Retry access checks") { draft.onRetryPermissions() }
            ForEach(draft.unresolvedPermissions, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        case .widgets:
            Text("Widgets never enable features. Disabled or unavailable targets link to Settings.").font(.caption)
            WidgetEditor(layout: $draft.widgets, model: draft.controls, allowSettings: false, layouts: draft.savedWindowLayouts)
        case .review:
            ForEach(AppModule.allCases) { module in
                HStack {
                    Text(module.title)
                    Spacer()
                    Text(draft.selected.contains(module) ? "Enabled" : "Disabled")
                }
                if draft.selected.contains(module) { Text(configurationSummary(module)).font(.caption).foregroundStyle(.secondary) }
            }
            Text("\(draft.widgets.entries.count) quick-action widgets. Configuration changes apply only to selected features.")
            ForEach(draft.unresolvedPermissions, id: \.self) { Text($0).foregroundStyle(.orange) }
            DashboardCard {
                Text("What Finish can change").font(.headline)
                Text("Finish installs the reviewed policies before activating selected features. Reviewed keep-awake app rules may activate immediately for running apps; Bluetooth automatic reconnect may connect chosen devices; automatic audio routing may choose reviewed routes. Animation changes may restart Dock and Finder. Window automatic restoration can run on later reconnect/wake.")
                Text("Setup never starts timed awake sessions, records clipboard copies, captures/moves windows, switches/rearranges displays, or applies pointer tuning. Mouse Apply stays explicit in Input settings.")
                if draft.selected.contains(.clipboard) {
                    Text(draft.configuration.clipboardPersistence ? "Disk history requested: local and unencrypted; up to \(draft.configuration.clipboardDays) days for unpinned entries. Capture remains unchanged (paused on fresh launches)." : "Clipboard remains memory-only. Turning existing disk retention off deletes its archive.")
                }
                Text("Deselecting an existing feature stops its work through normal recovery. Disabling Keep awake ends its session; removing a widget never does.")
            }.font(.caption)
        case .results:
            ForEach(Array(draft.results.enumerated()), id: \.offset) { _, result in Text(result).textSelection(.enabled) }
            Button("Open Settings") { model.onOpenSettings(nil) }
        }
    }
    private func selectedFeatures(_ group: SettingsGroup) -> [DashboardTab] {
        var seen = Set<DashboardTab>()
        return group.modules.filter { draft.selected.contains($0) }.map(\.dashboardFeature).filter { seen.insert($0).inserted }
    }
    private func configurationSummary(_ module: AppModule) -> String {
        let value = draft.configuration
        switch module {
        case .monitors: return value.confirmDisplays ? "20-second undo confirmation" : "Immediate switching (no countdown)"
        case .arrangement: return "Screen-edge matching: \(value.matchEdges ? "requested" : "off")"
        case .audio: return "Automatic routing: \(value.audioAutomatic ? "on" : "off"); output preferences: \(value.outputPreferences.joined(separator: ", ")); microphone preferences: \(value.inputPreferences.joined(separator: ", ")); fallbacks: \(value.outputFallback), \(value.inputFallback)"
        case .bluetooth: return "Reconnect: \(value.bluetoothAutomatic ? "on" : "paused"); \(value.bluetoothTargets.count) targets; other-audio protection: \(value.protectAudio ? "on" : "off"); route reconnected speakers: \(value.switchAudio ? "on" : "off")"
        case .quitGuard: return "Hold to quit: \(value.quitGuard ? "on" : "off"), \(Int(value.quitDuration)) seconds"
        case .keepAwake: return "\(value.awakeMinutes)-minute default; display wake: \(value.displayAwake ? "on" : "off"); app rules: \(value.awakeApps.values.sorted().joined(separator: ", "))"
        case .clipboard: return "Recording unchanged; disk history: \(value.clipboardPersistence ? "on" : "off"), \(value.clipboardDays) days; exclusions: \(value.clipboardExclusions)"
        case .mouse: return String(format: "Proposed acceleration: %@; tracking: %.2f. Finish transfers the proposal to Input settings, but never applies it.", value.mouseAcceleration ? "on" : "off", value.mouseTracking)
        case .windows: return "Automatic restore: \(value.windowsAutomatic ? "on" : "off"); paused: \(value.windowsPaused ? "yes" : "no"); target: \(value.windowsSelected.isEmpty ? "unique match" : value.windowsSelected); exclusions: \(value.windowsExclusions)"
        case .menuBar: return "Compact spacing: \(value.compactMenu ? "on" : "off"); icon hiding: \(value.hideMenu ? "on" : "off")"
        case .spaces: return "Animation preset: \(value.animations ? "on" : "off"); desktop switching: \(value.spaces ? "requested" : "off"); speed: \(TransitionSpeed.from(rawValue: value.speed).title)"
        }
    }
}
