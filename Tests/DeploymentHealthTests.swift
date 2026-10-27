import AppKit
import IOKit.pwr_mgt

private final class DeploymentPowerBackend: PowerAssertionBackend {
    var releases = 0
    func create(display: Bool, timeout: TimeInterval) throws -> IOPMAssertionID { 1 }
    func setTimeout(_ id: IOPMAssertionID, seconds: TimeInterval) throws {}
    func release(_ id: IOPMAssertionID) throws { releases += 1 }
}

private final class DeploymentReplyProbe: NSObject {
    var replies: [DeploymentHealth] = []
    @objc func receive(_ notification: Notification) {
        guard let text = notification.userInfo?["report"] as? String,
              let value = try? JSONDecoder().decode(DeploymentHealth.self, from: Data(text.utf8)) else { return }
        replies.append(value)
    }
}

private func runDeploymentEndpointTests() {
    let center = DistributedNotificationCenter.default()
    let probe = DeploymentReplyProbe()
    let nonce = UUID().uuidString
    var blocked = true
    var quits = 0
    let endpoint = DeploymentEndpoint(snapshot: {
        DeploymentHealth(session: "fixture", revision: "fixture", bundlePath: "/isolated", blockers: [], checks: ["watchdog": "ready"], configurationHash: "fixture")
    }, prepareQuit: { blocked ? ["Active session"] : [] }, terminate: { quits += 1 })
    center.addObserver(probe, selector: #selector(DeploymentReplyProbe.receive(_:)), name: DeploymentEndpoint.response, object: nonce)
    defer { center.removeObserver(probe) }
    func send(_ action: String, expired: Bool = false) {
        center.postNotificationName(DeploymentEndpoint.request, object: nonce,
            userInfo: ["pid": String(ProcessInfo.processInfo.processIdentifier), "action": action,
                       "expires": String(Date().addingTimeInterval(expired ? -1 : 10).timeIntervalSince1970)], deliverImmediately: true)
        let count = probe.replies.count
        let deadline = Date().addingTimeInterval(expired ? 0.2 : 2)
        while probe.replies.count == count && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    send("status")
    expect(probe.replies.last?.session == "fixture" && quits == 0, "Live deployment status answers the nonce without requesting quit")
    send("quit")
    expect(probe.replies.last?.blockers == ["Active session"] && quits == 0, "Live deployment endpoint reports a veto without terminating")
    blocked = false
    send("quit", expired: true)
    expect(quits == 0, "Expired update requests cannot terminate the GUI after the client gives up")
    send("quit")
    expect(quits == 1 && probe.replies.last?.blockers.isEmpty == true, "Approved endpoint request replies before invoking normal host termination")
    withExtendedLifetime(endpoint) {}
}

/// Real process-boundary persistence check, restricted to disposable preference domains.
func runDeploymentRestartFixture(mode: String, suite: String) throws {
    guard suite.hasPrefix("better-macos.deployment-fixture."), let defaults = UserDefaults(suiteName: suite) else {
        throw ToggleError(message: "Invalid isolated restart fixture suite")
    }
    let model = DashboardModel(); model.enabledModules = []
    let store = UISettingsStore(defaults: defaults)
    if mode == "write" {
        for module in AppModule.allCases { defaults.set(false, forKey: "modules.\(module.rawValue)") }
        var config = LinkRoutingConfig()
        config.aliases = ["work": "com.google.Chrome:Profile 1"]
        config.rules = [LinkRule(pattern: "work.example", target: "com.google.Chrome:Profile 1", destinationAlias: "work")]
        defaults.set(try JSONEncoder().encode(config), forKey: LinksModule.configKey)
        store.save(WidgetLayout(entries: [WidgetEntry(.clipboard), WidgetEntry(.keepAwake)]))
        let draft = SetupDraft(current: model, defaults: defaults)
        draft.step = .widgets; draft.windowsShortcuts = true; draft.saveForLater()
        guard defaults.synchronize() else { throw ToggleError(message: "Fixture flush failed") }
    } else if mode == "read" {
        guard let data = defaults.data(forKey: LinksModule.configKey) else { throw ToggleError(message: "Rules lost across restart") }
        let config = try JSONDecoder().decode(LinkRoutingConfig.self, from: data)
        let draft = SetupDraft(current: model, defaults: defaults); draft.resumeCheckpoint()
        guard config.aliases["work"] == "com.google.Chrome:Profile 1", config.rules.first?.destinationAlias == "work",
              store.loadLayout(modules: []).entries.map(\.known) == [.clipboard, .keepAwake],
              draft.step == .widgets, draft.windowsShortcuts, ModuleSettings(defaults: defaults).enabled.isEmpty else {
            throw ToggleError(message: "Saved choices or draft changed across process restart")
        }
    } else { throw ToggleError(message: "Unknown fixture mode") }
    print(DeploymentHealth.configurationHash(defaults))
}

private func runDeploymentProcessRestartTests() {
    let suite = "better-macos.deployment-fixture.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    func child(_ mode: String) -> String? {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--deployment-restart-fixture", mode, suite]
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
    let written = child("write")
    expect(written != nil && written == child("read"), "Separate processes preserve aliases, widget order, module choices and staged setup without replaying Apply")
}

func runDeploymentHealthTests() {
    _ = NSApplication.shared
    runDeploymentEndpointTests()
    runDeploymentProcessRestartTests()
    expect(UpdateSessionPolicy().blockers.isEmpty, "Idle update policy permits deployment")
    for policy in [UpdateSessionPolicy(busy: true), UpdateSessionPolicy(keepAwake: true), UpdateSessionPolicy(mouseOverride: true),
                   UpdateSessionPolicy(displayRecovery: true), UpdateSessionPolicy(volatileClipboard: true), UpdateSessionPolicy(clipboardRecording: true),
                   UpdateSessionPolicy(unsavedRules: true), UpdateSessionPolicy(transientUI: true), UpdateSessionPolicy(browserChange: true), UpdateSessionPolicy(audioOverride: true), UpdateSessionPolicy(unsavedWidgets: true)] {
        expect(!policy.blockers.isEmpty, "Transient or unrecovered session defers updates instead of losing state")
    }
    let suite = "better-macos.deployment-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for module in AppModule.allCases { defaults.set(false, forKey: "modules.\(module.rawValue)") }
    defaults.set(try? JSONEncoder().encode(LinkRoutingConfig()), forKey: "links.config")
    UISettingsStore(defaults: defaults).save(WidgetLayout(entries: [WidgetEntry(.clipboard), WidgetEntry(.keepAwake)]))
    let hash = DeploymentHealth.configurationHash(defaults)
    defaults.set(Data("runtime heartbeat".utf8), forKey: "modules.runtimeStatus")
    expect(DeploymentHealth.configurationHash(defaults) == hash, "Restart digest excludes changing runtime status")
    defaults.set(true, forKey: "windows.shortcuts")
    expect(DeploymentHealth.configurationHash(defaults) != hash, "Restart digest detects changed saved shortcut choices")
    // A new host uses the same isolated preferences; no live device owners start.
    let model = DashboardModel()
    model.enabledModules = []
    let power = DeploymentPowerBackend()
    let awake = KeepAwakeModule(defaults: defaults, backend: power, automaticUpdates: false, runningApps: { [:] }, processInstances: { [:] })
    let host = AppDelegate(model: model, preferences: defaults, makeKeepAwake: { awake }, presentWindow: { _ in }, displayRecoveryPending: { false })
    model.onRunSetup()
    host.setupSession?.step = .widgets
    expect(host.prepareForUpdate().isEmpty, "Update preparation checkpoints an idle setup draft")
    let checkpoint = defaults.data(forKey: "ui.setup.draft.v1")
    expect(checkpoint != nil && host.setupSession?.allowClose() == true, "Prepared setup survives native close handling")
    let hashAfterFlush = DeploymentHealth.configurationHash(defaults)
    let reloadedDefaults = UserDefaults(suiteName: suite)!
    let next = SetupDraft(current: model, defaults: reloadedDefaults)
    next.resumeCheckpoint()
    expect(next.step == .widgets, "Fresh setup owner resumes the pre-update step")
    expect(DeploymentHealth.configurationHash(reloadedDefaults) == hashAfterFlush, "Fresh owner preserves saved aliases, widgets, choices and checkpoint")
    model.monitorBusy = true
    expect(!host.prepareForUpdate().isEmpty, "Live host refuses update preparation during a display operation")
    expect(host.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Update rechecks sessions at the actual quit boundary before touching hardware")
    model.monitorBusy = false
    model.onModuleChanged(.keepAwake, true)
    model.onKeepAwakeStart()
    expect(awake.active && !host.prepareForUpdate().isEmpty && power.releases == 0, "Actual host defers updates without releasing an active injected Keep awake assertion")
    model.onKeepAwakeStop()
    expect(!awake.active && host.prepareForUpdate().isEmpty, "Ending the session permits update preparation")
    model.popupWidgetEditor.begin(WidgetLayout())
    expect(!host.prepareForUpdate().isEmpty, "Actual host preserves the open widget-editing session")
    model.popupWidgetEditor.cancel()
    let source = SourceInstallation(revision: String(repeating: "a", count: 40), sourceDirectory: "/source with spaces", destination: "/Applications/Better macOS.app", localDevelopment: true)
    let script = try? source.updateScript(revision: String(repeating: "b", count: 40))
    expect(script?.contains("scripts/deploy.py") == true && script?.contains("--revision") == true && script?.contains("curl") == false,
           "Managed development builds update their exact checkout through guarded deployment")
    withExtendedLifetime(host) {}
}
