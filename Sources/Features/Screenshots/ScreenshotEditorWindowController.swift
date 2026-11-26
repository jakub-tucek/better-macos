import AppKit
import UniformTypeIdentifiers
import Vision

final class ShotEditorWindow: NSWindow {
    var onLayoutTitlebar: (() -> Void)?
    /// Editor commands the host menu bar does not carry (save, pin, retake, zoom, OCR).
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ShotEditorWindowController: NSWindowController, NSWindowDelegate, ShotCanvasDelegate, NSMenuDelegate {
    let model: ShotEditorModel
    let canvas: ShotCanvasView
    private let app: ScreenshotsModule

    private let toolbar = ShotToolbarView()
    private let scrollView = NSScrollView()
    private let checker = ShotCheckerView()
    private let panel = NSView()
    private let swatch = ShotSwatch()
    private let toast = NSTextField(labelWithString: "")
    private let toastPill = NSView()
    private var toastHide: DispatchWorkItem?

    private let hexInfo = ShotInfoBlock(top: "#000000", bottom: "Tab to copy")
    private let sizeInfo = ShotInfoBlock(top: "", bottom: "Image size")
    private let zoomInfo = ShotInfoBlock(top: "100%", bottom: "Zoom")
    private let colorDot = ShotColorDot()
    private let dragHandle = ShotDragHandle()
    private var toolButtons: [ShotTool: ShotIconButton] = [:]
    private var moreButton: ShotIconButton!
    private var beautifyButton: ShotIconButton!
    private var chrome: [NSView] = []

    private static let toolbarHeight: CGFloat = 52
    private static let barTools: [ShotTool] = [.select, .crop, .arrow, .text, .measure, .rect, .blur]
    private static let moreTools: [ShotTool] = [.ellipse, .line, .pen, .highlighter, .counter, .spotlight]
    private static let minSize = CGSize(width: 900, height: 420)

    /// Set when the user retakes, so the app knows to start another capture after closing.
    var onClosed: ((ShotEditorWindowController) -> Void)?

    /// Where this document lives in Recent Captures; nil for an image opened from elsewhere until it is edited.
    private(set) var documentURL: URL?
    private let originalBase: CGImage

    init(model: ShotEditorModel, documentURL: URL?, app: ScreenshotsModule) {
        self.app = app
        self.model = model
        self.documentURL = documentURL
        originalBase = model.state.base
        canvas = ShotCanvasView(model: model)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pts = model.state.pointSize
        let padding: CGFloat = 120
        let width = min(max(pts.width + padding, Self.minSize.width), screen.width * 0.92)
        let height = min(max(pts.height + padding + Self.toolbarHeight, Self.minSize.height), screen.height * 0.92)

        let window = ShotEditorWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = "Screenshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = ShotTheme.deep
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        app.prepare(window)
        window.onKeyEquivalent = { [weak self] event in self?.performCommand(event) ?? false }
        buildUI(in: window)

        canvas.delegate = self
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = false
        ShotTheme.softShadow(canvas.layer)
        fitZoomIfNeeded(viewport: CGSize(width: width - 40, height: height - Self.toolbarHeight - 40))
        refreshAll()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: UI construction

    private func buildUI(in window: NSWindow) {
        let content = window.contentView!
        panel.wantsLayer = true
        panel.layer?.cornerRadius = ShotTheme.panelRadius
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = ShotTheme.hairline.cgColor
        panel.layer?.backgroundColor = ShotTheme.panel.cgColor
        content.addSubview(panel)
        panel.addSubview(checker)

        let clip = ShotCenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = canvas
        panel.addSubview(scrollView)

        toast.font = .systemFont(ofSize: 12, weight: .medium)
        toast.textColor = ShotTheme.text
        toast.alignment = .center
        toastPill.wantsLayer = true
        toastPill.layer?.backgroundColor = ShotTheme.raised.cgColor
        toastPill.layer?.borderWidth = 1
        toastPill.layer?.borderColor = ShotTheme.hairline.cgColor
        toastPill.addSubview(toast)
        toastPill.isHidden = true
        content.addSubview(toastPill)

        content.addSubview(toolbar)
        buildToolbar()
        layoutUI()
    }

    private func buildToolbar() {
        func add(_ view: NSView, x: inout CGFloat, width: CGFloat = 30, advance: CGFloat? = nil) {
            view.frame = CGRect(x: x, y: (Self.toolbarHeight - 30) / 2, width: width, height: 30)
            toolbar.addSubview(view)
            x += advance ?? (width + 2)
        }
        func separator(_ x: inout CGFloat) {
            let s = ShotSeparator(frame: CGRect(x: x + 3, y: 18, width: 1, height: 16))
            toolbar.addSubview(s)
            x += 8
        }

        var x: CGFloat = 86
        add(ShotIconButton(symbol: "doc.on.doc", tooltip: "Copy image (⌘C)", target: self, action: #selector(copyImage(_:))), x: &x)
        separator(&x)
        add(ShotIconButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", target: self, action: #selector(saveImage(_:))), x: &x)
        separator(&x)
        add(ShotIconButton(symbol: "pin", tooltip: "Pin on top of all windows (⌘P)", target: self, action: #selector(pinImage(_:))), x: &x)
        dragHandle.makeFile = { [weak self] in self?.writeDragFile() }
        dragHandle.toolTip = "Drag into another app"
        x += 6
        add(dragHandle, x: &x, width: 44, advance: 60)

        let trayStart = x - 4
        for tool in Self.barTools {
            let button = ShotIconButton(symbol: tool.symbol, tooltip: "\(tool.title) (\(tool.key.uppercased()))", target: self, action: #selector(toolClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            toolButtons[tool] = button
            add(button, x: &x)
        }
        moreButton = ShotIconButton(symbol: "ellipsis", tooltip: "More tools and collage", target: self, action: #selector(showMore(_:)))
        add(moreButton, x: &x, advance: 34)
        let tray = ShotToolTray(frame: CGRect(x: trayStart, y: (Self.toolbarHeight - 38) / 2, width: x - 4 - trayStart + 4, height: 38))
        toolbar.addSubview(tray, positioned: .below, relativeTo: nil)
        x += 8

        colorDot.isBordered = false
        colorDot.title = ""
        colorDot.target = self
        colorDot.action = #selector(showColors(_:))
        colorDot.toolTip = "Annotation color"
        add(colorDot, x: &x, advance: 34)

        add(ShotIconButton(symbol: "arrow.triangle.2.circlepath", tooltip: "Retake (⌘R)", tint: ShotTheme.retake, size: 15, target: self, action: #selector(retake(_:))), x: &x)
        beautifyButton = ShotIconButton(symbol: "sparkles", tooltip: "Beautify (F)", target: self, action: #selector(showBeautify(_:)))
        add(beautifyButton, x: &x, advance: 34)
        chrome = [swatch, hexInfo, sizeInfo, zoomInfo]
        chrome.forEach(toolbar.addSubview)
    }

    private func layoutUI() {
        guard let content = window?.contentView else { return }
        let b = content.bounds
        toolbar.frame = CGRect(x: 0, y: b.height - Self.toolbarHeight, width: b.width, height: Self.toolbarHeight)
        panel.frame = CGRect(x: 8, y: 8, width: b.width - 16, height: b.height - Self.toolbarHeight - 8)
        checker.frame = panel.bounds
        scrollView.frame = panel.bounds

        var right = b.width - 12
        for (view, width) in [(zoomInfo, CGFloat(40)), (sizeInfo, 84), (hexInfo, 62)] {
            right -= width
            view.frame = CGRect(x: right, y: 6, width: width, height: 40)
            right -= 14
        }
        swatch.frame = CGRect(x: right - 4, y: (Self.toolbarHeight - 18) / 2, width: 18, height: 18)
        positionTrafficLights()
    }

    /// Centers the window buttons vertically in the taller toolbar.
    private func positionTrafficLights() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        var frame = container.frame
        frame.size.height = Self.toolbarHeight
        frame.origin.y = window.frame.height - Self.toolbarHeight
        container.frame = frame
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(CGPoint(x: 16 + CGFloat(i) * 22, y: (Self.toolbarHeight - button.frame.height) / 2))
        }
    }

    func windowDidResize(_ notification: Notification) { layoutUI() }
    func windowDidEndLiveResize(_ notification: Notification) { layoutUI() }
    func windowDidEnterFullScreen(_ notification: Notification) { layoutUI() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutUI() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        layoutUI()
    }

    private func fitZoomIfNeeded(viewport: CGSize) {
        let pts = model.state.pointSize
        let fit = min(viewport.width / pts.width, viewport.height / pts.height)
        canvas.setZoom(fit < 1 ? fit : 1)
    }

    // MARK: Refresh

    private func refreshAll() {
        for (tool, button) in toolButtons { button.isActiveTool = tool == canvas.tool }
        let usingMore = Self.moreTools.contains(canvas.tool)
        moreButton.isActiveTool = usingMore
        moreButton.setSymbol(usingMore ? canvas.tool.symbol : "ellipsis")
        colorDot.color = canvas.color
        canvasDidChange()
        canvasZoomChanged()
    }

    func canvasDidChange() {
        let pts = model.state.pointSize
        sizeInfo.value = "\(Int(pts.width.rounded()))×\(Int(pts.height.rounded()))pt"
        beautifyButton.isActiveTool = model.state.beautify != nil
        colorDot.color = canvas.color
    }

    func canvasHover(color: ShotRGBA?) {
        guard let color else { return }
        hexInfo.value = color.hexString
        swatch.color = color
    }

    func canvasZoomChanged() { zoomInfo.value = "\(Int((canvas.zoom * 100).rounded()))%" }

    func canvasSetTool(_ tool: ShotTool) {
        canvas.tool = tool
        refreshAll()
    }

    func canvasCopyHoverColor() {
        guard let color = canvas.hoverColor else { return }
        ShotExporter.copy(string: color.hexString)
        canvasToast("Copied \(color.hexString)")
    }

    func canvasRequestCopy() { copyImage(nil) }
    func canvasRequestClose() { window?.performClose(nil) }

    func canvasToast(_ message: String) {
        guard let content = window?.contentView else { return }
        toast.stringValue = message
        let size = toast.intrinsicContentSize
        let width = size.width + 28, height: CGFloat = 28
        toastPill.frame = CGRect(x: (content.bounds.width - width) / 2, y: 24, width: width, height: height)
        toastPill.layer?.cornerRadius = height / 2
        toast.frame = CGRect(x: 0, y: (height - size.height) / 2, width: width, height: size.height)
        toastPill.isHidden = false
        toastPill.alphaValue = 1
        toastHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self?.toastPill.animator().alphaValue = 0 },
                                                 completionHandler: { self?.toastPill.isHidden = true })
        }
        toastHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: hide)
    }

    // MARK: Output

    func flattened() -> CGImage {
        canvas.commitText()
        return ShotRenderer.flatten(model.state)
    }

    @objc func copyImage(_ sender: Any?) {
        let image = flattened()
        guard ShotExporter.copy(image, scale: model.state.scale) else {
            canvasToast("Couldn't copy image")
            return
        }
        canvasToast("Copied to clipboard")
        if ShotPreferences.closeAfterCopy {
            window?.close()
            if ShotPreferences.showThumbnail, let documentURL { app.showThumbnail(image, documentURL: documentURL) }
        }
    }

    @objc func saveImage(_ sender: Any?) {
        let url = ShotPreferences.saveFolder.appendingPathComponent(ShotPreferences.timestampedName())
        write(to: url, type: .png)
    }

    @objc func saveImageAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = ShotPreferences.timestampedName()
        panel.directoryURL = ShotPreferences.saveFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(to: url, type: url.pathExtension.lowercased().hasPrefix("j") ? .jpeg : .png)
        }
    }

    private func write(to url: URL, type: UTType) {
        do {
            guard let data = ShotExporter.encode(flattened(), type: type, scale: model.state.scale) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            canvasToast("Saved \(url.lastPathComponent)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func writeDragFile() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Better macOS Screenshot Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ShotPreferences.timestampedName())
        guard let data = ShotExporter.encode(flattened(), scale: model.state.scale), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    @objc func pinImage(_ sender: Any?) {
        app.pin(ShotCapturedImage(image: flattened(), scale: model.state.scale))
    }

    @objc func retake(_ sender: Any?) {
        window?.close()
        app.captureAreaAfterHiding()
    }

    @objc func recognizeText(_ sender: Any?) {
        let image = flattened()
        Task {
            let text = await ShotOCR.recognize(image)
            if text.isEmpty {
                canvasToast("No text found")
            } else {
                ShotExporter.copy(string: text)
                canvasToast("Copied \(text.count) characters")
            }
        }
    }

    // MARK: Zoom actions

    @objc func zoomIn(_ sender: Any?) { canvas.setZoom(canvas.zoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { canvas.setZoom(canvas.zoom / 1.25) }
    @objc func zoomActual(_ sender: Any?) { canvas.setZoom(1) }
    @objc func zoomFit(_ sender: Any?) {
        canvas.setZoom(min(scrollView.bounds.width / model.state.pointSize.width, scrollView.bounds.height / model.state.pointSize.height) * 0.96)
    }

    // MARK: ShotTool, color and collage menus

    @objc private func toolClicked(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let tool = ShotTool(rawValue: raw) { canvasSetTool(tool) }
        window?.makeFirstResponder(canvas)
    }

    @objc private func toolMenuItem(_ sender: NSMenuItem) {
        if let tool = sender.representedObject as? String, let t = ShotTool(rawValue: tool) { canvasSetTool(t) }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        for tool in Self.moreTools {
            let entry = item("\(tool.title)  (\(tool.key.uppercased()))", #selector(toolMenuItem(_:)), symbol: tool.symbol, represented: tool.rawValue)
            entry.state = canvas.tool == tool ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for (title, points) in [("Thin Stroke", CGFloat(2)), ("Medium Stroke", 3), ("Thick Stroke", 6)] {
            let entry = item(title, #selector(strokeItem(_:)), represented: points)
            entry.state = canvas.strokePoints == points ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let beautify = NSMenuItem(title: "Beautify", action: nil, keyEquivalent: "")
        beautify.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        beautify.submenu = beautifyMenu()
        menu.addItem(beautify)
        menu.addItem(item("Copy Text from Image (OCR)", #selector(recognizeText(_:)), symbol: "text.viewfinder"))
        menu.addItem(item("Add Image from File…", #selector(insertImageFile(_:)), symbol: "photo.badge.plus"))
        menu.addItem(.separator())
        let collage = NSMenuItem(title: "Collage", action: nil, keyEquivalent: "")
        collage.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        collage.submenu = collageMenu()
        menu.addItem(collage)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: sender)
    }

    // MARK: Beautify

    func canvasToggleBeautify() {
        setBeautify(model.state.beautify == nil ? ShotPreferences.beautifyStyle : nil)
    }

    func setBeautify(_ style: ShotBeautifyStyle?) {
        canvas.commitText()
        model.mutate { $0.beautify = style }
        if let style { ShotPreferences.beautifyStyle = style }
        canvas.syncFrame()
        canvasDidChange()
        zoomFitIfOverflowing()
    }

    private func beautifyMenu() -> NSMenu {
        let menu = NSMenu()
        let current = model.state.beautify
        let toggle = item(current == nil ? "Turn On  (F)" : "Turn Off  (F)", #selector(beautifyToggleItem(_:)))
        menu.addItem(toggle)
        menu.addItem(.separator())
        let shown = current ?? ShotPreferences.beautifyStyle
        for (i, background) in ShotBeautifyStyle.backgrounds.enumerated() {
            let entry = item(background.name, #selector(beautifyBackgroundItem(_:)), represented: i)
            entry.image = Self.swatch(background.from)
            entry.state = current != nil && shown.background == i ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for padding in ShotBeautifyStyle.paddings {
            let entry = item("\(padding.name) Padding", #selector(beautifyPaddingItem(_:)), represented: padding.points)
            entry.state = current != nil && shown.padding == padding.points ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func showBeautify(_ sender: NSButton) {
        beautifyMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: sender)
    }

    @objc private func beautifyToggleItem(_ sender: Any?) { canvasToggleBeautify() }

    @objc private func beautifyBackgroundItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        var style = model.state.beautify ?? ShotPreferences.beautifyStyle
        style.background = index
        setBeautify(style)
    }

    @objc private func beautifyPaddingItem(_ sender: NSMenuItem) {
        guard let points = sender.representedObject as? CGFloat else { return }
        var style = model.state.beautify ?? ShotPreferences.beautifyStyle
        style.padding = points
        setBeautify(style)
    }

    func collageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Capture and Add to the Right", #selector(collageCaptureRight(_:))))
        menu.addItem(item("Capture and Add Below", #selector(collageCaptureBelow(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Add Clipboard Image to the Right", #selector(collagePasteRight(_:))))
        menu.addItem(item("Add Clipboard Image Below", #selector(collagePasteBelow(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Add File to the Right…", #selector(collageFileRight(_:))))
        menu.addItem(item("Add File Below…", #selector(collageFileBelow(_:))))
        return menu
    }

    @objc private func collageCaptureRight(_ sender: Any?) { collageCapture(.right) }
    @objc private func collageCaptureBelow(_ sender: Any?) { collageCapture(.below) }
    @objc private func collagePasteRight(_ sender: Any?) { collagePaste(.right) }
    @objc private func collagePasteBelow(_ sender: Any?) { collagePaste(.below) }
    @objc private func collageFileRight(_ sender: Any?) { collageFile(.right) }
    @objc private func collageFileBelow(_ sender: Any?) { collageFile(.below) }

    func collageCapture(_ direction: ShotCollageDirection) {
        window?.orderOut(nil)
        app.captureAreaAfterHiding { [weak self] capture in
            guard let self else { return }
            if let capture { self.append(capture.image, direction) }
            self.present()
        }
    }

    private func collagePaste(_ direction: ShotCollageDirection) {
        guard let image = ShotExporter.image(fromPasteboard: ShotExporter.pasteboard) else {
            canvasToast("No image on the clipboard")
            return
        }
        append(image, direction)
    }

    private func collageFile(_ direction: ShotCollageDirection) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let loaded = ShotExporter.load(url: url) else { return }
            self?.append(loaded.image, direction)
        }
    }

    func append(_ image: CGImage, _ direction: ShotCollageDirection) {
        canvas.commitText()
        model.appendToCollage(image, direction: direction, gap: Int(12 * model.state.scale))
        canvas.syncFrame()
        canvasDidChange()
        zoomFitIfOverflowing()
    }

    private func zoomFitIfOverflowing() {
        let pts = model.state.pointSize
        if pts.width * canvas.zoom > scrollView.bounds.width || pts.height * canvas.zoom > scrollView.bounds.height {
            zoomFit(nil)
        }
    }

    @objc private func insertImageFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let loaded = ShotExporter.load(url: url) else { return }
            self?.canvas.insertImage(loaded.image)
        }
    }

    @objc private func strokeItem(_ sender: NSMenuItem) {
        if let points = sender.representedObject as? CGFloat { canvas.setStroke(points: points) }
    }

    @objc private func showColors(_ sender: NSButton) {
        let menu = NSMenu()
        for preset in ShotRGBA.presets {
            let entry = item(preset.name, #selector(colorItem(_:)), represented: preset.name)
            entry.image = Self.swatch(preset.color)
            entry.state = canvas.color == preset.color ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Custom…", #selector(customColor(_:))))
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: sender)
    }

    private static func swatch(_ color: ShotRGBA) -> NSImage {
        NSImage(size: CGSize(width: 14, height: 14), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func colorItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = ShotRGBA.presets.first(where: { $0.name == name }) else { return }
        canvas.setColor(preset.color)
        colorDot.color = preset.color
    }

    @objc private func customColor(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = canvas.color.nsColor
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        canvas.setColor(ShotRGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent))
    }

    // MARK: Commands

    /// Shottie kept these in its own menu bar; inside Better macOS the editor answers them directly.
    private func performCommand(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), !mods.contains(.option), !mods.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = mods.contains(.shift)
        switch (key, shift) {
        case ("s", false): saveImage(nil)
        case ("s", true): saveImageAs(nil)
        case ("p", false): pinImage(nil)
        case ("r", false): retake(nil)
        case ("c", true): recognizeText(nil)
        case ("=", _), ("+", _): zoomIn(nil)
        case ("-", false): zoomOut(nil)
        case ("0", false): zoomActual(nil)
        case ("9", false): zoomFit(nil)
        case ("m", false): window?.performMiniaturize(nil)
        default: return false
        }
        return true
    }

    // MARK: Window lifetime

    /// Writes edits to Recent Captures so the document can come back after closing.
    private func persist() {
        canvas.commitText()
        guard model.canUndo else { return }
        let isNew = documentURL == nil
        let url = documentURL ?? ShotRecentCaptures.newURL()
        documentURL = url
        ShotRecentCaptures.save(model.state, to: url, writeBase: isNew || model.state.base !== originalBase)
    }

    func windowWillClose(_ notification: Notification) {
        toastHide?.cancel()
        persist()
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { NSColorPanel.shared.setTarget(nil) }
        onClosed?(self)
    }
}

enum ShotOCR {
    static func recognize(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}
