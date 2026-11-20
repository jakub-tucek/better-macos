import AppKit
import Darwin
import UniformTypeIdentifiers

enum ShotOption: CaseIterable {
    case copyOnCapture, closeAfterCopy, showThumbnail
    var title: String {
        switch self {
        case .copyOnCapture: return "Copy right after capturing"
        case .closeAfterCopy: return "Close the editor after ⌘C"
        case .showThumbnail: return "Show a preview after copying"
        }
    }
}

/// Owns capture sessions, editors, pins, the copy preview and the global shortcuts.
/// Captures and their edits are kept in Recent Captures; disabling closes windows after saving edits.
@MainActor
final class ScreenshotsModule: NSObject, ObservableObject {
    var acceptsActions: () -> Bool = { true }
    var captureSource: ShotCaptureSource = ScreenCaptureKitSource()
    /// Tests skip the permission preflight when using a fake source.
    var requiresPermission = true
    /// Tests: windows exist and handle events but are transparent, click-through and never activate.
    var invisibleForTesting = false
    var screenAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }

    @Published private(set) var active = false
    @Published private(set) var hotKeyFailures: [String] = []
    @Published private(set) var hotKeys: [ShotHotKeyAction: ShotHotKey] = [:]
    @Published private(set) var hasScreenAccess = false
    @Published private(set) var recent: [URL] = []

    private let binding: ShotHotKeyBinding
    private(set) var editors: [ShotEditorWindowController] = []
    private var pins: [ShotPinWindow] = []
    private var session: ShotSelectionSession?
    private var capturing = false
    private var settleBeforeCapture = false
    private var thumbnail: ShotThumbnailPanel?
    private var lastDocument: URL?
    private var previousApp: NSRunningApplication?
    private var delayed: DispatchWorkItem?

    init(defaults: UserDefaults, binding: ShotHotKeyBinding = CarbonShotHotKeys()) {
        ShotPreferences.defaults = defaults
        self.binding = binding
        super.init()
        loadHotKeys()
    }

    // MARK: Lifecycle

    func start() {
        guard !active else { return }
        active = true
        refresh()
        registerHotKeys()
    }

    /// Idempotent. Edits are written to Recent Captures before windows close.
    func stop() {
        delayed?.cancel()
        delayed = nil
        binding.unregisterAll()
        hotKeyFailures = []
        session?.complete(nil)
        session = nil
        capturing = false
        editors.forEach { $0.window?.close() }
        editors = []
        pins.forEach { $0.close() }
        pins = []
        dismissThumbnail()
        ShotRecentCaptures.flush()
        active = false
    }

    func refresh() {
        hasScreenAccess = !requiresPermission || screenAccess()
        recent = Array(ShotRecentCaptures.list().prefix(10))
    }

    private func loadHotKeys() {
        hotKeys = Dictionary(uniqueKeysWithValues: ShotHotKeyAction.allCases.map { ($0, ShotPreferences.hotKey($0)) })
    }

    /// While a shortcut field listens, the current shortcuts must not fire a capture.
    func beginRecordingShortcut() {
        binding.unregisterAll()
    }

    func endRecordingShortcut() {
        if active { registerHotKeys() }
    }

    func setHotKey(_ action: ShotHotKeyAction, _ key: ShotHotKey) {
        guard acceptsActions() else { return }
        ShotPreferences.setHotKey(action, key)
        loadHotKeys()
        if active { registerHotKeys() }
    }

    func setOption(_ option: ShotOption, _ value: Bool) {
        guard acceptsActions() else { return }
        switch option {
        case .copyOnCapture: ShotPreferences.copyOnCapture = value
        case .closeAfterCopy: ShotPreferences.closeAfterCopy = value
        case .showThumbnail: ShotPreferences.showThumbnail = value
        }
        objectWillChange.send()
    }

    func option(_ option: ShotOption) -> Bool {
        switch option {
        case .copyOnCapture: return ShotPreferences.copyOnCapture
        case .closeAfterCopy: return ShotPreferences.closeAfterCopy
        case .showThumbnail: return ShotPreferences.showThumbnail
        }
    }

    func resetHotKeys() {
        guard acceptsActions() else { return }
        ShotHotKeyAction.allCases.forEach { ShotPreferences.setHotKey($0, $0.fallback) }
        loadHotKeys()
        if active { registerHotKeys() }
    }

    private func registerHotKeys() {
        binding.unregisterAll()
        var failures: [String] = []
        for action in ShotHotKeyAction.allCases {
            let key = ShotPreferences.hotKey(action)
            let registered = binding.register(action, key: key) { [weak self] in
                MainActor.assumeIsolated { self?.perform(action) }
            }
            if !registered { failures.append(key.label) }
        }
        hotKeyFailures = failures
    }

    func perform(_ action: ShotHotKeyAction) {
        switch action {
        case .area: captureArea()
        case .full: captureFullscreen()
        case .reopen: reopenLast()
        }
    }

    /// User actions run only while the feature is on and the host accepts actions.
    private var admitted: Bool { active && acceptsActions() }

    // MARK: Capture

    func prepare(_ window: NSWindow) {
        guard invisibleForTesting else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    private func activate() {
        if !invisibleForTesting { NSApp.activate(ignoringOtherApps: true) }
    }

    private func hasPermission() -> Bool {
        refresh()
        if hasScreenAccess { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Screenshots needs Screen Recording access"
        alert.informativeText = "Turn on Better macOS in System Settings › Privacy & Security › Screen & System Audio Recording, then try again. macOS may ask you to reopen Better macOS."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        activate()
        if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
        return false
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Remembers who to hand focus back to, and clears our preview so it isn't in the shot.
    private func prepareForCapture() {
        rememberFrontmostApp()
        if thumbnail != nil {
            dismissThumbnail()
            settleBeforeCapture = true
        }
    }

    private func rememberFrontmostApp() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current { previousApp = front }
    }

    /// Our own windows take a moment to leave the screen; capture only after they have.
    private func waitForOwnWindowsToClear() async {
        guard settleBeforeCapture else { return }
        settleBeforeCapture = false
        CATransaction.flush()
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// For flows that just closed or hid one of our windows, such as the quick-actions popup.
    func captureAreaAfterHiding(completion: ((ShotCapturedImage?) -> Void)? = nil) {
        settleBeforeCapture = true
        captureArea(completion: completion)
    }

    func captureScreenAfterHiding() {
        settleBeforeCapture = true
        captureFullscreen()
    }

    /// Freezes the screen, lets the user draw a box, then opens the editor — or calls `completion` instead.
    func captureArea(completion: ((ShotCapturedImage?) -> Void)? = nil) {
        guard admitted, !capturing, hasPermission() else {
            completion?(nil)
            return
        }
        capturing = true
        prepareForCapture()
        Task { [self] in
            do {
                await waitForOwnWindowsToClear()
                let captures = try await captureSource.captureDisplays()
                guard active else { capturing = false; completion?(nil); return }
                let session = ShotSelectionSession(captures: captures) { [weak self] result in
                    guard let self else { return }
                    self.session = nil
                    self.capturing = false
                    malloc_zone_pressure_relief(nil, 0)
                    if let completion {
                        completion(result)
                    } else if let result {
                        self.didCapture(result)
                    }
                }
                self.session = session
                session.overlayWindows.forEach(prepare)
                activate()
                session.show()
            } catch {
                capturing = false
                completion?(nil)
                showCaptureError(error)
            }
        }
    }

    func captureFullscreen() {
        guard admitted, !capturing, hasPermission() else { return }
        capturing = true
        prepareForCapture()
        Task {
            defer { capturing = false }
            do {
                await waitForOwnWindowsToClear()
                let captures = try await captureSource.captureDisplays()
                let mouse = NSEvent.mouseLocation
                guard active, let capture = captures.first(where: { $0.screen.frame.contains(mouse) }) ?? captures.first else { return }
                didCapture(ShotCapturedImage(image: capture.image, scale: CGFloat(capture.image.width) / capture.screen.frame.width))
            } catch {
                showCaptureError(error)
            }
        }
    }

    func captureAreaDelayed(seconds: TimeInterval = 3) {
        guard admitted else { return }
        delayed?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.captureArea() }
        delayed = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func showCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't capture the screen"
        alert.informativeText = error.localizedDescription
        activate()
        alert.runModal()
    }

    private func didCapture(_ capture: ShotCapturedImage) {
        let url = ShotRecentCaptures.add(capture)
        if ShotPreferences.copyOnCapture { ShotExporter.copy(capture.image, scale: capture.scale) }
        openEditor(capture, documentURL: url)
        refresh()
    }

    @discardableResult
    func openEditor(_ capture: ShotCapturedImage, documentURL: URL? = nil) -> ShotEditorWindowController {
        open(ShotEditorModel(image: capture.image, scale: capture.scale), documentURL: documentURL)
    }

    @discardableResult
    private func open(_ model: ShotEditorModel, documentURL: URL?) -> ShotEditorWindowController {
        let editor = ShotEditorWindowController(model: model, documentURL: documentURL, app: self)
        editor.onClosed = { [weak self] controller in
            guard let self else { return }
            self.lastDocument = controller.documentURL ?? self.lastDocument
            self.editors.removeAll { $0 === controller }
            if self.editors.isEmpty { self.returnFocus() }
            self.refresh()
            // Hand the screenshot's pages back rather than keeping them for the next capture.
            DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
        }
        editors.append(editor)
        activate()
        editor.present()
        return editor
    }

    /// Back to the app you came from, so ⌘V works straight after ⌘C.
    private func returnFocus() {
        guard !invisibleForTesting, !capturing, active else { return }
        previousApp?.activate()
    }

    // MARK: Thumbnail and reopening

    func showThumbnail(_ image: CGImage, documentURL: URL) {
        guard active else { return }
        dismissThumbnail()
        let panel = ShotThumbnailPanel(image: image, onOpen: { [weak self] in
            self?.reopen(documentURL)
        }, makeDragFile: {
            ShotRecentCaptures.load(documentURL).flatMap { state in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Better macOS Screenshot Drag", isDirectory: true)
                    .appendingPathComponent(documentURL.lastPathComponent)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let data = ShotExporter.encode(ShotRenderer.flatten(state), scale: state.scale), (try? data.write(to: url)) != nil else { return nil }
                return url
            }
        })
        panel.onDismissed = { [weak self] closed in
            if self?.thumbnail === closed { self?.thumbnail = nil }
        }
        thumbnail = panel
        prepare(panel)
        panel.present()
    }

    private func dismissThumbnail() {
        thumbnail?.dismiss()
        thumbnail = nil
    }

    /// Opens a stored document with its annotations, or brings it forward if already open.
    func reopen(_ url: URL) {
        guard admitted else { return }
        rememberFrontmostApp()
        dismissThumbnail()
        if let open = editors.first(where: { $0.documentURL == url }) {
            activate()
            open.present()
            return
        }
        guard let state = ShotRecentCaptures.load(url) else { return }
        open(ShotEditorModel(state: state), documentURL: url)
    }

    func reopenLast() {
        guard let url = lastDocument ?? ShotRecentCaptures.list().first else { return }
        reopen(url)
    }

    var canReopen: Bool { lastDocument != nil || !recent.isEmpty }

    func pin(_ capture: ShotCapturedImage) {
        guard admitted else { return }
        let window = ShotPinWindow(capture: capture)
        window.onClosed = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        pins.append(window)
        prepare(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func openImage(at url: URL) {
        guard let loaded = ShotExporter.load(url: url) else { return }
        openEditor(ShotCapturedImage(image: loaded.image, scale: loaded.scale))
    }

    func chooseImages() {
        guard admitted else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        activate()
        if panel.runModal() == .OK, admitted { panel.urls.forEach(openImage(at:)) }
    }

    func chooseCollage(fromRecent: Bool) {
        guard admitted else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = fromRecent ? ShotRecentCaptures.folder : nil
        panel.message = "Pick the images to arrange into a grid"
        activate()
        guard panel.runModal() == .OK, admitted else { return }
        openCollage(urls: panel.urls)
    }

    func openCollage(urls: [URL]) {
        // Recent captures come in with their annotations.
        let states = urls.compactMap { ShotRecentCaptures.load($0) }
        let scale = states.map(\.scale).max() ?? 1
        guard let collage = ShotCollage.stitch(states.map { ShotRenderer.flatten($0) }, layout: .grid(columns: ShotCollage.gridColumns(for: states.count)), gap: Int(12 * scale)) else { return }
        didCapture(ShotCapturedImage(image: collage, scale: scale))
    }

    func revealRecentFolder() {
        try? FileManager.default.createDirectory(at: ShotRecentCaptures.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ShotRecentCaptures.folder)
    }

    var saveFolder: URL { ShotPreferences.saveFolder }

    func chooseSaveFolder() {
        guard acceptsActions() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.directoryURL = ShotPreferences.saveFolder
        activate()
        guard panel.runModal() == .OK, let url = panel.url, acceptsActions() else { return }
        ShotPreferences.saveFolder = url
        objectWillChange.send()
    }

    static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Screenshot ", with: "")
    }

    // MARK: Test access

    var openEditorCount: Int { editors.count }
    var activeSession: ShotSelectionSession? { session }
    var activeThumbnail: ShotThumbnailPanel? { thumbnail }
}
