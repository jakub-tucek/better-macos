import AppKit

struct ShotRGBA: Equatable, Codable {
    var r, g, b, a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32) {
        self.init(r: CGFloat((hex >> 16) & 0xFF) / 255,
                  g: CGFloat((hex >> 8) & 0xFF) / 255,
                  b: CGFloat(hex & 0xFF) / 255)
    }

    var hexString: String {
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.6 }

    /// Black or white, whichever reads against this color.
    var contrasting: ShotRGBA { isLight ? ShotRGBA(r: 0, g: 0, b: 0) : ShotRGBA(r: 1, g: 1, b: 1) }

    static let presets: [(name: String, color: ShotRGBA)] = [
        ("Red", ShotRGBA(hex: 0xFF3B30)), ("Orange", ShotRGBA(hex: 0xFF9500)),
        ("Yellow", ShotRGBA(hex: 0xFFCC00)), ("Green", ShotRGBA(hex: 0x34C759)),
        ("Blue", ShotRGBA(hex: 0x0A84FF)), ("Purple", ShotRGBA(hex: 0xAF52DE)),
        ("Black", ShotRGBA(hex: 0x000000)), ("White", ShotRGBA(hex: 0xFFFFFF)),
    ]
}

enum ShotTool: String, CaseIterable {
    case select, crop, arrow, text, measure, rect, blur
    case ellipse, line, pen, highlighter, counter, spotlight

    var key: Character {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .text: return "t"
        case .measure: return "m"
        case .rect: return "r"
        case .blur: return "b"
        case .ellipse: return "o"
        case .line: return "l"
        case .pen: return "p"
        case .highlighter: return "h"
        case .counter: return "n"
        case .spotlight: return "s"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .measure: return "Measure"
        case .rect: return "Box"
        case .blur: return "Pixelate"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .counter: return "Numbered Step"
        case .spotlight: return "Spotlight"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .measure: return "ruler"
        case .rect: return "rectangle"
        case .blur: return "checkerboard.rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .counter: return "1.circle"
        case .spotlight: return "rectangle.inset.filled"
        }
    }

    var annotationKind: ShotAnnotation.Kind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .text: return .text
        case .measure: return .measure
        case .rect: return .rect
        case .blur: return .blur
        case .ellipse: return .ellipse
        case .line: return .line
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .counter: return .counter
        case .spotlight: return .spotlight
        }
    }
}

/// All coordinates are base-image pixels, y-down.
struct ShotAnnotation: Identifiable {
    enum Kind: String, Codable { case rect, ellipse, arrow, line, pen, highlighter, text, blur, spotlight, counter, measure, image }

    var id: UUID
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: ShotRGBA
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat = 0
    var number = 0
    var image: CGImage?

    init(kind: Kind, start: CGPoint, end: CGPoint, color: ShotRGBA, width: CGFloat) {
        self.id = UUID()
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.width = width
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isRectLike: Bool { [.rect, .ellipse, .blur, .spotlight, .image].contains(kind) }
    var isLineLike: Bool { [.arrow, .line, .measure].contains(kind) }

    var counterRadius: CGFloat { max(fontSize, width * 4) * 0.62 }

    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: ShotRenderer.textSize(self))
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        default:
            return rect
        }
    }

    var isDegenerate: Bool {
        switch kind {
        case .text: return text.isEmpty
        case .counter: return false
        case .pen, .highlighter: return points.count < 2
        case .arrow, .line, .measure: return hypot(end.x - start.x, end.y - start.y) < 4
        default: return rect.width < 4 || rect.height < 4
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line, .measure:
            return Self.distance(p, segment: start, end) <= tolerance + width / 2
        case .pen, .highlighter:
            return zip(points, points.dropFirst()).contains {
                Self.distance(p, segment: $0, $1) <= tolerance + width / 2
            }
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Corner handles for boxes (tl, tr, bl, br); endpoints for lines; none otherwise.
    var handles: [CGPoint] {
        if isRectLike {
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        }
        return isLineLike ? [start, end] : []
    }

    mutating func moveHandle(_ index: Int, to p: CGPoint) {
        if isRectLike {
            let opposite = handles[3 - index]
            start = opposite
            end = p
            if kind == .image, let image { end = Self.aspectFitted(from: opposite, to: p, image: image) }
        } else if isLineLike {
            if index == 0 { start = p } else { end = p }
            if kind == .measure { snapMeasure(anchorIsStart: index != 0) }
        }
    }

    static func aspectFitted(from a: CGPoint, to p: CGPoint, image: CGImage) -> CGPoint {
        let aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        let w = abs(p.x - a.x)
        return CGPoint(x: p.x, y: a.y + (p.y >= a.y ? 1 : -1) * w / aspect)
    }

    /// Measurements are always horizontal or vertical.
    mutating func snapMeasure(anchorIsStart: Bool = true) {
        if anchorIsStart {
            if abs(end.x - start.x) >= abs(end.y - start.y) { end.y = start.y } else { end.x = start.x }
        } else {
            if abs(end.x - start.x) >= abs(end.y - start.y) { start.y = end.y } else { start.x = end.x }
        }
    }
}

/// Backdrop, padding and rounded corners around the screenshot. Sizes are points.
struct ShotBeautifyStyle: Equatable, Codable {
    var background: Int
    var padding: CGFloat
    var cornerRadius: CGFloat = 12

    init(background: Int, padding: CGFloat) {
        self.background = background
        self.padding = padding
    }

    static let backgrounds: [(name: String, from: ShotRGBA, to: ShotRGBA)] = [
        ("Graphite", ShotRGBA(hex: 0x2A2A2A), ShotRGBA(hex: 0x0A0A0A)),
        ("Periwinkle", ShotRGBA(hex: 0xA5B4FC), ShotRGBA(hex: 0x6366F1)),
        ("Sunset", ShotRGBA(hex: 0xFDBA74), ShotRGBA(hex: 0xEC4899)),
        ("Ocean", ShotRGBA(hex: 0x67E8F9), ShotRGBA(hex: 0x2563EB)),
        ("Mint", ShotRGBA(hex: 0x6EE7B7), ShotRGBA(hex: 0x0EA5E9)),
        ("Paper", ShotRGBA(hex: 0xFFFFFF), ShotRGBA(hex: 0xE5E5E5)),
    ]

    static let paddings: [(name: String, points: CGFloat)] = [("Small", 24), ("Medium", 48), ("Large", 80)]
}

struct ShotDocumentState {
    var base: CGImage
    /// Non-destructive visible region of `base`, in pixels.
    var crop: CGRect
    var annotations: [ShotAnnotation] = []
    /// Pixels per point of the source display.
    var scale: CGFloat
    var beautify: ShotBeautifyStyle?

    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.crop = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        self.scale = scale
    }

    var paddingPixels: CGFloat { (beautify?.padding ?? 0) * scale }

    /// Pixel size of the exported image, including any beautify padding.
    var outputSize: CGSize {
        CGSize(width: crop.width + paddingPixels * 2, height: crop.height + paddingPixels * 2)
    }

    var pointSize: CGSize { CGSize(width: outputSize.width / scale, height: outputSize.height / scale) }
}

enum ShotCollageDirection { case right, below }

/// Editable document with snapshot undo. Snapshots are cheap: images are shared by reference.
final class ShotEditorModel {
    private(set) var state: ShotDocumentState
    var selectedID: UUID?
    private var undoStack: [ShotDocumentState] = []
    private var redoStack: [ShotDocumentState] = []
    private static let undoLimit = 100

    init(image: CGImage, scale: CGFloat) {
        state = ShotDocumentState(base: image, scale: scale)
    }

    init(state: ShotDocumentState) {
        self.state = state
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selected: ShotAnnotation? { state.annotations.first { $0.id == selectedID } }

    func mutate(_ change: (inout ShotDocumentState) -> Void) {
        undoStack.append(state)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        change(&state)
    }

    /// Live update during a gesture; pair with `pushUndo(of:)` when the gesture ends.
    func updateWithoutUndo(_ change: (inout ShotDocumentState) -> Void) { change(&state) }

    func pushUndo(of snapshot: ShotDocumentState) {
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        dropStaleSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        dropStaleSelection()
    }

    private func dropStaleSelection() {
        if selected == nil { selectedID = nil }
    }

    func add(_ annotation: ShotAnnotation) {
        mutate { $0.annotations.append(annotation) }
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        mutate { $0.annotations.removeAll { $0.id == id } }
        selectedID = nil
    }

    func updateSelected(_ change: (inout ShotAnnotation) -> Void) {
        guard let id = selectedID else { return }
        mutate { state in
            if let i = state.annotations.firstIndex(where: { $0.id == id }) { change(&state.annotations[i]) }
        }
    }

    var nextCounterNumber: Int {
        (state.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    func applyCrop(_ rect: CGRect) {
        let clipped = rect.integral.intersection(state.crop)
        guard clipped.width >= 1, clipped.height >= 1 else { return }
        mutate { $0.crop = clipped }
    }

    func topmost(at p: CGPoint, tolerance: CGFloat) -> ShotAnnotation? {
        state.annotations.last { $0.hitTest(p, tolerance: tolerance) }
    }

    /// Bakes annotations into the image and stitches `image` next to it.
    func appendToCollage(_ image: CGImage, direction: ShotCollageDirection, gap: Int) {
        let flat = ShotRenderer.flatten(state)
        let layout: ShotCollage.Layout = direction == .right ? .horizontal : .vertical
        guard let stitched = ShotCollage.stitch([flat, image], layout: layout, gap: gap) else { return }
        mutate {
            $0.base = stitched
            $0.crop = CGRect(x: 0, y: 0, width: stitched.width, height: stitched.height)
            $0.annotations = []
            $0.beautify = nil
        }
        selectedID = nil
    }
}
