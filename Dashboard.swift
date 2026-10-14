import SwiftUI
import AppKit

enum DashboardTab: String, CaseIterable {
    case monitors = "Monitors"
    case bluetooth = "Bluetooth"
    case spaces = "Spaces"
}

/// The same state drives the persistent popover and its controls. Refreshes
/// update values without destroying the UI or closing its containing popover.
final class DashboardModel: ObservableObject {
    @Published var tab: DashboardTab = .monitors
    @Published var monitors: [Monitor] = []
    @Published var monitorBusy = false
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
    @Published var spacesPermission = false
    @Published var spacesAvailable = false
    @Published var spacesSpeed: TransitionSpeed = .instant
    @Published var launchAtLogin = false
    @Published var errorMessage: String?

    var onMonitorChanged: (String, Bool) -> Void = { _, _ in }
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
    var onSpeedChanged: (TransitionSpeed) -> Void = { _ in }
    var onLoginChanged: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onQuit: () -> Void = {}

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
                Button(action: model.onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close dashboard")
            }.padding(16)
            Text(model.watchdogStatus).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
            Picker("Controls", selection: $model.tab) {
                ForEach(DashboardTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("System controls require the recovery watchdog. Display changes pause Space interception; unconfirmed changes restore after 20 seconds.")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    if let error = model.errorMessage {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    switch model.tab {
                    case .monitors: monitors
                    case .bluetooth: bluetooth
                    case .spaces: spaces
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

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var monitors: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Displays", detail: "Blue means enabled. Disabling a screen removes it from the desktop.")
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
            arrangementPreview
            card {
                ForEach(model.monitors, id: \.uuid) { monitor in
                    HStack(spacing: 10) {
                        Image(systemName: monitor.isBuiltIn ? "laptopcomputer" : "display")
                            .frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.name).font(.system(size: 13, weight: .medium))
                            Text(monitor.isMain ? "Main display" : monitor.enabled ? "Enabled" : "Disabled")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BlueSwitch(label: "\(monitor.name) enabled", isOn: Binding(
                            get: { monitor.enabled }, set: { model.onMonitorChanged(monitor.uuid, $0) }))
                            .disabled(model.displaySettling || model.monitorBusy || !model.displaySupported || monitor.id == nil || (monitor.enabled && model.activeMonitorCount <= 1))
                    }
                    if monitor.uuid != model.monitors.last?.uuid { Divider() }
                }
            }
            if model.monitorBusy { ProgressView("Applying display change…").controlSize(.small) }
            if model.displaySettling { Text("Waiting for display connections to settle…").font(.caption).foregroundStyle(.secondary) }
            Button(model.pendingArrangement ? "Restore previous layout" : "Enable all disabled displays", action: model.onRestoreAll)
                .disabled(model.displaySettling || model.monitorBusy || (model.disabledMonitorCount == 0 && !model.pendingArrangement))
            Text("The last usable display is protected. Quit restores screens disabled by this app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var arrangementPreview: some View {
        let selected = model.monitors.first { $0.uuid == previewMonitor && $0.enabled }
        let proposal = selected.flatMap { model.layoutPreviews[$0.uuid] }
        let busy = model.displaySettling || model.monitorBusy
        return card {
            HStack {
                Label("Smart arrangement", systemImage: "rectangle.3.group").font(.headline)
                Spacer()
                Text("Automatic").font(.caption2).foregroundStyle(.blue)
            }
            Text("Click a screen to preview turning it off. Nothing changes until you apply.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Arrange displays…", action: model.onArrangeDisplays)
                .disabled(busy || !model.displaySupported || model.disabledMonitorCount > 0 || model.pendingArrangement || model.currentLayout.count < 2)
            Text(model.disabledMonitorCount > 0 ? "Turn all screens on to edit the full desk layout." : "Arrange displays opens the drag-and-drop editor.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Current layout").font(.caption).bold()
            MonitorLayoutMap(positions: model.currentLayout, monitors: model.monitors,
                             selected: selected?.uuid, onSelect: { previewMonitor = $0 })
                .disabled(busy)
            if let selected {
                HStack {
                    Text("Without \(selected.name)").font(.caption).bold()
                    Spacer()
                    Button("Cancel") { previewMonitor = nil }.controlSize(.small)
                }
                if let proposal {
                    MonitorLayoutMap(positions: proposal, monitors: model.monitors)
                    Text("Remaining screens close the gap. Connected screens keep their alignment.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Apply — turn off \(selected.name)") {
                        model.onMonitorChanged(selected.uuid, false)
                        previewMonitor = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !model.displaySupported || !model.countdowns.isEmpty)
                    Text("Restores after 20 seconds unless you choose Keep disabled.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(model.activeMonitorCount <= 1 ? "The last usable screen cannot be turned off." :
                         "No reliable preview for this arrangement. Check display mirroring, connections, and resolution.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Turning screens back on restores their saved positions. The switches below apply changes directly.")
                    .font(.caption2).foregroundStyle(.secondary)
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
                Text("Checks every 5 seconds. Pausing keeps your device selections.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.bluetoothPermissionRequired {
                    Button("Allow Bluetooth access…", action: model.onBluetoothAccessRequested)
                    Text("macOS permission is separate from the radio being on. Rebuilt ad-hoc apps may need permission granted again.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.bluetoothRadioOn == false {
                    Button("Turn Bluetooth on", action: model.onBluetoothPowerOn).disabled(model.bluetoothManualBusy)
                }
                if model.legacyServicePresent {
                    Button("Take over existing service…") { showLegacyWarning = true }.disabled(model.bluetoothBusy)
                }
            }
            heading("Devices to reconnect", detail: "The blue switch means auto-reconnect—not connected right now. Connect / Disconnect is a separate, one-time action.")
            card {
                HStack {
                    Text("Paired device").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Auto-reconnect").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.devices, id: \.address) { device in
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
                    if device.address != model.devices.last?.address { Divider() }
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

    private var spaces: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Desktop Spaces", detail: "Speed up trackpad swipes between desktops. This does not disable all macOS animations.")
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fast Space switching").font(.headline)
                        Text(!model.spacesAvailable ? "Waiting for watchdog or display changes" : model.spacesPermission ? "Accessibility permission granted" : "Accessibility permission required")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    BlueSwitch(label: "Enable fast Space switching", isOn: Binding(
                        get: { model.spacesEnabled }, set: model.onSpacesChanged))
                        .disabled(!model.spacesAvailable)
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
                    Text("Grant permission to Fix macOS, then turn this switch on. Monitors and Bluetooth do not require it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
