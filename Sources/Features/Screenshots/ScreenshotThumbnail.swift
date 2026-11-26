import AppKit

/// Corner preview shown after copying. Click to reopen with annotations, drag into any app, or let it fade away.
final class ShotThumbnailPanel: NSPanel {
    /// Seconds on screen; tests shorten it.
    nonisolated(unsafe) static var lifetime: TimeInterval = 6

    private let content: ThumbnailContent
    private var dismissal: DispatchWorkItem?
    var onDismissed: ((ShotThumbnailPanel) -> Void)?
    private var dismissed = false

    init(image: CGImage, onOpen: @escaping () -> Void, makeDragFile: @escaping () -> URL?) {
        let aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        var size = CGSize(width: 220, height: 220 / aspect)
        if size.height > 160 { size = CGSize(width: 160 * aspect, height: 160) }
        size = CGSize(width: max(size.width, 72), height: max(size.height, 48))

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height)

        content = ThumbnailContent(frame: CGRect(origin: .zero, size: size), image: Self.shrunk(image, to: size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = content
        content.onOpen = { [weak self] in
            onOpen()
            self?.dismiss()
        }
        content.makeDragFile = makeDragFile
        content.onClose = { [weak self] in self?.dismiss() }
        content.onHover = { [weak self] hovering in
            if hovering { self?.dismissal?.cancel() } else { self?.scheduleDismissal() }
        }
    }

    override var canBecomeKey: Bool { false }

    /// A small copy, so the preview doesn't pin the full screenshot in memory.
    private static func shrunk(_ image: CGImage, to size: CGSize) -> CGImage {
        let ctx = ShotRenderer.makeContext(width: Int(size.width * 2), height: Int(size.height * 2))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx.makeImage() ?? image
    }

    func present() {
        let target = frame
        let invisible = alphaValue == 0
        if !invisible { alphaValue = 0 }
        setFrame(target.offsetBy(dx: 16, dy: 0), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
            if !invisible { animator().alphaValue = 1 }
        }
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: work)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        dismissal?.cancel()
        orderOut(nil)
        onDismissed?(self)
    }
}

private final class ThumbnailContent: NSView, NSDraggingSource {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var makeDragFile: (() -> URL?)?
    private let closeButton: ShotIconButton
    private var dragged = false

    init(frame: CGRect, image: CGImage) {
        closeButton = ShotIconButton(symbol: "xmark", tooltip: "Dismiss", tint: ShotTheme.text, size: 9, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = ShotTheme.panel.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = ShotTheme.hairline.cgColor

        closeButton.frame = CGRect(x: 6, y: frame.height - 26, width: 20, height: 20)
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = ShotTheme.panel.cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        toolTip = "Click to edit, drag to share"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func closeClicked() { onClose?() }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let url = makeDragFile?() else { return }
        dragged = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(contentsOf: url) ?? NSImage()
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onOpen?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onClose?() }
    }
}
