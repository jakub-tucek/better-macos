import AppKit
import SwiftUI

// A separate app identity and unique preference suite. No production AppDelegate,
// device owners, global shortcuts, permission prompts or real window moves.
final class HarnessEnvironment: ObservableObject {
    @Published var accessibility = false
    @Published var bluetooth = false
    var accessRequests = 0
    @Published var lastAction = ""
}

final class PreviewBrowserBackend: LinkBrowserBackend {
    var requests = 0
    func discover() -> LinkDiscovery {
        LinkDiscovery(destinations: [
            LinkDestination(id: "com.apple.Safari", name: "Safari", appPath: "/simulated/Safari.app"),
            LinkDestination(id: "com.google.Chrome", name: "Chrome", appPath: "/simulated/Chrome.app"),
            LinkDestination(id: "com.google.Chrome:Default", name: "Chrome · Personal", appPath: "/simulated/Chrome.app", profile: "Default"),
            LinkDestination(id: "com.google.Chrome:Profile 1", name: "Chrome · Work", appPath: "/simulated/Chrome.app", profile: "Profile 1")], profileBrowsers: ["com.google.Chrome"])
    }
    func systemFallback() -> LinkDestination? { discover().destinations.first }
    func open(_ url: URL, in destination: LinkDestination, completion: @escaping (Error?) -> Void) {
        requests += 1; completion(ToggleError(message: "Preview only: no browser opened."))
    }
    func requestProfileAccess(browser: String) -> Bool { requests += 1; return false }
    func isDefaultBrowser() -> Bool { false }
    func makeDefaultBrowser(completion: @escaping (Error?) -> Void) {
        requests += 1; completion(ToggleError(message: "Preview only: default browser unchanged."))
    }
    func relinquishDefaultBrowser(to destination: LinkDestination, completion: @escaping (Error?) -> Void) { requests += 1; completion(nil) }
}

struct HarnessView: View {
    @ObservedObject var environment: HarnessEnvironment
    let model: DashboardModel
    @ObservedObject var draft: SetupDraft
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TEST HOST · simulated permissions").font(.caption.bold())
                Toggle("Accessibility", isOn: $environment.accessibility)
                Toggle("Bluetooth", isOn: $environment.bluetooth)
                Button("Return to app") { NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) }
            }.padding(12)
            if !environment.lastAction.isEmpty { Text(environment.lastAction).font(.caption).padding(.bottom, 8) }
            SetupWizard(model: model, draft: draft, close: close)
        }
    }
}

final class UIHarness {
    let environment = HarnessEnvironment()
    let model = DashboardModel()
    let defaults: UserDefaults
    let suite = "io.github.jakub-tucek.better-macos.ui-harness.\(UUID().uuidString)"
    let window: NSWindow
    var draft: SetupDraft!
    var closed = false
    var checks = 0
    var finishPending: (() -> Void)?
    var openedSettings: SettingsGroup?
    let previewBrowser = PreviewBrowserBackend()
    var previewLinks: LinksModule?

    init() {
        defaults = UserDefaults(suiteName: suite)!
        model.enabledModules = [.windows, .bluetooth, .arrangement, .quitGuard, .spaces]
        model.watchdogReady = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 840), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Better macOS UI Test Host"
        model.onAccessibilitySettings = { [weak self] in
            self?.environment.accessRequests += 1
            self?.environment.lastAction = "Simulated Accessibility request. Toggle Accessibility above, then Return to app."
        }
        model.onOpenSettings = { [weak self] in
            self?.openedSettings = $0
            self?.environment.lastAction = "Would open \($0?.rawValue ?? "General") settings."
        }
        model.onFinishSetup = { [weak self] draft, completion in
            let finish = {
                draft.outcomes[.windows] = .failed("Simulated shortcut conflict. Retry in Window settings.")
                completion(["Simulated apply only; no system settings changed."])
            }
            if CommandLine.arguments.contains("--interactive") { finish() }
            else { self?.finishPending = finish }
        }
        openSetup()
    }

    func openSetup() {
        closed = false
        draft = SetupDraft(current: model, defaults: defaults)
        draft.onRetryPermissions = { [weak self] in
            guard let self else { return }
            draft.accessibilityGranted = environment.accessibility
            draft.bluetoothGranted = environment.bluetooth
        }
        draft.onBluetoothPermission = { [weak self] in
            self?.environment.accessRequests += 1
            self?.environment.lastAction = "Simulated Bluetooth request. Toggle Bluetooth above, then Return to app."
        }
        draft.onRetryPermissions()
        window.contentView = NSHostingView(rootView: HarnessView(environment: environment, model: model, draft: draft, close: { [weak self] in
            guard let self, draft.allowClose() else { return }
            closed = true
            if CommandLine.arguments.contains("--interactive") { window.close() }
            else { window.orderOut(nil) }
        }))
        settle()
    }

    func settle() {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    func openLinks() {
        let owner = LinksModule(defaults: defaults, backend: previewBrowser)
        owner.setActive(true); owner.refresh()
        _ = owner.saveRuleText("alias: home -> com.google.Chrome:Default\nalias: work -> com.google.Chrome:Profile 1\n\ngithub.com/my-team -> @work\nyoutube.com -> @home", expected: owner.config.rules, expectedAliases: owner.config.aliases)
        previewLinks = owner
        window.title = "Links preview · isolated settings and simulated browsers"
        window.contentView = NSHostingView(rootView: ScrollView { LinksSettingsView(module: owner).padding(20) })
        settle()
    }

    func elements() -> [AnyObject] {
        var pending: [Any] = [window]
        var visited = Set<ObjectIdentifier>()
        var result: [AnyObject] = []
        while let item = pending.popLast() {
            let object = item as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            pending += object.accessibilityChildren?() ?? []
            if let view = item as? NSView { pending += view.subviews }
            if let window = item as? NSWindow, let view = window.contentView { pending.append(view) }
        }
        return result
    }

    func control(_ id: String) -> AnyObject {
        guard let element = elements().first(where: { $0.accessibilityIdentifier?() == id }) else {
            for element in elements() { print("AX: \(type(of: element)) \(element.accessibilityIdentifier?() ?? "-")") }
            print("FAIL: Missing UI control: \(id)"); fflush(stdout); exit(1)
        }
        return element
    }

    func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
        checks += 1; print("PASS: \(message)")
    }

    func press(_ id: String) {
        let element = control(id)
        check(element.isAccessibilityEnabled?() ?? true, "\(id) is enabled")
        check(element.accessibilityPerformPress?() ?? false, "\(id) performs its native accessibility action")
        settle()
    }

    func run() {
        press("setup.start")
        press("setup.enable")
        check(draft.step == .access(.windows) && control("setup.continue").isAccessibilityEnabled?() == false, "Windows permission gate blocks configuration without Accessibility")
        press("setup.accessibility")
        check(environment.accessRequests == 1, "Permission button reaches the injected boundary")
        environment.accessibility = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        settle()
        press("setup.continue")
        check(draft.step == .configure(.windows), "Returning after simulated grant unlocks the real setup screen")
        press("setup.saveLater")
        check(closed && draft.hasCheckpoint, "Save for later closes without losing the draft")
        openSetup()
        press("setup.resume")
        check(draft.step == .configure(.windows), "Resume returns to the saved screen")
        environment.accessibility = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        settle()
        press("setup.continue")
        check(draft.step == .access(.windows), "Revoked permission sends configuration back to the access gate")
        press("setup.cancel")
        check(closed && !draft.hasCheckpoint, "Cancel discards the draft")
        check(defaults.object(forKey: "windows.shortcuts") == nil && defaults.object(forKey: UISettingsStore.completionKey) == nil, "Navigation never applies feature settings or completes setup")

        environment.accessibility = true; environment.bluetooth = true
        openSetup()
        press("setup.easy")
        press("setup.continue")
        press("setup.continue")
        check(draft.step == .review, "Easy setup reaches review after permission checks and widgets")
        press("setup.finish")
        check(draft.applying && !control("setup.finish").isAccessibilityEnabled(), "Applying disables Finish and prevents duplicate submission")
        draft.back()
        check(draft.step == .review && !draft.cancel(), "Applying refuses navigation and cancellation even outside the UI")
        finishPending?(); finishPending = nil; settle()
        check(draft.step == .results && !draft.applying, "Apply failure reaches an actionable results screen")
        press("setup.review.windows")
        check(openedSettings == .displays, "Failed window setup has a working direct Review link")

        model.windowShortcutIssue = "Shortcuts unavailable. Quit other window managers, then retry."
        var retries = 0
        model.onRetryWindowShortcuts = { [weak model] in retries += 1; model?.windowShortcutIssue = nil }
        model.errorMessage = "Separate retained issue"
        window.contentView = NSHostingView(rootView: SafetyAlerts(model: model).padding(20).frame(width: 640, height: 400, alignment: .topLeading))
        settle()
        _ = control("issues.windowShortcuts")
        check(model.statusNeedsAttention, "Window shortcut conflicts are visible in global alerts and status-icon state")
        press("issues.retryWindowShortcuts")
        check(retries == 1 && model.windowShortcutIssue == nil && model.errorMessage != nil, "Visible retry clears only its own issue")
        check(suite.hasPrefix("io.github.jakub-tucek.better-macos.ui-harness."), "Test host uses a unique isolated preference suite")
        openLinks()
        _ = control("links.rulesText")
        check(previewLinks?.config.aliases.count == 2 && previewBrowser.requests == 0, "Links preview renders actual alias editor with simulated browsers and no OS requests")
        print("\(checks) native UI checks passed; simulated OS boundaries, no live permission grants or window movement.")
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}

final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = HarnessAppDelegate()
app.delegate = delegate
// Ask this test process to materialize its accessibility tree, without granting
// system Accessibility permission or attaching to another application's UI.
_ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: true, with: "AXEnhancedUserInterface")
app.setActivationPolicy(CommandLine.arguments.contains("--interactive") ? .regular : .prohibited)
let harness = UIHarness()
atexit { harness.defaults.removePersistentDomain(forName: harness.suite) }
if CommandLine.arguments.contains("--interactive") {
    if CommandLine.arguments.contains("--links") { harness.openLinks() }
    harness.window.center(); harness.window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    app.run()
} else { harness.run() }
