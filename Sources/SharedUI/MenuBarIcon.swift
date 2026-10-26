import AppKit

enum MenuBarIcon {
    static func image(for model: DashboardModel, description: String) -> NSImage? {
        if model.statusNeedsAttention || model.keepAwakeActive {
            return NSImage(systemSymbolName: model.statusSymbol, accessibilityDescription: description)
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            // Parallel rising strokes, optically centered with generous separation.
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 3.5, y: 4))
            mark.line(to: NSPoint(x: 7.5, y: 11))
            mark.move(to: NSPoint(x: 10.5, y: 7))
            mark.line(to: NSPoint(x: 14.5, y: 14))
            mark.lineWidth = 3.5
            mark.lineCapStyle = .round
            mark.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
