import AppKit
import ScreenCaptureKit

struct ShotCapturedImage {
    let image: CGImage
    let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }
}

struct ShotDisplayCapture {
    let screen: NSScreen
    let image: CGImage
    /// On-screen windows front to back, in top-left-origin points local to `screen`.
    let windows: [CGRect]

    init(screen: NSScreen, image: CGImage, windows: [CGRect]) {
        self.screen = screen
        self.image = image
        self.windows = windows
    }
}

@MainActor
protocol ShotCaptureSource {
    func captureDisplays() async throws -> [ShotDisplayCapture]
}

enum ShotCaptureError: LocalizedError {
    case noDisplays
    var errorDescription: String? { "No displays could be captured." }
}

@MainActor
struct ScreenCaptureKitSource: ShotCaptureSource {
    private let forcedScale: CGFloat?

    /// `forcedScale` overrides the display's backing scale; only the test driver uses it.
    init(forcedScale: CGFloat? = nil) {
        self.forcedScale = forcedScale
    }

    func captureDisplays() async throws -> [ShotDisplayCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var results: [ShotDisplayCapture] = []
        for display in content.displays {
            guard let screen = Self.screen(for: display.displayID) else { continue }
            let (frame, backing) = (screen.frame, screen.backingScaleFactor)
            let config = SCStreamConfiguration()
            let scale = forcedScale ?? backing
            config.width = Int(frame.width * scale)
            config.height = Int(frame.height * scale)
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            results.append(ShotDisplayCapture(screen: screen, image: image, windows: Self.windows(on: screen)))
        }
        if results.isEmpty { throw ShotCaptureError.noDisplays }
        return results
    }

    @MainActor private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
    }

    @MainActor private static func windows(on screen: NSScreen) -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
        let local = CGRect(origin: .zero, size: screen.frame.size)
        return info.compactMap { window -> CGRect? in
            guard (window[kCGWindowLayer] as? Int) == 0,
                  (window[kCGWindowAlpha] as? CGFloat ?? 1) > 0,
                  let dict = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            let rect = bounds.offsetBy(dx: -origin.x, dy: -origin.y).intersection(local)
            return rect.width > 20 && rect.height > 20 ? rect : nil
        }
    }
}
