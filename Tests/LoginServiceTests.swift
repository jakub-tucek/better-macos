import AppKit
import SwiftUI

private final class FakeLoginService: LoginServicing {
    var currentStatus: LoginStatus = .notRegistered
    var status: LoginStatus { reads += 1; return currentStatus }
    var registrationStatus: LoginStatus = .enabled
    var failure: Error?
    var registrations = 0
    var unregistrations = 0
    var settingsOpened = 0
    var reads = 0

    func register() throws {
        registrations += 1
        if let failure { throw failure }
        currentStatus = registrationStatus
    }
    func unregister() throws {
        unregistrations += 1
        if let failure { throw failure }
        currentStatus = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}

func runLoginServiceTests() {
    let suite = "fix-mac-os.login.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { ModuleSettings(defaults: defaults).set(module, enabled: false) }
    let model = DashboardModel()
    let service = FakeLoginService()
    let transactions = HostTransactions()
    service.registrationStatus = .requiresApproval
    let host = AppDelegate(model: model, preferences: defaults,
        displayRecoveryPending: { false }, displaySnapshotRefresh: {},
        transactions: transactions, loginService: service)
    let originalPreferences = defaults.persistentDomain(forName: suite)! as NSDictionary
    expect(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpened == 0,
           "constructing the actual host never changes login registration or opens settings")
    let active = Notification(name: NSApplication.didBecomeActiveNotification)
    for status: LoginStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unknown] {
        service.currentStatus = status
        let reads = service.reads
        host.applicationDidBecomeActive(active)
        expect(model.loginStatus == status && service.reads == reads + 1,
               "activation reads and publishes actual login status \(status)")
        expect(model.launchAtLogin == (status == .enabled || status == .requiresApproval),
               "checkbox represents registration intent for \(status)")
        expect(!model.loginStatus.message.isEmpty, "login status \(status) always has explanatory text")
    }
    expect(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpened == 0,
           "repeated activation only reads status, including denied or unknown states")
    service.currentStatus = .notRegistered
    model.onLoginChanged(true)
    expect(model.launchAtLogin && model.loginStatus == .requiresApproval,
           "actual login callback retains registration intent while approval is pending")
    expect(model.loginStatus.message.contains("Approval required") && model.loginStatus.needsAttention,
           "pending login approval has explicit actionable status")
    expect(service.settingsOpened == 0, "pending approval never opens macOS settings automatically")
    model.onOpenLoginSettings()
    expect(service.settingsOpened == 1, "explicit actual host action opens injected Login Items settings")
    model.onLoginChanged(false)
    expect(!model.launchAtLogin && model.loginStatus == .notRegistered && service.unregistrations == 1,
           "pending approval can be explicitly unregistered through the actual host")

    let unrelatedError = "blueutil timed out (isolated sentinel; never executed)"
    model.errorMessage = unrelatedError
    service.failure = ToggleError(message: "injected registration denial")
    model.onLoginChanged(true)
    expect(model.loginError?.contains("Could not enable launch at login: injected registration denial") == true,
           "actual registration failure has inline login-specific error context")
    expect(!model.launchAtLogin && model.loginStatus == .notRegistered,
           "failed registration reflects the service rather than an optimistic checkbox")
    expect(model.errorMessage == unrelatedError, "login registration failure does not overwrite Bluetooth error")
    service.currentStatus = .requiresApproval
    model.onLoginChanged(true)
    expect(model.launchAtLogin && model.loginStatus == .requiresApproval && model.loginError != nil,
           "a denied retry preserves the service's pending intent and reports its operation error")

    service.failure = nil
    service.registrationStatus = .enabled
    model.onLoginChanged(true)
    expect(model.launchAtLogin && model.loginStatus == .enabled && model.loginError == nil,
           "successful registration checks the box and clears only its own previous error")
    expect(model.errorMessage == unrelatedError, "login success does not clear an unrelated global error")

    service.failure = ToggleError(message: "injected unregister failure")
    model.onLoginChanged(false)
    expect(model.launchAtLogin && model.loginError?.contains("Could not disable launch at login: injected unregister failure") == true,
           "unregister failure retains registered state and provides inline failure")
    service.failure = nil
    model.onLoginChanged(false)
    expect(!model.launchAtLogin && model.loginStatus == .notRegistered && model.loginError == nil,
           "successful unregister clears its own error and reflects unregistered status")
    expect(model.errorMessage == unrelatedError, "unregister never erases unrelated global failure")

    for status: LoginStatus in [.notFound, .unknown] {
        service.registrationStatus = status
        model.onLoginChanged(true)
        expect(model.loginStatus == status && !model.launchAtLogin && model.loginStatus.needsAttention,
               "unexpected registration result \(status) remains truthful and actionable")
        expect(!model.loginStatus.message.contains("Approval required"),
               "unexpected registration result \(status) is not mislabeled pending approval")
    }

    service.currentStatus = .requiresApproval
    host.applicationDidBecomeActive(active)
    let registrationsBeforeApproval = service.registrations
    service.currentStatus = .enabled
    host.applicationDidBecomeActive(active)
    expect(model.loginStatus == .enabled && model.launchAtLogin && service.registrations == registrationsBeforeApproval,
           "returning after external approval refreshes the actual host without registering again")
    service.currentStatus = .requiresApproval
    host.applicationDidBecomeActive(active)
    expect(model.launchAtLogin && model.loginStatus.needsAttention,
           "external revocation refreshes to explicit pending state, not a false disabled choice")

    var actions = HostTransactions.QuitActions(isBusy: { false }, prepareMouse: { false },
        quiesce: {}, prepareClipboard: { true }, needsDisplayRecovery: { false },
        restoreDisplays: { $0(true) }, resumeClipboard: {}, restoreSpacesChoice: {},
        didReopen: {}, didVeto: { _ in })
    let unregistrationsBeforeCancel = service.unregistrations
    _ = transactions.requestQuit(actions, reply: { _ in })
    model.onLoginChanged(false)
    expect(service.unregistrations == unregistrationsBeforeCancel + 1 && !model.launchAtLogin,
           "canceled quit reopens admission for explicit login actions")
    actions.prepareMouse = { true }
    actions.suspendSpaces = { _ in } // Leave this isolated quit attempt draining.
    _ = transactions.requestQuit(actions, reply: { _ in })
    let registrations = service.registrations
    let unregistrations = service.unregistrations
    let opened = service.settingsOpened
    model.loginError = "Earlier login operation failed."
    let error = model.loginError
    model.onLoginChanged(true)
    model.onLoginChanged(false)
    model.onOpenLoginSettings()
    expect(service.registrations == registrations && service.unregistrations == unregistrations && service.settingsOpened == opened,
           "closed host admission blocks both login writes and the settings opener")
    expect(model.loginError == error, "rejected login action does not clear previously published feedback")
    service.currentStatus = .enabled
    host.applicationDidBecomeActive(active)
    expect(model.loginStatus == .enabled && service.registrations == registrations,
           "activation remains read-only even when host admission is closed")
    expect(originalPreferences.isEqual(to: defaults.persistentDomain(forName: suite)!),
           "login lifecycle and action callbacks write no app preferences")
    withExtendedLifetime(host) {}
    runRetainedLoginCallbackTests(defaults: defaults)
}

private func runRetainedLoginCallbackTests(defaults: UserDefaults) {
    let model = DashboardModel()
    let service = FakeLoginService()
    weak var releasedHost: AppDelegate?
    do {
        let host = AppDelegate(model: model, preferences: defaults, loginService: service)
        releasedHost = host
    }
    expect(releasedHost == nil, "login callbacks do not retain the host")
    model.onLoginChanged(true)
    model.onLoginChanged(false)
    model.onOpenLoginSettings()
    expect(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpened == 0,
           "retained login callbacks cannot operate after host teardown")
}

/// Explicit owned-view rendering only: no app delegate, registration, permissions or screen capture.
func renderLoginUIFixtures(directory: String) throws {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for dark in [false, true] {
        for status: LoginStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unknown] {
            let model = DashboardModel()
            model.loginStatus = status
            if status == .notFound { model.loginError = "Could not enable launch at login: Fixture registration failure." }
            let view = NSHostingView(rootView: LoginSettingsView(model: model)
                .padding(24).frame(width: 500, height: 220, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = view.appearance
            window.contentView = view
            for _ in 0..<6 {
                view.layoutSubtreeIfNeeded()
                window.display()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: root.appendingPathComponent("login-\(status)-\(dark ? "dark" : "light").png"))
        }
    }
}
