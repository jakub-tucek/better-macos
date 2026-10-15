import AppKit
import ApplicationServices

/// Maps edge crossings in CoreGraphics coordinates (positive Y points down).
/// Ambiguous edges with multiple neighbors retain native macOS behavior.
enum ScreenEdges {
    static func destination(from previous: CGPoint, to current: CGPoint, delta: CGPoint,
                            layout: [DisplayPosition]) -> CGPoint? {
        let frames = layout.compactMap { position -> CGRect? in
            guard let width = position.width, let height = position.height, width > 4, height > 4 else { return nil }
            return CGRect(x: Int(position.x), y: Int(position.y), width: Int(width), height: Int(height))
        }
        guard previous.x.isFinite, previous.y.isFinite, current.x.isFinite, current.y.isFinite,
              delta.x.isFinite, delta.y.isFinite,
              let source = frames.first(where: { $0.contains(previous) }) else { return nil }
        let horizontal = abs(delta.x) > abs(delta.y)
        let directions = horizontal ? [0, 1, 2, 3] : [2, 3, 0, 1]
        for edge in directions {
            let crossing: Bool
            switch edge {
            case 0: crossing = delta.x < 0 && current.x <= source.minX + 0.5
            case 1: crossing = delta.x > 0 && current.x >= source.maxX - 1
            case 2: crossing = delta.y < 0 && current.y <= source.minY + 0.5
            default: crossing = delta.y > 0 && current.y >= source.maxY - 1
            }
            guard crossing else { continue }
            let neighbors = frames.filter { target in
                guard target != source else { return false }
                let overlapX = min(source.maxX, target.maxX) - max(source.minX, target.minX)
                let overlapY = min(source.maxY, target.maxY) - max(source.minY, target.minY)
                switch edge {
                case 0: return abs(target.maxX - source.minX) <= 1 && overlapY > 0
                case 1: return abs(target.minX - source.maxX) <= 1 && overlapY > 0
                case 2: return abs(target.maxY - source.minY) <= 1 && overlapX > 0
                default: return abs(target.minY - source.maxY) <= 1 && overlapX > 0
                }
            }
            guard neighbors.count == 1, let target = neighbors.first else { continue }
            // A two-point inset avoids immediately bouncing back over the seam.
            if edge < 2 {
                let fraction = min(1, max(0, (current.y - source.minY) / source.height))
                return CGPoint(x: edge == 0 ? target.maxX - 2 : target.minX + 2,
                               y: target.minY + 2 + fraction * (target.height - 4))
            }
            let fraction = min(1, max(0, (current.x - source.minX) / source.width))
            return CGPoint(x: target.minX + 2 + fraction * (target.width - 4),
                           y: edge == 2 ? target.maxY - 2 : target.minY + 2)
        }
        return nil
    }
}

/// A main-run-loop mouse-move tap; never intercepts clicks, keys, or dragging.
final class ScreenEdgeController {
    static func makeWarpSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        // Quartz otherwise suppresses local input for 250ms after a cursor warp.
        source.localEventsSuppressionInterval = 0
        return source
    }
    private var warpSource: CGEventSource?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var layout: [DisplayPosition] = []
    private var previous: CGPoint?
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start(layout: [DisplayPosition]) throws {
        if tap != nil && !isRunning { stop() }
        self.layout = layout
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { throw ToggleError(message: "Match screen edges requires Accessibility access.") }
        guard let warpSource = Self.makeWarpSource() else {
            throw ToggleError(message: "Could not create the cursor event source.")
        }
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ScreenEdgeController>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Leave disabled until the next explicit start/refresh rather than
                // repeatedly fighting an OS timeout in an input callback.
                owner.previous = nil
                return Unmanaged.passUnretained(event)
            }
            guard type == .mouseMoved else {
                owner.previous = nil
                return Unmanaged.passUnretained(event)
            }
            owner.handle(event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw ToggleError(message: "Could not enable Match screen edges. Check Accessibility access.")
        }
        self.tap = tap
        self.warpSource = warpSource
        self.source = source
        previous = CGEvent(source: nil)?.location
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ event: CGEvent) {
        let point = event.location
        defer { previous = event.location }
        guard let previous, warpSource != nil else { return }
        // A drag, another tool's warp, or a display change may have moved the
        // pointer since our last mouseMoved event; don't bridge that jump.
        let delta = CGPoint(x: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
                            y: CGFloat(event.getIntegerValueField(.mouseEventDeltaY)))
        guard abs(point.x - previous.x) <= max(80, abs(delta.x) * 4),
              abs(point.y - previous.y) <= max(80, abs(delta.y) * 4),
              let destination = ScreenEdges.destination(from: previous, to: point, delta: delta, layout: layout) else { return }
        if CGWarpMouseCursorPosition(destination) == .success {
            event.location = destination
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        warpSource = nil
        source = nil
        previous = nil
        layout = []
    }

    deinit { stop() }
}
