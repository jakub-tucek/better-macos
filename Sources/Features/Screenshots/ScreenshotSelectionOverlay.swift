import AppKit
import QuartzCore

/// Non-activating, so it takes the keyboard (Esc, Return) even if the app can't come to the front.
final class ShotOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One full-screen window per display showing the frozen capture. Draw a box, or click a window,
/// or press Return for the whole display. Esc cancels. Hold Space while dragging to reposition.
@MainActor
final class ShotSelectionSession {
    private var windows: [ShotOverlayWindow] = []
    private let finish: (ShotCapturedImage?) -> Void
    private var finished = false

    init(captures: [ShotDisplayCapture], finish: @escaping (ShotCapturedImage?) -> Void) {
        self.finish = finish
        for capture in captures {
            let window = ShotOverlayWindow(contentRect: capture.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.setFrame(capture.screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = ShotOverlayView(capture: capture, frame: CGRect(origin: .zero, size: capture.screen.frame.size)) { [weak self] result in
                self?.complete(result)
            }
            window.contentView = view
            windows.append(window)
        }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
        NSCursor.crosshair.set()
    }

    var overlayWindows: [NSWindow] { windows }

    func complete(_ result: ShotCapturedImage?) {
        guard !finished else { return }
        finished = true
        for window in windows {
            window.orderOut(nil)
            window.contentView?.layer?.sublayers?.forEach { $0.contents = nil }
            window.contentView = nil
        }
        windows.removeAll()
        CATransaction.flush()
        finish(result)
    }
}

final class ShotOverlayView: NSView {
    private let capture: ShotDisplayCapture
    private let done: (ShotCapturedImage?) -> Void
    private let scale: CGFloat

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let crossHLayer = CALayer()
    private let crossVLayer = CALayer()
    private let hudLayer = CATextLayer()
    private let hudBackground = CALayer()

    private var anchor: CGPoint?
    private var current: CGPoint = .zero
    private var spaceHeld = false
    private var lastSpacePoint: CGPoint?
    private var hoveredWindow: CGRect?

    private static let clickThreshold: CGFloat = 3

    init(capture: ShotDisplayCapture, frame: CGRect, done: @escaping (ShotCapturedImage?) -> Void) {
        self.capture = capture
        self.done = done
        self.scale = CGFloat(capture.image.width) / max(1, frame.width)
        super.init(frame: frame)
        wantsLayer = true
        setUpLayers()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor

        imageLayer.frame = bounds
        imageLayer.contents = capture.image
        imageLayer.contentsScale = scale
        imageLayer.magnificationFilter = .nearest
        root.addSublayer(imageLayer)

        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        root.addSublayer(dimLayer)

        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        root.addSublayer(borderLayer)

        for line in [crossHLayer, crossVLayer] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
            root.addSublayer(line)
        }

        hudLayer.fontSize = 12
        hudLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hudLayer.foregroundColor = ShotTheme.text.cgColor
        hudBackground.backgroundColor = ShotTheme.panel.cgColor
        hudBackground.borderColor = ShotTheme.hairline.cgColor
        hudBackground.borderWidth = 1
        hudBackground.cornerRadius = 8
        ShotTheme.softShadow(hudBackground, radius: 12)
        root.addSublayer(hudBackground)
        hudLayer.contentsScale = scale
        hudLayer.alignmentMode = .center
        hudBackground.addSublayer(hudLayer)

        current = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        refresh()
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        current = point(event)
        hoveredWindow = windowRect(at: current)
        refresh()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        current = point(event)
        anchor = current
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if spaceHeld, let last = lastSpacePoint, let a = anchor {
            anchor = CGPoint(x: a.x + p.x - last.x, y: a.y + p.y - last.y)
        }
        if spaceHeld { lastSpacePoint = p }
        current = p
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        current = point(event)
        guard let rect = selectionRect else { return }
        if rect.width < Self.clickThreshold, rect.height < Self.clickThreshold {
            if let hovered = windowRect(at: current) { finish(with: hovered) } else { anchor = nil; refresh() }
        } else {
            finish(with: rect)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: done(nil) // Esc
        case 36, 76: finish(with: bounds) // Return
        case 49:
            spaceHeld = true
            lastSpacePoint = current
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            lastSpacePoint = nil
        }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private var selectionRect: CGRect? {
        guard let anchor else { return nil }
        return CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                      width: abs(anchor.x - current.x), height: abs(anchor.y - current.y))
    }

    /// Topmost window under `p`, converted to this view's bottom-up coordinates.
    private func windowRect(at p: CGPoint) -> CGRect? {
        capture.windows.lazy
            .map { CGRect(x: $0.minX, y: self.bounds.height - $0.maxY, width: $0.width, height: $0.height) }
            .first { $0.contains(p) }
    }

    private func finish(with rect: CGRect) {
        // Snap to the pixel grid, then flip to the image's top-left origin.
        let clipped = rect.intersection(bounds)
        let px = CGRect(x: (clipped.minX * scale).rounded(),
                        y: ((bounds.height - clipped.maxY) * scale).rounded(),
                        width: max(1, (clipped.width * scale).rounded()),
                        height: max(1, (clipped.height * scale).rounded()))
        guard let cropped = capture.image.cropping(to: px) else { done(nil); return }
        // A cropped CGImage keeps its whole parent frame alive, so copy out just these pixels.
        let ctx = ShotRenderer.makeContext(width: cropped.width, height: cropped.height)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        done(ShotCapturedImage(image: ctx.makeImage() ?? cropped, scale: scale))
    }

    // MARK: Drawing

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let selection = selectionRect
        let highlight = selection ?? hoveredWindow

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let highlight { dim.addRect(highlight) }
        dimLayer.path = dim
        borderLayer.path = highlight.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }

        crossHLayer.frame = CGRect(x: 0, y: current.y, width: bounds.width, height: 1 / scale)
        crossVLayer.frame = CGRect(x: current.x, y: 0, width: 1 / scale, height: bounds.height)
        let showCross = selection == nil
        crossHLayer.isHidden = !showCross
        crossVLayer.isHidden = !showCross

        updateHUD(selection ?? hoveredWindow)
    }

    private func updateHUD(_ rect: CGRect?) {
        hudBackground.isHidden = rect == nil
        guard let rect else { return }
        let text = "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
        hudLayer.string = text
        let width = CGFloat(text.count) * 7.4 + 20
        let height: CGFloat = 26
        let offset: CGFloat = 16
        var x = current.x + offset, y = current.y - offset - height
        if x + width > bounds.width { x = current.x - offset - width }
        if y < 0 { y = current.y + offset }
        hudBackground.frame = CGRect(x: x, y: y, width: width, height: height)
        hudLayer.frame = CGRect(x: 0, y: -5, width: width, height: height) // CATextLayer top-aligns; this centers one line
    }
}
