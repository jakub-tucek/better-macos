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
    enum Step: Hashable { case welcome, feature(AppModule), configure(AppModule), permissions, widgets, review, results }
    static let featureOrder: [AppModule] = [.windows, .monitors, .arrangement, .keepAwake, .audio, .bluetooth, .clipboard, .quitGuard, .mouse, .spaces, .menuBar]
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
        [.welcome] + Self.featureOrder.flatMap { module -> [Step] in
            selected.contains(module) ? [.feature(module), .configure(module)] : [.feature(module)]
        } + [.permissions, .widgets, .review]
    }
    func choose(_ module: AppModule, enabled: Bool) {
        guard step == .feature(module), !applying else { return }
        setSelected(module, enabled: enabled)
        next()
    }
    func requiresAccessibility(for module: AppModule) -> Bool {
        guard selected.contains(module) else { return false }
        switch module {
        case .windows: return true
        case .arrangement: return controls.matchScreenEdges
        case .quitGuard: return controls.quitGuardEnabled
        case .spaces: return controls.spacesEnabled
        default: return false
        }
    }
    var needsAccessibility: Bool { selected.contains { requiresAccessibility(for: $0) } }
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
        widgets = saved.widgets; widgetsVisited = true; checkpointing = true; syncSelection(); step = .feature(Self.featureOrder[0])
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

extension AppModule {
    var setupNeedsAccessibility: Bool { [.windows, .arrangement, .quitGuard, .spaces].contains(self) }
    var setupAccess: String {
        if setupNeedsAccessibility { return "Accessibility for window and input controls" }
        if self == .bluetooth { return "Bluetooth permission for device discovery" }
        if self == .mouse { return "Hardware support required; Apply stays manual" }
        return "No additional macOS permission required"
    }
    var setupExplanation: String {
        switch self {
        case .windows: return "Put windows where you want them. Use keyboard shortcuts to tile them, or save a layout to restore your workspace later."
        case .monitors: return "Turn individual displays on or off from the menu bar, with recovery controls close at hand."
        case .arrangement: return "Make your virtual desk match your physical one. Arrange screens and smooth pointer movement across their edges."
        case .keepAwake: return "Keep your Mac awake for a task, presentation or download. Choose a timer when you need it, or let selected apps keep it awake."
        case .audio: return "Choose speakers and microphone independently. Optionally prefer particular devices when they become available."
        case .bluetooth: return "Reconnect the paired devices you choose, without repeatedly visiting system settings."
        case .clipboard: return "Find something you copied earlier. Search your local history, pin useful items and choose what stays on disk."
        case .quitGuard: return "Avoid an accidental ⌘Q. Hold the shortcut for a moment when you really want to quit."
        case .mouse: return "Tune supported mouse pointer acceleration and tracking. Preview your choices here and apply them explicitly in Settings."
        case .spaces: return "Reduce Dock and Finder animations, and optionally use faster keyboard-driven desktop switching."
        case .menuBar: return "Keep the menu bar tidy. Adjust icon spacing or tuck less-used icons behind a divider."
        }
    }
    var setupEffect: String {
        switch self {
        case .windows: return "Setup never captures or moves windows. Automatic restoration can act on later reconnects or wake when configured."
        case .monitors: return "The last usable display stays protected. Turning a display off requires a ready safety watchdog."
        case .arrangement: return "Setup does not rearrange screens. Edge matching starts only when access, layout and safety checks are ready."
        case .keepAwake: return "Finish never starts a timer. Saved app rules may activate immediately. Apple-menu Sleep and closing the lid still work."
        case .audio: return "Automatic routing can change audio routes after Finish. Choosing a microphone does not record audio."
        case .bluetooth: return "Automatic reconnect can connect selected devices after Finish. You choose which devices and whether to protect other audio."
        case .clipboard: return "Recording starts paused on a fresh launch. Disk history is optional, local and unencrypted; sensitive or excluded captures are rejected."
        case .quitGuard: return "Uses Accessibility for the keyboard shortcut. It requests normal quit and preserves app save prompts."
        case .mouse: return "Hardware support varies. Finish saves your proposal; only Apply in Input settings changes pointer behavior."
        case .spaces: return "Applying the animation preset can restart Dock and Finder. Desktop switching needs Accessibility and a ready watchdog; it may vary by macOS version."
        case .menuBar: return "Spacing changes may require apps to restart. You place the divider with ⌘-drag; hidden icons can be revealed again."
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
            HStack {
                Text("Better macOS").font(AppStyle.sectionTitle)
                Spacer()
                Text(progressLabel).font(.caption).foregroundStyle(.secondary)
                if draft.applying { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 32).padding(.vertical, 20)
            Divider()
            stepContent
            Divider()
            HStack {
                if draft.step != .results {
                    Button("Cancel") { if draft.cancel() { close() } }.buttonStyle(.plain).foregroundStyle(.secondary)
                    if draft.step != .welcome { Button("Back") { draft.back() } }
                    if draft.step != .welcome { Button("Save for later") { draft.saveCheckpoint(); close() } }
                }
                Spacer()
                if draft.step == .results { Button("Close", action: close) }
                else if draft.step == .review { Button("Finish") { confirmFinish = true }.buttonStyle(.borderedProminent) }
                else if case .feature(let module) = draft.step {
                    Button("Skip this feature") { draft.choose(module, enabled: false) }
                    Button("Enable & configure") { draft.choose(module, enabled: true) }.buttonStyle(.borderedProminent)
                }
                else if draft.step != .welcome { Button(draft.step == .permissions && !draft.unresolvedPermissions.isEmpty ? "Set up access later" : "Continue") { draft.next() }.buttonStyle(.borderedProminent) }
            }.controlSize(.large).padding(24).disabled(draft.applying)
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
                DispatchQueue.main.async { draft.objectWillChange.send(); draft.autosaveCheckpoint() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in draft.onRetryPermissions() }
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
            VStack(alignment: .leading, spacing: 24) {
                AppHeading(title: title, subtitle: subtitle)
                content
            }.frame(maxWidth: 560, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .top)
        }.id(draft.step).disabled(draft.applying)
    }
    private var progressLabel: String {
        switch draft.step {
        case .feature(let module), .configure(let module):
            return "Feature \((SetupDraft.featureOrder.firstIndex(of: module) ?? 0) + 1) of \(SetupDraft.featureOrder.count)"
        case .welcome: return "Make it yours"
        case .permissions: return "Access"
        case .widgets: return "Quick actions"
        case .review: return "Ready when you are"
        case .results: return "Complete"
        }
    }
    private var subtitle: String {
        switch draft.step {
        case .welcome: return "A few small improvements. A Mac that works your way."
        case .feature(let module): return module.detail
        case .configure: return "Choose how it should work. These changes stay in your draft until Finish."
        case .permissions: return "Only the access your choices need. You can come back to this later."
        case .widgets: return "Keep your everyday controls one click away."
        case .review: return "Your choices, before anything changes."
        case .results: return "See what’s ready and what still needs attention."
        }
    }
    private var title: String {
        switch draft.step {
        case .welcome: return "Welcome to Better macOS"
        case .feature(let module): return module.title
        case .configure(let module): return "Make \(module.title.lowercased()) yours"
        case .permissions: return "Access when you need it"
        case .widgets: return "Choose quick actions"
        case .review: return "Review and finish"
        case .results: return "Setup results"
        }
    }
    @ViewBuilder private var content: some View {
        switch draft.step {
        case .welcome:
            HStack(spacing: 16) {
                ForEach(["rectangle.split.2x2", "moon.zzz", "speaker.wave.2", "clipboard"], id: \.self) { AppSymbolBadge(symbol: $0) }
            }.padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 18) {
                welcomeRow("1", title: "Discover each feature", detail: "See what it does, then enable it or skip it.")
                welcomeRow("2", title: "Choose your settings", detail: "Configure the features you want, with access explained along the way.")
                welcomeRow("3", title: "Review and apply", detail: "Nothing in this draft changes your setup until you choose Finish.")
            }
            HStack {
                Button("Let’s get started") { draft.next() }.buttonStyle(.borderedProminent)
                Button("Not now", action: model.onSkipSetup)
            }.controlSize(.large).padding(.top, 8)
            Text("You can run setup again from Settings → General. Canceling keeps your current configuration.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.hasCheckpoint {
                DashboardCard {
                    Text("A saved draft is available. It is not applied automatically.")
                    Button("Resume saved draft") { draft.resumeCheckpoint() }
                    Button("Discard saved draft") { draft.discardCheckpoint(); draft.objectWillChange.send() }
                }
            }
        case .feature(let module):
            Image(systemName: module.dashboardFeature.symbol).font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24).accessibilityHidden(true)
            Text(module.setupExplanation).font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
            DashboardCard {
                Label("What to expect", systemImage: "sparkles").font(AppStyle.sectionTitle)
                Text(module.setupEffect).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(module.setupAccess, systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
            }
            Text(draft.selected.contains(module) ? "Currently included. Choose Enable & configure to review it, or Skip to turn it off at Finish." : "Currently not included. You can enable it now or leave it off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .configure(let module):
            if module == .bluetooth { permissionCard(bluetooth: true) }
            if module == .audio || module == .bluetooth {
                HStack {
                    Button("Find available devices") { draft.onDiscover(draft) }
                    Text(draft.discoveryStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            featureConfiguration(module)
            if draft.requiresAccessibility(for: module) { permissionCard(bluetooth: false) }
        case .permissions:
            Text("macOS grants stay in place if you cancel setup. Features with missing access remain unavailable until you grant it.")
                .font(.caption).foregroundStyle(.secondary)
            if draft.needsAccessibility {
                permissionCard(bluetooth: false)
            }
            if draft.selected.contains(.bluetooth) {
                permissionCard(bluetooth: true)
            }
            if !draft.needsAccessibility && !draft.selected.contains(.bluetooth) { Text("No extra access step for your selection. Some hardware controls can still be unavailable.") }
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
    private func welcomeRow(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(width: 28, height: 28).modifier(AppSurface()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppStyle.sectionTitle)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func permissionCard(bluetooth: Bool) -> some View {
        let granted = bluetooth ? draft.bluetoothGranted : draft.accessibilityGranted
        return DashboardCard {
            HStack {
                Label(bluetooth ? "Bluetooth access" : "Accessibility access", systemImage: "hand.raised")
                    .font(AppStyle.sectionTitle)
                Spacer()
                Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle" : "circle")
                    .font(.caption).foregroundStyle(granted ? Color.green : .secondary)
            }
            Text(bluetooth ? "Lets Better macOS discover paired devices and connect the ones you choose. It does not pair new devices during setup." : "Lets Better macOS control supported windows and respond to your keyboard or screen-edge actions. Enable Better macOS in Privacy & Security → Accessibility.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !granted {
                HStack {
                    Button(bluetooth ? "Allow Bluetooth…" : "Open Accessibility settings…", action: bluetooth ? draft.onBluetoothPermission : model.onAccessibilitySettings)
                    Button("Check again", action: draft.onRetryPermissions)
                }
                Text("You can continue without access and enable it later in Settings.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func featureConfiguration(_ module: AppModule) -> some View {
        if module == .windows {
            WindowPolicyControls(automatic: $draft.windowsAutomatic, paused: $draft.windowsPaused, selected: $draft.windowsSelected, exclusions: $draft.windowsExclusions, layouts: draft.savedWindowLayouts)
            Text("Save layouts and enable window keyboard shortcuts in Displays settings after setup.").font(.caption).foregroundStyle(.secondary)
        } else if module == .monitors {
            DashboardSwitchRow(title: "Offer a 20-second undo after disabling a display", isOn: Binding(get: { draft.controls.confirmMonitorDisable }, set: draft.controls.onMonitorDisableModeChanged))
            Text("Display switching stays manual. Setup never turns a screen off.").font(.caption).foregroundStyle(.secondary)
        } else if module == .arrangement {
            DashboardSwitchRow(title: "Match pointer movement across screen edges", isOn: Binding(get: { draft.controls.matchScreenEdges }, set: draft.controls.onMatchScreenEdgesChanged))
            Text("Arrange your displays in Settings after setup. Pointer matching requires Accessibility and a ready safety watchdog.").font(.caption).foregroundStyle(.secondary)
        } else {
            DashboardView(model: draft.controls, feature: module.dashboardFeature, draftMode: true)
        }
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
