import SwiftUI
import AppKit

enum DashboardTab: String, CaseIterable {
    case modules = "Modules"
    case monitors = "Monitors"
    case bluetooth = "Bluetooth"
    case audio = "Audio"
    case spaces = "Animations"
    case menuBar = "Menu bar"
    case keyboard = "Keyboard"
    case keepAwake = "Keep awake"
    case windows = "Windows"
    case clipboard = "Clipboard"
    case mouse = "Mouse"
}

/// The same state drives the persistent popover and its controls. Refreshes
/// update values without destroying the UI or closing its containing popover.
final class DashboardModel: ObservableObject {
    @Published var windowPositions: WindowPositions?
    @Published var audioDevices: [AudioDevice] = []
    @Published var audioRoutes: [AudioDirection: String] = [:]
    @Published var audioPreferences: [AudioDirection: [String]] = [:]
    @Published var audioFallbacks: [AudioDirection: String] = [:]
    @Published var audioOverrides: [AudioDirection: Bool] = [:]
    @Published var audioAutomatic = false
    @Published var audioStatus = "Loading audio devices…"
    var onAudioSelect: (String, AudioDirection) -> Void = { _, _ in }
    var onAudioAutomatic: (Bool) -> Void = { _ in }
    var onAudioResume: () -> Void = {}
    var onAudioPreferences: ([String], AudioDirection) -> Void = { _, _ in }
    var onAudioFallback: (String, AudioDirection) -> Void = { _, _ in }
    @Published var enabledModules = Set(AppModule.allCases)
    @Published var stoppingModules = Set<AppModule>()
    @Published var tab: DashboardTab = .monitors
    @Published var monitors: [Monitor] = []
    @Published var monitorBusy = false
    @Published var confirmMonitorDisable = false
    @Published var matchScreenEdges = false
    @Published var screenEdgesActive = false
    @Published var activeMonitorCount = 0
    @Published var displaySupported = false
    @Published var displaySettling = true
    @Published var watchdogStatus = "Starting recovery watchdog…"
    @Published var countdowns: [String: Int] = [:]
    @Published var disabledMonitorCount = 0
    @Published var currentLayout: [DisplayPosition] = []
    @Published var layoutPreviews: [String: [DisplayPosition]] = [:]
    @Published var pendingArrangement = false
    @Published var devices: [BluetoothDevice] = []
    @Published var selectedAddresses = Set<String>()
    @Published var automaticReconnectEnabled = false
    @Published var bluetoothAvailable = false
    @Published var bluetoothBusy = false
    @Published var bluetoothManualBusy = false
    @Published var bluetoothRadioOn: Bool?
    @Published var bluetoothPermissionRequired = false
    @Published var bluetoothDeviceStates: [String: String] = [:]
    @Published var bluetoothSummary = "Loading devices…"
    @Published var protectOtherAudio = true
    @Published var switchAudioOutput = true
    @Published var protectedAudioAddresses = Set<String>()
    @Published var legacyServicePresent = false
    @Published var spacesEnabled = false
    @Published var animationsEnabled = false
    @Published var animationsBusy = false
    @Published var animationRecoveryRequired = false
    @Published var spacesPermission = false
    @Published var spacesAvailable = false
    @Published var spacesSpeed: TransitionSpeed = .instant
    @Published var launchAtLogin = false
    @Published var updateStatus = "Not checked yet"
    @Published var updateChecking = false
    @Published var updateAvailable = false
    @Published var compactMenuBar = false
    @Published var menuBarHiding = false
    @Published var menuBarHidden = false
    @Published var menuBarRecoveryRequired = false
    @Published var quitGuardEnabled = false
    @Published var quitGuardActive = false
    @Published var quitGuardDuration = 3.0
    @Published var keepAwakeActive = false
    @Published var keepAwakeCanStop = false
    @Published var keepAwakeRemaining: TimeInterval = 0
    @Published var keepAwakeMinutes = 30
    @Published var keepAwakeApps: [String: String] = [:]
    @Published var keepAwakeAppNames: [String] = []
    @Published var keepAwakeAppsPaused = false
    @Published var keepAwakeProtectionFailed = false
    var onKeepAwakeAddApp: () -> Void = {}
    var onKeepAwakeRemoveApp: (String) -> Void = { _ in }
    var onKeepAwakeResume: () -> Void = {}
    @Published var keepDisplayAwake = false
    @Published var clipboardRecording = false
    @Published var clipboardCount = 0
    @Published var clipboardPersistence = false
    @Published var clipboardStoragePending = false
    @Published var clipboardDays = 7
    @Published var clipboardExclusions = ""
    var onClipboardRecording: (Bool) -> Void = { _ in }
    var onClipboardPersistence: (Bool) -> Void = { _ in }
    var onClipboardDays: (Int) -> Void = { _ in }
    var onClipboardExclusions: (String) -> Void = { _ in }
    var onClipboardOpen: () -> Void = {}
    var onClipboardClear: () -> Void = {}
    @Published var mouseRecoveryRequired = false
    private var mouseErrorMessage: String?
    @Published var mouseCapabilityError: String?
    @Published var mouseAcceleration = true
    @Published var mouseTracking = 1.0
    private var mouseDraftInitialized = false
    @Published var mouseOverrideActive = false
    var onApplyMouse: () -> Void = {}
    var onRefreshMouse: () -> Void = {}
    var onRestoreMouse: () -> Void = {}
    var onKeepAwakeStart: () -> Void = {}
    var onKeepAwakeStop: () -> Void = {}
    var onKeepAwakeExtend: () -> Void = {}
    var onKeepAwakeMinutesChanged: (Int) -> Void = { _ in }
    var onKeepDisplayAwakeChanged: (Bool) -> Void = { _ in }
    var onQuitGuardChanged: (Bool) -> Void = { _ in }
    var onQuitGuardDurationChanged: (Double) -> Void = { _ in }
    var onRetryQuitGuard: () -> Void = {}
    var onCompactMenuBarChanged: (Bool) -> Void = { _ in }
    var onMenuBarHidingChanged: (Bool) -> Void = { _ in }
    var onToggleMenuBar: () -> Void = {}
    var onRestoreMenuBarSpacing: () -> Void = {}
    @Published var errorMessage: String?

    var onMonitorChanged: (String, Bool) -> Void = { _, _ in }
    var onMonitorDisableModeChanged: (Bool) -> Void = { _ in }
    var onMatchScreenEdgesChanged: (Bool) -> Void = { _ in }
    var onModuleChanged: (AppModule, Bool) -> Void = { _, _ in }
    var onKeepDisabled: (String) -> Void = { _ in }
    var onRestoreAll: () -> Void = {}
    var onArrangeDisplays: () -> Void = {}
    var onKeepArrangement: () -> Void = {}
    var onAutoDeviceChanged: (String, Bool) -> Void = { _, _ in }
    var onManualConnection: (String) -> Void = { _ in }
    var onAutomaticReconnectChanged: (Bool) -> Void = { _ in }
    var onBluetoothPowerOn: () -> Void = {}
    var onBluetoothAccessRequested: () -> Void = {}
    var onProtectAudioChanged: (Bool) -> Void = { _ in }
    var onSwitchAudioChanged: (Bool) -> Void = { _ in }
    var onProtectedDeviceChanged: (String, Bool) -> Void = { _, _ in }
    var onTakeOverLegacy: () -> Void = {}
    var onSpacesChanged: (Bool) -> Void = { _ in }
    var onAnimationsChanged: (Bool) -> Void = { _ in }
    var onRestoreAnimations: () -> Void = {}
    var onSpeedChanged: (TransitionSpeed) -> Void = { _ in }
    var onLoginChanged: (Bool) -> Void = { _ in }
    var onCheckUpdates: () -> Void = {}
    var onInstallUpdate: () -> Void = {}
    var onClose: () -> Void = {}
    var onQuit: () -> Void = {}

    func updateMouseRecovery(required: Bool, message: String?) {
        mouseRecoveryRequired = required
        if let message { errorMessage = message }
        else if errorMessage == mouseErrorMessage { errorMessage = nil }
        mouseErrorMessage = message
    }

    func initializeMouseDraft(_ snapshot: MouseOriginalSettings, force: Bool = false) {
        guard force || !mouseDraftInitialized,
              case .number(let linear) = snapshot.acceleration,
              case .number(let tracking) = snapshot.speed else { return }
        mouseAcceleration = linear == 0
        mouseTracking = tracking
        mouseDraftInitialized = true
    }

    func autoReconnectBinding(for address: String) -> Binding<Bool> {
        Binding(get: { self.selectedAddresses.contains(address) }, set: { enabled in
            if enabled { self.selectedAddresses.insert(address) }
            else { self.selectedAddresses.remove(address) }
            self.onAutoDeviceChanged(address, enabled)
        })
    }
}

/// Explicit blue enabled state, independent of system accent color and whether
/// the status-bar window is active. Exposes standard Toggle accessibility.
struct BlueSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Color.blue : Color.gray.opacity(0.35))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1).padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
        .help(label)
    }
}

/// A snapshot-only map: geometry reads and layout planning happen outside SwiftUI.
struct MonitorLayoutMap: View {
    let positions: [DisplayPosition]
    let monitors: [Monitor]
    var selected: String? = nil
    var onSelect: ((String) -> Void)? = nil

    private var bounds: CGRect {
        positions.reduce(CGRect.null) { result, position in
            result.union(CGRect(x: Int(position.x), y: Int(position.y),
                                width: Int(position.width ?? 0), height: Int(position.height ?? 0)))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if positions.isEmpty || bounds.isNull || bounds.width <= 0 || bounds.height <= 0 {
                Text("Waiting for display layout…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let scale = min((geometry.size.width - 12) / bounds.width, (geometry.size.height - 12) / bounds.height)
                let left = (geometry.size.width - bounds.width * scale) / 2
                let top = (geometry.size.height - bounds.height * scale) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(positions, id: \.uuid) { position in
                        let monitor = monitors.first { $0.uuid == position.uuid }
                        let width = CGFloat(position.width ?? 0) * scale
                        let height = CGFloat(position.height ?? 0) * scale
                        let name = monitor?.name ?? "Display"
                        let tile = VStack(spacing: 2) {
                            Image(systemName: monitor?.isBuiltIn == true ? "laptopcomputer" : "display")
                            Text(name).font(.system(size: 9, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(3)
                        .frame(width: max(1, width - 2), height: max(1, height - 2))
                        .background(selected == position.uuid ? Color.blue.opacity(0.3) : Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected == position.uuid ? Color.blue : Color.secondary.opacity(0.5), lineWidth: selected == position.uuid ? 2 : 1))
                        .help(name)
                        Group {
                            if let onSelect {
                                Button { onSelect(position.uuid) } label: { tile }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Preview turning off \(name)")
                            } else { tile.accessibilityLabel(name) }
                        }
                        .offset(x: left + (CGFloat(position.x) - bounds.minX) * scale,
                                y: top + (CGFloat(position.y) - bounds.minY) * scale)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }.frame(height: 145)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var disconnectWarning: BluetoothDevice?
    @State private var showDisconnectWarning = false
    @State private var showLegacyWarning = false
    @State private var previewMonitor: String?
    @State private var customAwakeDuration = false
    @State private var clipboardExclusionsDraft = ClipboardExclusionsDraft()

    private var disconnectDisablesRule: Bool {
        guard let device = disconnectWarning else { return false }
        return model.automaticReconnectEnabled && model.selectedAddresses.contains(device.address)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.blue)
                Text("Fix macOS").font(.headline)
                Spacer()
                Button { model.tab = model.tab == .modules ? .monitors : .modules } label: {
                    Image(systemName: model.tab == .modules ? "gearshape.fill" : "gearshape")
                }
                .buttonStyle(.plain).help("Settings and modules")
                .accessibilityLabel("Settings and modules")
                Button(action: model.onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close dashboard")
            }.padding(16)
            if model.tab != .modules {
            Picker("Controls", selection: $model.tab) {
                ForEach(DashboardTab.allCases.filter { $0 != .modules }, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).labelsHidden().padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Back") { model.tab = .monitors }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.errorMessage {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.animationRecoveryRequired {
                        Button("Restore original animation settings", action: model.onRestoreAnimations)
                            .disabled(model.animationsBusy)
                    }
                    if model.menuBarRecoveryRequired {
                        Button("Restore original menu-bar spacing", action: model.onRestoreMenuBarSpacing)
                    }
                    if model.mouseRecoveryRequired {
                        Button("Retry restoring original mouse settings", action: model.onRestoreMouse)
                    }
                    switch model.tab {
                    case .windows:
                        if let positions = model.windowPositions { WindowPositionsView(module: positions) }
                        else { disabledModule("Window positions") }
                    case .modules: modules
                    case .monitors:
                        if !model.enabledModules.isDisjoint(with: [.monitors, .arrangement]) || model.pendingArrangement || model.disabledMonitorCount > 0 { monitors }
                        else { disabledModule("Display modules") }
                    case .audio:
                        if model.enabledModules.contains(.audio) { audioControls }
                        else { Text("Enable Audio in Settings and modules.") }
                    case .bluetooth:
                        if model.enabledModules.contains(.bluetooth) { bluetooth }
                        else { disabledModule("Bluetooth reconnect") }
                    case .spaces:
                        if model.enabledModules.contains(.spaces) { spaces }
                        else { disabledModule("Space animations") }
                    case .menuBar:
                        if model.enabledModules.contains(.menuBar) { menuBar }
                        else { disabledModule("Menu bar") }
                    case .keyboard:
                        if model.enabledModules.contains(.quitGuard) { keyboard }
                        else { disabledModule("Hold to quit") }
                    case .keepAwake:
                        if model.enabledModules.contains(.keepAwake) { keepAwake }
                        else { disabledModule("Keep awake") }
                    case .clipboard:
                        if model.enabledModules.contains(.clipboard) { clipboard }
                        else { disabledModule("Clipboard") }
                    case .mouse:
                        if model.enabledModules.contains(.mouse) { mouse }
                        else { disabledModule("Mouse") }
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                BlueSwitch(label: "Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.onLoginChanged))
                Text("Launch at login").font(.caption)
                Spacer()
                Button("Quit", action: model.onQuit).disabled(model.monitorBusy)
            }.padding(14)
        }
        .frame(width: 430, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: model.onClose)
        .alert(disconnectDisablesRule ? "Disconnect and turn off auto-reconnect?" : "Disconnect this device?", isPresented: $showDisconnectWarning) {
            Button(disconnectDisablesRule ? "Turn off & disconnect" : "Disconnect", role: .destructive) {
                if let device = disconnectWarning {
                    if disconnectDisablesRule { model.onAutoDeviceChanged(device.address, false) }
                    model.onManualConnection(device.address)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disconnect \(disconnectWarning?.name ?? "this device")? \(disconnectDisablesRule ? "Its auto-reconnect rule will be turned off; other rules are unchanged. " : "")If this is your keyboard or mouse, make sure you have another usable input device first.")
        }
        .alert("Move auto-connect into Fix macOS?", isPresented: $showLegacyWarning) {
            Button("Take over", action: model.onTakeOverLegacy)
            Button("Cancel", role: .cancel) {}
        } message: { Text("The existing LaunchAgent will be stopped and disabled. Its source files are preserved.") }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Automatic audio routing")
                Spacer()
                BlueSwitch(label: "Automatic audio routing", isOn: Binding(get: { model.audioAutomatic }, set: model.onAudioAutomatic))
            }
            Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
            Text("Preferences apply on device changes or Resume. Connected Bluetooth audio is protected.").font(.caption)
            ForEach(AudioDirection.allCases, id: \.self) { direction in
                audioDirectionControls(direction)
            }
            Button("Resume preferred routes", action: model.onAudioResume)
        }
    }

    private func audioDirectionControls(_ direction: AudioDirection) -> some View {
        let devices = model.audioDevices.filter { $0.directions.contains(direction) }
        let preferred = model.audioPreferences[direction] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text(direction == .input ? "Microphone" : "Output").font(.headline)
            Picker("Current", selection: Binding(get: { model.audioRoutes[direction] ?? "" }, set: { model.onAudioSelect($0, direction) })) {
                Text("Unavailable").tag("")
                ForEach(devices) { device in Text("\(device.name) · \(device.uid)").tag(device.uid) }
            }
            if model.audioOverrides[direction] == true { Text("Manual override until this device list changes or Resume.").font(.caption) }
            Text("Preference order (highest first)").font(.caption)
            ForEach(Array(preferred.enumerated()), id: \.element) { index, uid in
                HStack {
                    Text("\(index + 1). \(devices.first { $0.uid == uid }?.name ?? "Unavailable") · \(uid)").lineLimit(2)
                    Spacer()
                    Button("↑") {
                        var values = preferred; values.swapAt(index, index - 1)
                        model.onAudioPreferences(values, direction)
                    }.disabled(index == 0).help("Move preference up")
                    Button("Remove") { model.onAudioPreferences(preferred.filter { $0 != uid }, direction) }
                }.font(.caption)
            }
            Menu("Add preferred device") {
                ForEach(devices.filter { !preferred.contains($0.uid) }) { device in
                    Button("\(device.name) · \(device.uid)") { model.onAudioPreferences(preferred + [device.uid], direction) }
                }
            }
            Picker("Fallback", selection: Binding(get: { model.audioFallbacks[direction] ?? "" }, set: { model.onAudioFallback($0, direction) })) {
                Text("Keep current route").tag("")
                ForEach(devices) { device in Text("\(device.name) · \(device.uid)").tag(device.uid) }
                if let uid = model.audioFallbacks[direction], !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
                    Text("Unavailable · \(uid)").tag(uid)
                }
            }
            Divider()
        }
    }

    private var clipboard: some View {
        card {
            HStack {
                Text("Record clipboard history")
                Spacer()
                BlueSwitch(label: "Record clipboard history", isOn: Binding(get: { model.clipboardRecording }, set: model.onClipboardRecording))
            }
            Text("\(model.clipboardCount) entries · ⌘⇧V to search").font(.caption)
            HStack {
                Button("Open history", action: model.onClipboardOpen)
                Button("Clear history", action: model.onClipboardClear)
            }
            Text("Starts paused each launch. Up to 100 entries, 64 KB per text, PNG images up to 4 MB (32 MB total). Selection copies; paste normally in your app.").font(.caption)
            HStack {
                Text("Save history to disk")
                Spacer()
                BlueSwitch(label: "Save clipboard history to disk", isOn: Binding(get: { model.clipboardPersistence }, set: model.onClipboardPersistence))
            }
            Stepper("Retain for \(model.clipboardDays) days", value: Binding(get: { model.clipboardDays }, set: model.onClipboardDays), in: 1...365)
            Text("Pins bypass age expiry, but count and image caps still apply. Disk history is local and unencrypted. Turning disk history off deletes its archive.").font(.caption)
            if model.clipboardStoragePending {
                Text("Disk cleanup/save pending — retrying. Old disk entries may remain until storage recovers; keep the module enabled.").font(.caption).foregroundStyle(.orange)
            }
            TextField("Excluded app bundle IDs, comma separated", text: Binding(get: {
                clipboardExclusionsDraft.text(applied: model.clipboardExclusions)
            }, set: { clipboardExclusionsDraft.edited = $0 }))
                .onSubmit(applyClipboardExclusions)
            Button("Apply exclusions", action: applyClipboardExclusions)
            Text("Exclusions use the foreground app at capture time and remove its existing entries. Concealed, transient, and autogenerated clipboard formats are skipped.").font(.caption)
        }
    }

    private func applyClipboardExclusions() {
        clipboardExclusionsDraft.apply(current: model.clipboardExclusions, save: model.onClipboardExclusions)
    }

    private var mouse: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                Label("Acceleration and tracking", systemImage: "computermouse").font(.headline)
                Text("Session-wide for devices using HIDMouseAcceleration, not per-device. Trackpad-specific keys are never written. Hardware behavior and reconnect still need verification.").font(.caption).foregroundStyle(.secondary)
                if let error = model.mouseCapabilityError { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("All-mice controls · no per-device support").font(.caption)
                HStack {
                    Text("Acceleration")
                    Spacer()
                    BlueSwitch(label: "Mouse acceleration", isOn: $model.mouseAcceleration)
                }
                Slider(value: $model.mouseTracking, in: SystemMouseBackend.trackingRange) { Text("Tracking") }
                Text(String(format: "Tracking: %.2f", model.mouseTracking)).font(.caption)
                Text("Proposed settings — applied together only when you click Apply.").font(.caption)
                Button("Read current settings", action: model.onRefreshMouse)
                Button("Apply mouse settings", action: model.onApplyMouse).disabled(model.mouseCapabilityError != nil || model.mouseRecoveryRequired)
                if model.mouseOverrideActive { Button("Restore original mouse settings", action: model.onRestoreMouse) }
                Text("Nothing changes until Apply. These runtime settings are restored on disable or quit, not saved as system preferences.").font(.caption)
            }
            card {
                Text("Separate wheel scrolling").font(.headline)
                Text(MouseModule.scrollLimitation).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Reverse mouse wheel direction")
                    Spacer()
                    BlueSwitch(label: "Reverse mouse wheel direction unavailable", isOn: .constant(false)).disabled(true)
                }
                Text("Wheel speed: unavailable").foregroundStyle(.secondary)
                Text("Trackpad, momentum, horizontal and modifier-assisted scrolling retain their existing behavior.").font(.caption)
            }
        }
    }

    private var keepAwake: some View {
        let presets = [15, 30, 45, 60, 120]
        let seconds = Int(ceil(model.keepAwakeRemaining))
        let countdown = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return VStack(alignment: .leading, spacing: 14) {
            card {
                HStack {
                    Label("Keep awake", systemImage: "cup.and.saucer.fill").font(.headline)
                    Spacer()
                    Text(model.keepAwakeProtectionFailed ? "Needs retry" : (model.keepAwakeActive ? "Active" : "Off"))
                        .foregroundStyle(model.keepAwakeActive ? .blue : .secondary)
                }
                if model.keepAwakeRemaining > 0 {
                    Text(countdown).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                        .accessibilityLabel("Time remaining: \(countdown)")
                    HStack {
                        Button("+15 min", action: model.onKeepAwakeExtend)
                            .disabled(model.keepAwakeRemaining >= 24 * 3600)
                        Spacer()
                        Button("Stop", action: model.onKeepAwakeStop)
                    }
                } else {
                    Picker("Duration", selection: Binding(get: {
                        customAwakeDuration || !presets.contains(model.keepAwakeMinutes) ? 0 : model.keepAwakeMinutes
                    }, set: { value in
                        customAwakeDuration = value == 0
                        if value != 0 { model.onKeepAwakeMinutesChanged(value) }
                    })) {
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("45 minutes").tag(45)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("Custom…").tag(0)
                    }
                    if customAwakeDuration || !presets.contains(model.keepAwakeMinutes) {
                        Stepper("\(model.keepAwakeMinutes) minutes", value: Binding(get: { model.keepAwakeMinutes },
                            set: model.onKeepAwakeMinutesChanged), in: 5...1440, step: 5)
                    }
                    Button("Start session", action: model.onKeepAwakeStart).buttonStyle(.borderedProminent)
                    if model.keepAwakeCanStop { Button("Stop", action: model.onKeepAwakeStop) }
                }
            }
            card {
                Text("While apps are running").font(.headline)
                Text("Includes apps running in the background.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.keepAwakeApps.keys.sorted(), id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.keepAwakeApps[id] ?? id)
                            Text(id).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.onKeepAwakeRemoveApp(id) }
                    }
                }
                Button("Add apps…", action: model.onKeepAwakeAddApp)
                if !model.keepAwakeAppNames.isEmpty {
                    Text("Requested by: " + model.keepAwakeAppNames.joined(separator: ", ")).font(.caption)
                }
                if model.keepAwakeAppsPaused {
                    Text("Stopped apps stay paused until they exit.").font(.caption)
                    Button("Resume", action: model.onKeepAwakeResume)
                }
            }
            card {
                HStack {
                    Text("Keep display awake")
                    Spacer()
                    BlueSwitch(label: "Keep display awake", isOn: Binding(get: { model.keepDisplayAwake }, set: model.onKeepDisplayAwakeChanged))
                }
                Text(model.keepDisplayAwake ? "Keep the computer and display awake until the session ends." : "Keep the computer awake while letting the display sleep.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Sleep from the Apple menu and closing the lid still work. Quitting Fix macOS ends the session.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var keyboard: some View {
        card {
            HStack {
                Text("Hold ⌘Q to quit")
                Spacer()
                BlueSwitch(label: "Hold Command Q to quit", isOn: Binding(get: { model.quitGuardEnabled }, set: model.onQuitGuardChanged))
            }
            HStack {
                Text("Hold for")
                Spacer()
                TextField("Seconds", value: Binding(get: { model.quitGuardDuration }, set: model.onQuitGuardDurationChanged),
                          format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 52)
                    .accessibilityLabel("Quit hold duration in seconds")
                Text("seconds")
                Stepper("Quit hold duration", value: Binding(get: { model.quitGuardDuration }, set: model.onQuitGuardDurationChanged),
                        in: 1...99, step: 1).labelsHidden().fixedSize()
            }
            Text("A popup names the app while you hold. Release early to cancel. Switching apps or clicking also cancels. Normal save prompts still appear.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.quitGuardActive {
                Text(model.quitGuardEnabled ? "Inactive — check Accessibility access, then retry." : "Requires Accessibility access.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Accessibility settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    if model.quitGuardEnabled { Button("Retry", action: model.onRetryQuitGuard) }
                }
            }
            Text("Applies to plain ⌘Q. Menu commands and other quit shortcuts stay unchanged.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                HStack {
                    Text("Compact spacing")
                    Spacer()
                    BlueSwitch(label: "Compact menu-bar spacing", isOn: Binding(get: { model.compactMenuBar }, set: model.onCompactMenuBarChanged))
                }
                Text("Experimental. Restart affected apps or log out to apply. Turning off restores your original spacing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card {
                HStack {
                    Text("Hide extra icons")
                    Spacer()
                    BlueSwitch(label: "Hide extra menu-bar icons", isOn: Binding(get: { model.menuBarHiding }, set: model.onMenuBarHidingChanged))
                }
                Text("Hold ⌘ and drag the divider left of the chevron. Move less-used icons left of the divider; keep Fix macOS and essential icons to its right.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.menuBarHiding {
                    Button(model.menuBarHidden ? "Show extra icons" : "Hide extra icons", action: model.onToggleMenuBar)
                }
                Text("Click the chevron to reveal icons. Quitting reveals them too. Icons beyond the notch may still need more space to appear.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monitors: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.enabledModules.contains(.monitors) {
                Picker("Disable mode", selection: Binding(
                    get: { model.confirmMonitorDisable }, set: model.onMonitorDisableModeChanged)) {
                    Text("Dangerously").tag(false)
                    Text("Safely (20s undo)").tag(true)
                }.disabled(model.monitorBusy || !model.countdowns.isEmpty)
            }
            if !model.countdowns.isEmpty {
                card {
                    ForEach(model.countdowns.keys.sorted(), id: \.self) { uuid in
                        Text("Restoring \(uuid == "layout" ? "previous layout" : model.monitors.first(where: { $0.uuid == uuid })?.name ?? "display") in \(model.countdowns[uuid] ?? 0)s")
                            .font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button(uuid == "layout" ? "Keep layout" : "Keep disabled") {
                                if uuid == "layout" { model.onKeepArrangement() }
                                else { model.onKeepDisabled(uuid) }
                            }.disabled(model.monitorBusy || (model.countdowns[uuid] ?? 0) <= 0)
                            Button("Restore now", action: model.onRestoreAll).disabled(model.monitorBusy || model.displaySettling)
                        }
                    }
                }
            }
            if model.enabledModules.contains(.arrangement) { arrangementPreview }
            card {
                ForEach(model.monitors, id: \.uuid) { monitor in
                    HStack(spacing: 10) {
                        Image(systemName: monitor.isBuiltIn ? "laptopcomputer" : "display")
                            .frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.name).font(.system(size: 13, weight: .medium))
                            if monitor.isMain || !monitor.enabled {
                                Text(monitor.isMain ? "Main" : "Off").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.enabledModules.contains(.monitors) {
                        BlueSwitch(label: "\(monitor.name) enabled", isOn: Binding(
                            get: { monitor.enabled }, set: { model.onMonitorChanged(monitor.uuid, $0) }))
                            .disabled(model.displaySettling || model.monitorBusy || !model.displaySupported || monitor.id == nil || (monitor.enabled && model.activeMonitorCount <= 1))
                        }
                    }
                    if monitor.uuid != model.monitors.last?.uuid { Divider() }
                }
            }
            if model.monitorBusy { ProgressView("Applying display change…").controlSize(.small) }
            if model.displaySettling { Text("Waiting for display connections to settle…").font(.caption).foregroundStyle(.secondary) }
            Button(model.pendingArrangement ? "Restore previous layout" : "Enable all disabled displays", action: model.onRestoreAll)
                .disabled(model.displaySettling || model.monitorBusy || (model.disabledMonitorCount == 0 && !model.pendingArrangement))
        }
    }

    private var arrangementPreview: some View {
        let selected = model.monitors.first { $0.uuid == previewMonitor && $0.enabled }
        let proposal = selected.flatMap { model.layoutPreviews[$0.uuid] }
        let busy = model.displaySettling || model.monitorBusy
        return card {
            HStack {
                Label("Layout", systemImage: "rectangle.3.group").font(.headline)
                Spacer()
                Button("Arrange…", action: model.onArrangeDisplays)
                    .disabled(busy || !model.displaySupported || model.disabledMonitorCount > 0 || model.pendingArrangement || model.currentLayout.count < 2)
                    .help("Drag screens to arrange your desk")
            }
            HStack {
                Text("Match screen edges").font(.subheadline)
                Spacer()
                BlueSwitch(label: "Match screen edges", isOn: Binding(
                    get: { model.matchScreenEdges }, set: model.onMatchScreenEdgesChanged))
            }
            if model.matchScreenEdges && !model.screenEdgesActive {
                Text("Paused — waiting for stable displays or Accessibility access.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.disabledMonitorCount > 0 {
                Text("Turn all screens on to arrange.").font(.caption2).foregroundStyle(.secondary)
            }
            MonitorLayoutMap(positions: model.currentLayout, monitors: model.monitors,
                             selected: selected?.uuid, onSelect: model.enabledModules.contains(.monitors) ? { previewMonitor = $0 } : nil)
                .disabled(busy)
            if let selected, model.enabledModules.contains(.monitors) {
                HStack {
                    Text("Without \(selected.name)").font(.caption).bold()
                    Spacer()
                    Button("Cancel") { previewMonitor = nil }.controlSize(.small)
                }
                if let proposal {
                    MonitorLayoutMap(positions: proposal, monitors: model.monitors)
                    Button("Apply — turn off \(selected.name)") {
                        model.onMonitorChanged(selected.uuid, false)
                        previewMonitor = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !model.displaySupported || !model.countdowns.isEmpty)
                    if model.confirmMonitorDisable {
                        Text("Reverts after 20 seconds unless confirmed.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.activeMonitorCount <= 1 ? "The last usable screen cannot be turned off." :
                         "No reliable preview for this arrangement. Check display mirroring, connections, and resolution.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func disabledModule(_ title: String) -> some View {
        card {
            Text("\(title) is off").font(.headline)
            Button("Enable in settings") { model.tab = .modules }
        }
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Modules").font(.headline)
            ForEach(AppModule.allCases) { module in
                card {
                    HStack {
                        Text(module.title).font(.headline)
                        Spacer()
                        BlueSwitch(label: "\(module.title) module", isOn: Binding(
                            get: { model.enabledModules.contains(module) },
                            set: { model.onModuleChanged(module, $0) }))
                            .disabled(model.stoppingModules.contains(module) ||
                                      ((module == .monitors || module == .arrangement) && model.monitorBusy))
                    }
                    if model.stoppingModules.contains(module) {
                        Text(module == .bluetooth ? "Stopping — finishing the current Bluetooth command…" : "Restoring displays before unloading…")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.help(module.detail)
            }
            DisclosureGroup("Diagnostics") {
                Text(model.watchdogStatus).font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            card {
                Text("Updates").font(.headline)
                Text(model.updateStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check for updates", action: model.onCheckUpdates).disabled(model.updateChecking)
                    if model.updateAvailable { Button("Install update…", action: model.onInstallUpdate) }
                }
            }
        }
    }

    private var bluetooth: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic reconnection").font(.headline)
                        Text(model.bluetoothSummary).font(.caption)
                            .foregroundStyle(model.selectedAddresses.isEmpty ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    BlueSwitch(label: "Enable automatic reconnection", isOn: Binding(
                        get: { model.automaticReconnectEnabled }, set: model.onAutomaticReconnectChanged))
                        .disabled(!model.bluetoothAvailable || model.legacyServicePresent || model.bluetoothPermissionRequired)
                }
                if model.bluetoothPermissionRequired {
                    Button("Allow Bluetooth access…", action: model.onBluetoothAccessRequested)
                } else if model.bluetoothRadioOn == false {
                    Button("Turn Bluetooth on", action: model.onBluetoothPowerOn).disabled(model.bluetoothManualBusy)
                }
                if model.legacyServicePresent {
                    Button("Take over existing service…") { showLegacyWarning = true }.disabled(model.bluetoothBusy)
                }
            }
            card {
                HStack {
                    Text("Paired device").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Auto-reconnect").font(.caption).foregroundStyle(.secondary)
                }
                bluetoothRows(model.devices.filter(isUsedBluetoothDevice))
                let otherDevices = model.devices.filter { !isUsedBluetoothDevice($0) }
                if !otherDevices.isEmpty {
                    DisclosureGroup("Other paired devices (\(otherDevices.count))") {
                        VStack(spacing: 12) { bluetoothRows(otherDevices) }.padding(.top, 8)
                    }
                }
                if model.devices.isEmpty { Text(model.bluetoothPermissionRequired ? "Grant Bluetooth access to show your paired devices." : "No paired devices found yet.").font(.caption).foregroundStyle(.secondary) }
            }
            card {
                HStack {
                    Text("Don’t interrupt other Bluetooth audio").font(.system(size: 12))
                    Spacer()
                    BlueSwitch(label: "Pause reconnection while other Bluetooth audio is connected", isOn: Binding(
                        get: { model.protectOtherAudio }, set: model.onProtectAudioChanged))
                }
                HStack {
                    Text("Use reconnected speakers as audio output").font(.system(size: 12))
                    Spacer()
                    BlueSwitch(label: "Switch audio output after safe reconnection", isOn: Binding(
                        get: { model.switchAudioOutput }, set: model.onSwitchAudioChanged))
                }
                DisclosureGroup("Advanced headphone detection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Always protect these devices as audio, even before macOS registers their audio output.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.devices, id: \.address) { device in
                            HStack {
                                Text(device.name).font(.caption)
                                Spacer()
                                BlueSwitch(label: "Always protect \(device.name) as audio", isOn: Binding(
                                    get: { model.protectedAudioAddresses.contains(device.address) },
                                    set: { model.onProtectedDeviceChanged(device.address, $0) }))
                            }
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
        }
    }

    private func isUsedBluetoothDevice(_ device: BluetoothDevice) -> Bool {
        device.connected || model.selectedAddresses.contains(device.address) ||
        model.protectedAudioAddresses.contains(device.address) ||
        !(model.bluetoothDeviceStates[device.address] ?? "").isEmpty
    }

    @ViewBuilder
    private func bluetoothRows(_ devices: [BluetoothDevice]) -> some View {
        ForEach(devices, id: \.address) { device in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    HStack(spacing: 4) {
                        Circle().fill(device.connected ? Color.green : Color.gray).frame(width: 5, height: 5)
                        Text(device.connected ? "Connected" : "Disconnected").font(.caption).foregroundStyle(.secondary)
                    }
                    if let state = model.bluetoothDeviceStates[device.address], !state.isEmpty {
                        Text(state).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                    }
                }
                Spacer(minLength: 4)
                Button(device.connected ? "Disconnect" : "Connect") {
                    if device.connected {
                        disconnectWarning = device
                        showDisconnectWarning = true
                    } else { model.onManualConnection(device.address) }
                }.controlSize(.small).frame(width: 78).disabled(model.bluetoothPermissionRequired || model.bluetoothManualBusy || model.bluetoothRadioOn == false)
                BlueSwitch(label: "Automatically reconnect \(device.name)", isOn: model.autoReconnectBinding(for: device.address))
                    .disabled(!model.bluetoothAvailable || model.bluetoothPermissionRequired)
            }
            if device.address != devices.last?.address { Divider() }
        }
    }

    private var spaces: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                HStack {
                    Text("Limit animations").font(.headline)
                    Spacer()
                    BlueSwitch(label: "Limit animations", isOn: Binding(
                        get: { model.animationsEnabled }, set: model.onAnimationsChanged))
                        .disabled(model.animationsBusy)
                }
                VStack(alignment: .leading, spacing: 8) {
                    animationScope("Dock", detail: "Reveal delay, sliding, bouncing, magnification")
                    animationScope("Minimize & restore", detail: "Scale instead of Genie")
                    animationScope("Finder & windows", detail: "Opening, closing, resizing")
                    animationScope("Scrolling", detail: "AppKit smooth scrolling")
                    animationScope("Window tiling", detail: "Experimental animation suppression")
                }
                Text("Dock and Finder restart when changed. Relaunch other apps; tiling may need a new login. Effects vary by app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card {
              DisclosureGroup("Advanced") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fast desktop switching").font(.headline).help("Horizontal trackpad swipes between desktops")
                        if !model.spacesAvailable || !model.spacesPermission {
                            Text(!model.spacesAvailable ? "Waiting for watchdog or display changes" : "Accessibility permission required")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    BlueSwitch(label: "Enable fast horizontal trackpad Space switching", isOn: Binding(
                        get: { model.spacesEnabled }, set: model.onSpacesChanged))
                        .disabled(!model.spacesAvailable || !model.animationsEnabled || model.animationsBusy)
                }
                Picker("Transition speed", selection: Binding(get: { model.spacesSpeed }, set: model.onSpeedChanged)) {
                    ForEach(TransitionSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(!model.spacesAvailable)
                if model.spacesAvailable && !model.spacesPermission {
                    Button("Open Accessibility settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("Mission Control and Control Center may still animate.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open macOS motion settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") {
                        NSWorkspace.shared.open(url)
                    }
                }
              }
            }
        }
    }

    private func animationScope(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
