import AppKit

/// The only place colors and chrome metrics are defined. Near-black neutrals, hairlines, one quiet accent.
enum ShotTheme {
    private static func hex(_ value: UInt32) -> NSColor { ShotRGBA(hex: value).nsColor }

    static let deep = hex(0x0A0A0A)        // Window background and toolbar
    static let panel = hex(0x171717)       // Raised surfaces
    static let tray = hex(0x141414)        // Recessed groups
    static let raised = hex(0x2A2A2A)      // Selected fill, keycaps
    static let hover = NSColor(white: 1, alpha: 0.07)
    static let hairline = NSColor(white: 1, alpha: 0.11)
    static let text = hex(0xEDEDED)
    static let muted = hex(0xA3A3A3)
    static let faint = hex(0x737373)
    static let accent = hex(0xA5B4FC)
    static let retake = hex(0xFF5A3C)
    static let checkerA = hex(0x1A1A1A)
    static let checkerB = hex(0x202020)

    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7

    static func softShadow(_ layer: CALayer?, radius: CGFloat = 24, opacity: Float = 0.5) {
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = opacity
        layer?.shadowRadius = radius
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }
}
