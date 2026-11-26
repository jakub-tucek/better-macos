import AppKit
import Carbon.HIToolbox
import SwiftUI

enum ScreenshotsFeatureTests: FeatureTestSuite {
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("better-macos.screenshots.\(UUID().uuidString)", isDirectory: true)
        ShotRecentCaptures.folderOverride = folder
        defer {
            ShotRecentCaptures.flush()
            ShotRecentCaptures.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        runScreenshotCoreChecks()
        MainActor.assumeIsolated { runScreenshotsOwnerTests() }
    }

    static func render(directory: String?) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("better-macos.screenshots.\(UUID().uuidString)", isDirectory: true)
        ShotRecentCaptures.folderOverride = folder
        let suite = "better-macos.screenshots-fixtures.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            ShotRecentCaptures.flush()
            ShotRecentCaptures.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        try MainActor.assumeIsolated {
            let fixture = ScreenshotsFixture(defaults: defaults)
            let model = DashboardModel(); model.enabledModules = [.screenshots]; model.settingsGroup = .screenshots; model.watchdogReady = true
            model.featureOwners = FeatureOwners(context: FeatureContext(preferences: defaults, acceptsActions: { true }),
                                                overrides: [.screenshots: { _ in fixture.owner }], registrations: [ScreenshotsFeatureRegistration.self])
            for dark in [false, true] {
                for access in [true, false] {
                    fixture.access = access
                    fixture.owner.stop(); fixture.owner.start()
                    try renderFeatureFixture(SettingsView(model: model), name: "screenshots-\(access ? "ready" : "access")", directory: directory, dark: dark)
                }
                fixture.access = true
                fixture.owner.stop(); fixture.owner.start()
                try renderFeatureFixture(SettingsView(model: model), name: "screenshots-ready", directory: directory, dark: dark, width: 680)
            }
            fixture.owner.stop()
        }
    }
}

/// Records registrations instead of grabbing global shortcuts.
final class FakeShotHotKeys: ShotHotKeyBinding {
    var registered: [ShotHotKeyAction: ShotHotKey] = [:]
    var handlers: [ShotHotKeyAction: () -> Void] = [:]
    var refuse: Set<ShotHotKeyAction> = []
    var unregisterCount = 0
    func register(_ action: ShotHotKeyAction, key: ShotHotKey, handler: @escaping () -> Void) -> Bool {
        guard !refuse.contains(action) else { return false }
        registered[action] = key
        handlers[action] = handler
        return true
    }
    func unregisterAll() { registered = [:]; handlers = [:]; unregisterCount += 1 }
}

/// Counts capture requests; returns no displays so no overlay or alert appears.
@MainActor
final class FakeShotCaptureSource: ShotCaptureSource {
    var calls = 0
    func captureDisplays() async throws -> [ShotDisplayCapture] { calls += 1; return [] }
}

@MainActor
final class ScreenshotsFixture {
    let binding = FakeShotHotKeys()
    let source = FakeShotCaptureSource()
    var access = true
    var admitted = true
    let owner: ScreenshotsModule
    init(defaults: UserDefaults) {
        owner = ScreenshotsModule(defaults: defaults, binding: binding)
        owner.captureSource = source
        owner.invisibleForTesting = true
        owner.screenAccess = { [unowned self] in access }
        owner.acceptsActions = { [unowned self] in admitted }
    }
}

private func drainMain() {
    for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

func runScreenshotCoreChecks() {
    ScreenshotCoreChecks.testRectStrokeLandsAtTopLeftOrigin()
    ScreenshotCoreChecks.testCropChangesOutputSizeAndOffsetsAnnotations()
    ScreenshotCoreChecks.testUndoRedo()
    ScreenshotCoreChecks.testTextDrawsUprightInsideItsBounds()
    ScreenshotCoreChecks.testBlurDestroysDetail()
    ScreenshotCoreChecks.testSpotlightDimsOutsideOnly()
    ScreenshotCoreChecks.testMeasureSnapsToAxis()
    ScreenshotCoreChecks.testHandleResizeKeepsOppositeCorner()
    ScreenshotCoreChecks.testHitTesting()
    ScreenshotCoreChecks.testCounterNumbersIncrement()
    ScreenshotCoreChecks.testCollageHorizontalLayoutAndGap()
    ScreenshotCoreChecks.testCollageGrid()
    ScreenshotCoreChecks.testAppendToCollageBakesAnnotationsAndUndoes()
    ScreenshotCoreChecks.testBeautifyOutputAndCorners()
    ScreenshotCoreChecks.testBeautifyDoesNotBlackenTransparentContent()
    ScreenshotCoreChecks.testCollageDropsBeautifyAfterBakingIt()
    ScreenshotCoreChecks.testRecentDocumentRoundTripsEveryField()
    ScreenshotCoreChecks.testRecentPruningRemovesSidecars()
    ScreenshotCoreChecks.testPNGRoundTripPreservesPixelsAndScale()
}

@MainActor
func runScreenshotsOwnerTests() {
    let suite = "better-macos.screenshots-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    // Shortcut parsing
    expect(ShotHotKey.from(keyCode: UInt16(kVK_ANSI_3), flags: [.shift], characters: "3") == nil, "Screenshots rejects Shift-only shortcuts")
    let parsed = ShotHotKey.from(keyCode: UInt16(kVK_ANSI_1), flags: [.option, .shift], characters: "1")
    expect(parsed == .defaultFullscreen, "Screenshots builds Carbon modifiers and label from a key press")

    // The Carbon handler must leave other features' hot keys (Windows 'WINS', Clipboard 'CLIP') unhandled.
    let carbon = CarbonShotHotKeys()
    expect(!carbon.handle(EventHotKeyID(signature: 0x434C4950, id: 1)), "Screenshots hot key handler ignores Clipboard's signature")
    expect(!carbon.handle(EventHotKeyID(signature: 0x57494E53, id: 1)), "Screenshots hot key handler ignores Windows' signature")
    expect(!carbon.handle(EventHotKeyID(signature: CarbonShotHotKeys.signature, id: 1)), "Screenshots hot key handler ignores unregistered ids")

    // Registration and owner identity
    let fixture = ScreenshotsFixture(defaults: defaults)
    let owner = fixture.owner
    let owners = FeatureOwners(context: FeatureContext(preferences: defaults, acceptsActions: { true }),
                               overrides: [.screenshots: { _ in owner }], registrations: [ScreenshotsFeatureRegistration.self])
    expect(owners.owner(.screenshots, as: ScreenshotsModule.self) === owner, "Screenshots registers one independent owner")
    expect(ScreenshotsFeatureRegistration.definitions.map(\.module) == [.screenshots] && AppModule.screenshots.rawValue == "screenshots",
           "Screenshots keeps a stable persisted module id")
    expect(ScreenshotsFeatureRegistration.widgets.first?.suggested == false, "Screenshots widget is optional, not suggested")

    // Inactive owners neither register shortcuts nor capture.
    expect(fixture.binding.registered.isEmpty && !owner.active, "Screenshots registers no shortcuts before enable")
    owner.captureArea()
    owner.captureFullscreen()
    drainMain()
    expect(fixture.source.calls == 0, "Screenshots ignores capture requests while disabled")

    owners.reconcile(enabled: [.screenshots])
    expect(owner.active && fixture.binding.registered.count == 3, "Screenshots registers its three shortcuts on enable")
    expect(fixture.binding.registered[.area] == .defaultArea && fixture.binding.registered[.reopen] == .defaultReopen, "Screenshots uses Shottie's default shortcuts")
    owner.start()
    expect(fixture.binding.registered.count == 3 && fixture.binding.unregisterCount == 1, "Screenshots start is idempotent")

    // Shortcut press → capture, subject to host admission.
    fixture.binding.handlers[.area]?()
    drainMain()
    expect(fixture.source.calls == 1, "Screenshots area shortcut starts a capture when admitted")
    owner.stop(); owner.start() // clears the empty selection session left by the fake source
    fixture.admitted = false
    fixture.binding.handlers[.full]?()
    owner.captureAreaDelayed(seconds: 0)
    drainMain()
    expect(fixture.source.calls == 1, "Screenshots shortcuts and delayed capture respect host admission")
    owner.setHotKey(.area, .defaultFullscreen)
    expect(owner.hotKeys[.area] == .defaultArea, "Screenshots refuses shortcut edits without admission")
    fixture.admitted = true

    // Preferences stay namespaced in the injected domain.
    let custom = ShotHotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘4")
    owner.setHotKey(.area, custom)
    expect(owner.hotKeys[.area] == custom && fixture.binding.registered[.area] == custom, "Screenshots re-registers an edited shortcut")
    expect((defaults.dictionary(forKey: "screenshots.hotKey.area")?["label"] as? String) == "⇧⌘4", "Screenshots stores shortcuts under the screenshots. prefix")
    owner.setOption(.copyOnCapture, true)
    owner.setOption(.closeAfterCopy, false)
    expect(defaults.bool(forKey: "screenshots.copyOnCapture") && defaults.object(forKey: "screenshots.closeAfterCopy") as? Bool == false,
           "Screenshots stores options in the injected preferences")
    owner.beginRecordingShortcut()
    expect(fixture.binding.registered.isEmpty, "Screenshots pauses shortcuts while recording a new one")
    owner.endRecordingShortcut()
    expect(fixture.binding.registered.count == 3, "Screenshots resumes shortcuts after recording")
    owner.resetHotKeys()
    expect(owner.hotKeys[.area] == .defaultArea, "Screenshots restores default shortcuts")

    // Busy shortcuts are reported, not fatal.
    fixture.binding.refuse = [.full]
    owner.stop(); owner.start()
    expect(owner.hotKeyFailures == ["⌥⇧1"], "Screenshots reports a shortcut another app holds")
    expect(owner.setupOutcome.description.contains("Shortcut in use"), "Screenshots setup outcome names the busy shortcut")
    fixture.binding.refuse = []

    // Screen Recording access drives setup outcome and status.
    fixture.access = false
    if case .pendingAccess = owner.setupOutcome {} else { expect(false, "Screenshots setup outcome waits for Screen Recording access") }
    expect(!owner.hasScreenAccess, "Screenshots shows missing Screen Recording access")
    fixture.access = true
    owner.stop(); owner.start()
    if case .applied = owner.setupOutcome {} else { expect(false, "Screenshots setup outcome applies with access") }

    // Editor commands answered by the window, since the host menu bar does not carry them.
    let image = ScreenshotCoreChecks.solid(ShotRGBA(hex: 0xFFFFFF), width: 400, height: 300)
    let editor = owner.openEditor(ShotCapturedImage(image: image, scale: 1))
    expect(owner.openEditorCount == 1, "Screenshots opens an editor for an image")
    func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    let window = editor.window as? ShotEditorWindow
    editor.canvas.setZoom(1)
    expect(window?.onKeyEquivalent?(key("=", .command, code: UInt16(kVK_ANSI_Equal))) == true && editor.canvas.zoom > 1, "Screenshots editor zooms in on ⌘=")
    expect(window?.onKeyEquivalent?(key("0", .command, code: UInt16(kVK_ANSI_0))) == true && editor.canvas.zoom == 1, "Screenshots editor resets zoom on ⌘0")
    expect(window?.onKeyEquivalent?(key("c", .command, code: UInt16(kVK_ANSI_C))) == false, "Screenshots editor leaves ⌘C to the host Edit menu")
    expect(window?.onKeyEquivalent?(key("z", .command, code: UInt16(kVK_ANSI_Z))) == false, "Screenshots editor leaves ⌘Z to the host Edit menu")

    // Disable closes windows and releases shortcuts; stopping twice is harmless.
    owners.reconcile(enabled: [])
    expect(!owner.active && owner.openEditorCount == 0 && fixture.binding.registered.isEmpty, "Screenshots disable closes editors and releases shortcuts")
    owners.stop()
    expect(!owner.active, "Screenshots stop is idempotent")
    owner.reopenLast()
    expect(owner.openEditorCount == 0, "Screenshots ignores reopen while disabled")
}
