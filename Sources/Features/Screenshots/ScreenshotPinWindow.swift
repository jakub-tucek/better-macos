import AppKit

/// A chromeless always-on-top image. Drag to move, scroll to resize, double-click or Esc to close.
final class ShotPinWindow: NSPanel {
    private let aspect: CGFloat
    var onClosed: ((ShotPinWindow) -> Void)?

    init(capture: ShotCapturedImage) {
        let size = CGSize(width: CGFloat(capture.image.width) / capture.scale, height: CGFloat(capture.image.height) / capture.scale)
        aspect = size.width / max(1, size.height)
        let mouse = NSEvent.mouseLocation
        super.init(contentRect: CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinContentView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.contents = capture.image
        view.layer?.contentsGravity = .resize
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY * 0.005
        let width = min(max(frame.width * factor, 60), 4000)
        let height = width / aspect
        setFrame(CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
    }

    override func close() {
        super.close()
        onClosed?(self)
    }
}

private final class PinContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.close() }
    }
}
