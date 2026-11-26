import AppKit
import SwiftUI

extension AppModule { static let screenshots = AppModule("screenshots") }
extension DashboardTab { static let screenshots = DashboardTab("Screenshots") }
extension SettingsGroup { static let screenshots = SettingsGroup("Screenshots") }
extension WidgetKind { static let screenshots = WidgetKind("screenshots") }

enum ScreenshotsFeatureRegistration: FeatureRegistration {
    static let order = 130
    static let definitions = [BuiltinFeatureDefinition(module: .screenshots, title: "Screenshots", detail: "Capture an area or screen, annotate, beautify, pin and copy text from screenshots.", feature: .screenshots, settings: .screenshots, settingsOrder: 0, symbol: "camera.viewfinder")]
    static let widgets = [BuiltinWidgetDefinition(kind: .screenshots, module: .screenshots, title: "Screenshots", detail: "Capture an area or screen, or reopen your last capture.", suggested: false)]
    static let settings = [FeatureSettingsDefinition(group: .screenshots, symbol: "camera.viewfinder", summary: "Capture shortcuts, editor output and recent captures.")]
    static let setup: [AppModule: FeatureSetupDescription] = [.screenshots: .init(
        introduction: "Capture an area, a window or a whole screen, then annotate, crop, blur, beautify, pin or copy text from it in a focused editor.",
        effect: "Adds global shortcuts (⇧⌘3 area, ⌥⇧1 screen, ⌥⇧3 reopen last), replacing the macOS ⇧⌘3 shortcut while on. Needs Screen Recording access. The latest 20 captures and their edits stay in Better macOS’s cache.",
        summary: "Global capture shortcuts and an annotation editor; needs Screen Recording access.")]
    static let launchArguments: [String: DashboardTab] = ["--show-screenshots": .screenshots]
    static func makeOwner(_ context: FeatureContext) -> FeatureOwner? {
        MainActor.assumeIsolated {
            // Only the app bundle grabs global shortcuts; isolated test runners get an inert binding.
            let binding: ShotHotKeyBinding = Bundle.main.bundleURL.pathExtension == "app" ? CarbonShotHotKeys() : InertShotHotKeys()
            let owner = ScreenshotsModule(defaults: context.preferences, binding: binding)
            owner.acceptsActions = context.acceptsActions
            return owner
        }
    }
    static func settingsView(model: DashboardModel, feature: DashboardTab, draft: Bool) -> AnyView? {
        guard feature == .screenshots else { return nil }
        if draft { return AnyView(Text("After Finish, allow Screen Recording when asked, then change shortcuts and output in Screenshots settings.")) }
        guard model.enabledModules.contains(.screenshots), let owner = model.featureOwners?.owner(.screenshots, as: ScreenshotsModule.self) else { return AnyView(Text("Screenshots is off.")) }
        return AnyView(ScreenshotsSettingsView(module: owner))
    }
    static func widgetView(model: DashboardModel, entry: WidgetEntry) -> AnyView? {
        guard entry.known == .screenshots, let owner = model.featureOwners?.owner(.screenshots, as: ScreenshotsModule.self) else { return nil }
        return AnyView(ScreenshotsWidgetView(module: owner, expanded: entry.expanded, close: model.onClose, openSettings: { model.onOpenSettings(.screenshots) }))
    }
}

extension ScreenshotsModule: @preconcurrency FeatureOwner {
    var module: AppModule { .screenshots }
    func reconcile(enabled: Bool) { if enabled { start() } else { stop() } }
    func stopFeature() { stop() }
    var setupOutcome: FeatureSetupOutcome {
        refresh()
        if !hasScreenAccess { return .pendingAccess("Allow Better macOS in Privacy & Security › Screen & System Audio Recording, then capture again.") }
        if !hotKeyFailures.isEmpty { return .applied("Shortcut in use: \(hotKeyFailures.joined(separator: ", ")). Pick another in Screenshots settings.") }
        return .applied("Press \(hotKeys[.area]?.label ?? "the capture shortcut") to capture an area.")
    }
}

// MARK: - Widget

private struct ScreenshotsWidgetView: View {
    @ObservedObject var module: ScreenshotsModule
    let expanded: Bool
    let close: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !module.hasScreenAccess {
                Label("Screen Recording access needed", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            AppActionRow(title: "Capture area", symbol: "viewfinder", shortcut: module.hotKeys[.area]?.label ?? "") {
                close(); module.captureAreaAfterHiding()
            }
            AppActionRow(title: "Capture screen", symbol: "macwindow", shortcut: module.hotKeys[.full]?.label ?? "") {
                close(); module.captureScreenAfterHiding()
            }
            if module.canReopen {
                AppActionRow(title: "Reopen last capture", symbol: "arrow.uturn.backward", shortcut: module.hotKeys[.reopen]?.label ?? "") {
                    close(); module.reopenLast()
                }
            }
            if expanded {
                AppActionRow(title: "Capture area in 3 seconds", symbol: "timer") { close(); module.captureAreaDelayed() }
                AppActionRow(title: "Open image…", symbol: "photo") { close(); module.chooseImages() }
            }
            AppActionRow(title: "Screenshot settings", symbol: "arrow.up.right", action: openSettings)
        }.onAppear(perform: module.refresh)
    }
}

// MARK: - Settings

struct ScreenshotsSettingsView: View {
    @ObservedObject var module: ScreenshotsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            status
            section {
                Text("Capture").font(AppStyle.sectionTitle)
                AppActionRow(title: "Capture area", symbol: "viewfinder", shortcut: module.hotKeys[.area]?.label ?? "") { module.captureArea() }
                AppActionRow(title: "Capture screen", symbol: "macwindow", shortcut: module.hotKeys[.full]?.label ?? "") { module.captureFullscreen() }
                AppActionRow(title: "Capture area in 3 seconds", symbol: "timer") { module.captureAreaDelayed() }
                AppActionRow(title: "Open image…", symbol: "photo") { module.chooseImages() }
                AppActionRow(title: "New collage from files…", symbol: "square.grid.2x2") { module.chooseCollage(fromRecent: false) }
                AppActionRow(title: "New collage from recent captures…", symbol: "square.grid.2x2.fill") { module.chooseCollage(fromRecent: true) }
            }
            shortcuts
            output
            recent
            section {
                DisclosureGroup("Editor keys") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.editorKeys, id: \.0) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.0).frame(width: 110, alignment: .leading)
                                Text(row.1).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 8).textSelection(.enabled)
                }
            }
        }.onAppear(perform: module.refresh)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                module.refresh()
            }
    }

    private var status: some View {
        section {
            HStack(alignment: .top, spacing: 12) {
                AppSymbolBadge(symbol: "camera.viewfinder")
                if module.hasScreenAccess {
                    Label("Ready to capture", systemImage: "checkmark.circle.fill").font(.headline)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording access needed").font(.headline)
                        Text("Request access to capture your screen. If access was previously denied, enable Better macOS in Privacy settings. macOS may ask you to reopen the app.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if !module.hasScreenAccess {
                HStack {
                    Button("Request access", action: module.requestScreenRecordingAccess).buttonStyle(.borderedProminent)
                    Button("Open Privacy settings", action: module.openScreenRecordingSettings)
                    Button("Check again", action: module.refresh)
                }
            }
            if !module.hotKeyFailures.isEmpty {
                Label("Shortcut in use by another app: \(module.hotKeyFailures.joined(separator: ", ")). Pick another below.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcuts: some View {
        section {
            Text("Shortcuts").font(AppStyle.sectionTitle)
            ForEach(ShotHotKeyAction.allCases, id: \.self) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    ShotShortcutField(module: module, action: action)
                }
            }
            Text("⇧⌘3 replaces the macOS screenshot shortcut while Screenshots is on. Click a shortcut, then press the new keys; Esc cancels.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Restore default shortcuts", action: module.resetHotKeys).controlSize(.small)
        }
    }

    private var output: some View {
        section {
            Text("After capturing").font(AppStyle.sectionTitle)
            ForEach(ShotOption.allCases, id: \.self) { option in
                Toggle(option.title, isOn: Binding(get: { module.option(option) }, set: { module.setOption(option, $0) }))
            }
            HStack {
                Text("Save (⌘S) to")
                Spacer()
                Text(module.saveFolder.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(module.saveFolder.path)
                Button("Choose…", action: module.chooseSaveFolder).controlSize(.small)
            }
        }
    }

    private var recent: some View {
        section {
            HStack {
                Text("Recent captures").font(AppStyle.sectionTitle)
                Spacer()
                Button("Show in Finder", action: module.revealRecentFolder).controlSize(.small)
            }
            if module.recent.isEmpty {
                Text("None yet. The latest 20 captures and their edits are kept here.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(module.recent, id: \.self) { url in
                    Button { module.reopen(url) } label: {
                        HStack {
                            Image(systemName: ShotRecentCaptures.hasEdits(url) ? "pencil.circle" : "photo").foregroundStyle(.secondary)
                            Text(ScreenshotsModule.displayName(url))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Reopen capture from \(ScreenshotsModule.displayName(url))\(ShotRecentCaptures.hasEdits(url) ? ", edited" : "")")
                }
            }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).modifier(AppSurface())
    }

    static let editorKeys: [(String, String)] = [
        ("Selecting", "Drag a box · click a window · Return whole display · hold Space to move · Esc cancel"),
        ("Tools", "R box · T text · A arrow · V select · C crop · M measure · B pixelate · O ellipse · L line · P pen · H highlighter · N step · S spotlight"),
        ("Editing", "⌘Z ⇧⌘Z · Delete · arrows nudge · [ ] size · Shift constrains · double-click text"),
        ("Output", "⌘C copy · ⌘S save · ⇧⌘S save as · ⌘P pin · ⌘R retake · ⇧⌘C copy text (OCR)"),
        ("Beautify", "F toggles backdrop, padding and rounded corners"),
        ("Color", "Tab copies the hex under the cursor · I uses it"),
        ("Zoom", "⌘= ⌘- ⌘0 ⌘9 · pinch"),
    ]
}

/// Click, then press the new shortcut. Current shortcuts are paused while listening.
private struct ShotShortcutField: View {
    @ObservedObject var module: ScreenshotsModule
    let action: ShotHotKeyAction
    @State private var monitor: Any?

    var body: some View {
        Button { monitor == nil ? start() : finish() } label: {
            Text(monitor == nil ? (module.hotKeys[action]?.label ?? "") : "Press keys…")
                .font(.system(.body, design: .monospaced)).frame(minWidth: 96)
        }
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(monitor == nil ? (module.hotKeys[action]?.label ?? "None") : "Listening")
        .onDisappear(perform: finish)
    }

    private func start() {
        module.beginRecordingShortcut()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { finish(); return nil } // Esc
            guard let key = ShotHotKey.from(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) else {
                NSSound.beep()
                return nil
            }
            module.setHotKey(action, key)
            finish()
            return nil
        }
    }

    private func finish() {
        guard let current = monitor else { return }
        NSEvent.removeMonitor(current)
        monitor = nil
        module.endRecordingShortcut()
    }
}
