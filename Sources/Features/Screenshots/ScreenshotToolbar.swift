import AppKit

/// Borderless icon button with a rounded highlight when active.
final class ShotIconButton: NSButton {
    private let restingTint: NSColor
    var isActiveTool = false {
        didSet {
            contentTintColor = isActiveTool ? ShotTheme.text : restingTint
            needsDisplay = true
        }
    }
    private var hovering = false

    init(symbol: String, tooltip: String, tint: NSColor = ShotTheme.muted, size: CGFloat = 15, target: AnyObject?, action: Selector?) {
        restingTint = tint
        super.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        setSymbol(symbol, size: size)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = tint
        toolTip = tooltip
        self.target = target
        self.action = action
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ symbol: String, size: CGFloat = 15) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(config)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isActiveTool || hovering {
            (isActiveTool ? ShotTheme.raised : ShotTheme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: ShotTheme.controlRadius, yRadius: ShotTheme.controlRadius).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Color dot; click for the annotation color menu.
final class ShotColorDot: NSButton {
    var color = ShotRGBA.presets[0].color { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 16
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        color.nsColor.setFill()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        NSColor(white: 1, alpha: 0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Two-line read-out, e.g. "#1C2022 / Tab to copy".
final class ShotInfoBlock: NSView {
    private let top = NSTextField(labelWithString: "")
    private let bottom = NSTextField(labelWithString: "")

    init(top topText: String, bottom bottomText: String) {
        super.init(frame: .zero)
        top.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        top.textColor = ShotTheme.text
        bottom.font = .systemFont(ofSize: 11)
        bottom.textColor = ShotTheme.faint
        top.stringValue = topText
        bottom.stringValue = bottomText
        addSubview(top)
        addSubview(bottom)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var value: String {
        get { top.stringValue }
        set { top.stringValue = newValue }
    }

    override func layout() {
        super.layout()
        top.frame = CGRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 16)
        bottom.frame = CGRect(x: 0, y: bounds.midY - 15, width: bounds.width, height: 14)
    }
}

/// The dotted document handle: drag it into any app to drop the image as a PNG file.
final class ShotDragHandle: NSView, NSDraggingSource {
    var makeFile: (() -> URL?)?

    override func draw(_ dirtyRect: NSRect) {
        let tint = ShotTheme.muted
        if let doc = NSImage(systemSymbolName: "doc", accessibilityDescription: "Drag image")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular).applying(.init(paletteColors: [tint]))) {
            doc.draw(in: CGRect(x: (bounds.width - doc.size.width) / 2, y: (bounds.height - doc.size.height) / 2,
                                width: doc.size.width, height: doc.size.height))
        }
        ShotTheme.faint.setFill()
        for x in [CGFloat(3), 7, bounds.width - 9, bounds.width - 5] {
            for y in stride(from: bounds.midY - 7, through: bounds.midY + 6, by: 6.5) {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 2, height: 2)).fill()
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { }

    override func mouseDragged(with event: NSEvent) {
        guard let url = makeFile?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSImage(contentsOf: url) ?? NSImage()
        let width: CGFloat = 160
        let height = width * icon.size.height / max(1, icon.size.width)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

final class ShotToolbarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ShotTheme.deep.setFill()
        bounds.fill()
    }
}

final class ShotSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ShotTheme.hairline.setFill()
        bounds.fill()
    }
}

/// The dark checkerboard behind the image.
final class ShotCheckerView: NSView {
    private static let pattern: NSColor = {
        let tile: CGFloat = 8
        let image = NSImage(size: CGSize(width: tile * 2, height: tile * 2), flipped: false) { _ in
            ShotTheme.checkerA.setFill()
            CGRect(x: 0, y: 0, width: tile * 2, height: tile * 2).fill()
            ShotTheme.checkerB.setFill()
            CGRect(x: 0, y: 0, width: tile, height: tile).fill()
            CGRect(x: tile, y: tile, width: tile, height: tile).fill()
            return true
        }
        return NSColor(patternImage: image)
    }()

    override func draw(_ dirtyRect: NSRect) {
        Self.pattern.setFill()
        dirtyRect.fill()
    }
}

/// Keeps the document centered when it is smaller than the viewport.
final class ShotCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if doc.frame.height < rect.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Recessed rounded group behind the tool buttons.
final class ShotToolTray: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        ShotTheme.tray.setFill()
        path.fill()
        ShotTheme.hairline.setStroke()
        path.stroke()
    }
}

/// Small circle showing the color under the cursor.
final class ShotSwatch: NSView {
    var color = ShotRGBA(hex: 0) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        color.nsColor.setFill()
        path.fill()
        ShotTheme.hairline.setStroke()
        path.stroke()
    }
}
