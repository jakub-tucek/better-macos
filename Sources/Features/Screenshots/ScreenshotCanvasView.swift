import AppKit

@MainActor
protocol ShotCanvasDelegate: AnyObject {
    func canvasDidChange()
    func canvasHover(color: ShotRGBA?)
    func canvasRequestCopy()
    func canvasRequestClose()
    func canvasSetTool(_ tool: ShotTool)
    func canvasCopyHoverColor()
    func canvasZoomChanged()
    func canvasToast(_ message: String)
    func canvasToggleBeautify()
}

/// Displays the document and turns mouse/keyboard input into model edits.
final class ShotCanvasView: NSView, NSTextViewDelegate {
    let model: ShotEditorModel
    weak var delegate: ShotCanvasDelegate?

    var tool: ShotTool = .rect {
        didSet {
            commitText()
            if tool != .select { model.selectedID = nil }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color = ShotRGBA.presets[0].color
    var strokePoints: CGFloat = 3
    var fontPoints: CGFloat = 22
    private(set) var zoom: CGFloat = 1
    private(set) var hoverColor: ShotRGBA?

    private enum Gesture {
        case none
        case drawing(ShotAnnotation)
        case moving(id: UUID, last: CGPoint, snapshot: ShotDocumentState, moved: Bool)
        case resizing(id: UUID, handle: Int, snapshot: ShotDocumentState)
        case cropping(anchor: CGPoint, current: CGPoint)
    }
    private var gesture = Gesture.none

    private var textView: ShotAnnotationTextView?
    private var editingID: UUID?
    private var editingOriginal: ShotAnnotation?
    private var textOrigin: CGPoint = .zero

    private var trackingArea: NSTrackingArea?

    init(model: ShotEditorModel) {
        self.model = model
        super.init(frame: .zero)
        syncFrame()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var state: ShotDocumentState { model.state }
    private var viewScale: CGFloat { zoom / state.scale }

    func setZoom(_ value: CGFloat) {
        commitText()
        zoom = min(max(value, 0.05), 16)
        syncFrame()
        delegate?.canvasZoomChanged()
    }

    func syncFrame() {
        let size = CGSize(width: (state.outputSize.width * viewScale).rounded(), height: (state.outputSize.height * viewScale).rounded())
        setFrameSize(size)
        needsDisplay = true
    }

    func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / viewScale - state.paddingPixels + state.crop.minX,
                y: viewPoint.y / viewScale - state.paddingPixels + state.crop.minY)
    }

    func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: (imagePoint.x - state.crop.minX + state.paddingPixels) * viewScale,
                y: (imagePoint.y - state.crop.minY + state.paddingPixels) * viewScale)
    }

    private func eventPoint(_ event: NSEvent) -> CGPoint {
        imagePoint(convert(event.locationInWindow, from: nil))
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, state.crop.minX), state.crop.maxX), y: min(max(p.y, state.crop.minY), state.crop.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.interpolationQuality = zoom >= 1 ? .none : .medium

        var extra: ShotAnnotation?
        if case .drawing(let annotation) = gesture { extra = annotation }
        ShotRenderer.compose(state, in: ctx, hiding: editingID, extra: extra)
        ctx.restoreGState()

        drawSelectionChrome(ctx)
        if case .cropping(let anchor, let current) = gesture { drawCropChrome(ctx, anchor: anchor, current: current) }
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        guard tool == .select, let selected = model.selected, editingID == nil else { return }
        let box = viewRect(selected.bounds).insetBy(dx: -4, dy: -4)
        if !selected.isLineLike {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(box)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for handle in selected.handles {
            let p = viewPoint(handle)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: r)
        }
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        let o = viewPoint(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * viewScale, height: r.height * viewScale)
    }

    private func drawCropChrome(_ ctx: CGContext, anchor: CGPoint, current: CGPoint) {
        let rect = viewRect(rectBetween(anchor, current))
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(rect)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect)
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Cursor & hover

    override func resetCursorRects() {
        switch tool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(eventPoint(event)) }
    override func mouseEntered(with event: NSEvent) { updateHover(eventPoint(event)) }
    override func mouseExited(with event: NSEvent) { }

    private func updateHover(_ p: CGPoint) {
        hoverColor = ShotExporter.sample(state.base, x: Int(p.x), y: Int(p.y)) ?? hoverColor
        delegate?.canvasHover(color: hoverColor)
    }

    // MARK: Mouse

    private var hitTolerance: CGFloat { 5 / viewScale }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let textWasOpen = textView != nil
        commitText()
        let p = clamped(eventPoint(event))

        switch tool {
        case .select:
            beginSelectGesture(at: p, event: event)
        case .crop:
            gesture = .cropping(anchor: p, current: p)
        case .text:
            if textWasOpen { break } // The click only dismissed the previous text box.
            if let existing = model.topmost(at: p, tolerance: hitTolerance), existing.kind == .text {
                beginEditing(existing)
            } else {
                beginEditing(nil, at: p)
            }
        case .counter:
            var a = newAnnotation(.counter, at: p)
            a.number = model.nextCounterNumber
            model.add(a)
            changed()
        default:
            guard let kind = tool.annotationKind else { return }
            var a = newAnnotation(kind, at: p)
            if kind == .pen || kind == .highlighter { a.points = [p] }
            if kind == .highlighter { a.width = strokePoints * state.scale * 5; a.color = color }
            gesture = .drawing(a)
        }
        needsDisplay = true
    }

    private func newAnnotation(_ kind: ShotAnnotation.Kind, at p: CGPoint) -> ShotAnnotation {
        var a = ShotAnnotation(kind: kind, start: p, end: p, color: color, width: strokePoints * state.scale)
        a.fontSize = fontPoints * state.scale
        return a
    }

    private func beginSelectGesture(at p: CGPoint, event: NSEvent) {
        if let selected = model.selected {
            for (i, handle) in selected.handles.enumerated() where hypot(handle.x - p.x, handle.y - p.y) <= 7 / viewScale {
                gesture = .resizing(id: selected.id, handle: i, snapshot: state)
                return
            }
        }
        guard let hit = model.topmost(at: p, tolerance: hitTolerance) else {
            model.selectedID = nil
            return
        }
        model.selectedID = hit.id
        if event.clickCount == 2, hit.kind == .text {
            beginEditing(hit)
            return
        }
        gesture = .moving(id: hit.id, last: p, snapshot: state, moved: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = eventPoint(event)
        let p = clamped(raw)
        switch gesture {
        case .none:
            return
        case .drawing(var a):
            updateDrawing(&a, to: p, constrain: event.modifierFlags.contains(.shift))
            gesture = .drawing(a)
        case .moving(let id, let last, let snapshot, _):
            modify(id) { $0.translate(dx: raw.x - last.x, dy: raw.y - last.y) }
            gesture = .moving(id: id, last: raw, snapshot: snapshot, moved: true)
        case .resizing(let id, let handle, _):
            modify(id) { $0.moveHandle(handle, to: p) }
        case .cropping(let anchor, _):
            gesture = .cropping(anchor: anchor, current: p)
        }
        needsDisplay = true
    }

    private func updateDrawing(_ a: inout ShotAnnotation, to p: CGPoint, constrain: Bool) {
        switch a.kind {
        case .pen, .highlighter:
            a.points.append(p)
            if a.kind == .highlighter, constrain { a.points = [a.points[0], CGPoint(x: p.x, y: a.points[0].y)] }
        case .measure:
            a.end = p
            a.snapMeasure()
        case .rect, .ellipse, .blur, .spotlight:
            a.end = p
            if constrain {
                let side = max(abs(p.x - a.start.x), abs(p.y - a.start.y))
                a.end = CGPoint(x: a.start.x + (p.x >= a.start.x ? side : -side), y: a.start.y + (p.y >= a.start.y ? side : -side))
            }
        case .arrow, .line:
            a.end = p
            if constrain {
                let angle = atan2(p.y - a.start.y, p.x - a.start.x)
                let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(p.x - a.start.x, p.y - a.start.y)
                a.end = CGPoint(x: a.start.x + cos(snapped) * length, y: a.start.y + sin(snapped) * length)
            }
        default:
            break
        }
    }

    private func modify(_ id: UUID, _ change: (inout ShotAnnotation) -> Void) {
        model.updateWithoutUndo { state in
            if let i = state.annotations.firstIndex(where: { $0.id == id }) { change(&state.annotations[i]) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = gesture
        gesture = .none
        switch finished {
        case .none:
            break
        case .drawing(let a):
            if !a.isDegenerate { model.add(a) }
        case .moving(_, _, let snapshot, let moved):
            if moved { model.pushUndo(of: snapshot) }
        case .resizing(_, _, let snapshot):
            model.pushUndo(of: snapshot)
        case .cropping(let anchor, let current):
            let rect = rectBetween(anchor, current)
            if rect.width >= 4, rect.height >= 4 {
                model.applyCrop(rect)
                syncFrame()
                delegate?.canvasSetTool(.select)
            }
        }
        changed()
    }

    private func changed() {
        needsDisplay = true
        delegate?.canvasDidChange()
    }

    // MARK: Zoom gestures

    override func magnify(with event: NSEvent) { setZoom(zoom * (1 + event.magnification)) }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(zoom * (1 + event.scrollingDeltaY * 0.01))
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        switch event.keyCode {
        case 48: delegate?.canvasCopyHoverColor(); return // Tab
        case 53: // Esc
            if model.selectedID != nil {
                model.selectedID = nil
                needsDisplay = true
            } else {
                delegate?.canvasRequestClose()
            }
            return
        case 51, 117: model.removeSelected(); changed(); return // Delete
        case 36, 76: // Return re-opens the selected text box
            if let selected = model.selected, selected.kind == .text { beginEditing(selected) }
            return
        case 123, 124, 125, 126: nudge(event); return
        default: break
        }
        guard plain, let c = event.charactersIgnoringModifiers?.lowercased().first else {
            super.keyDown(with: event)
            return
        }
        switch c {
        case "f": delegate?.canvasToggleBeautify()
        case "[": adjustSize(by: -1)
        case "]": adjustSize(by: 1)
        case "i":
            if let hoverColor {
                setColor(hoverColor)
                delegate?.canvasToast("Color \(hoverColor.hexString)")
                delegate?.canvasDidChange()
            }
        default:
            if let tool = ShotTool.allCases.first(where: { $0.key == c }) {
                delegate?.canvasSetTool(tool)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func nudge(_ event: NSEvent) {
        guard model.selectedID != nil else { return }
        let step = (event.modifierFlags.contains(.shift) ? 10 : 1) * state.scale
        let (dx, dy): (CGFloat, CGFloat) = {
            switch event.keyCode {
            case 123: return (-step, 0)
            case 124: return (step, 0)
            case 125: return (0, step)
            default: return (0, -step)
            }
        }()
        model.updateSelected { $0.translate(dx: dx, dy: dy) }
        changed()
    }

    private func adjustSize(by steps: CGFloat) {
        if let selected = model.selected {
            model.updateSelected {
                if selected.kind == .text || selected.kind == .counter {
                    $0.fontSize = max(8 * state.scale, $0.fontSize + steps * 2 * state.scale)
                } else {
                    $0.width = max(state.scale, $0.width + steps * state.scale)
                }
            }
            changed()
        } else if tool == .text || tool == .counter {
            fontPoints = max(8, fontPoints + steps * 2)
        } else {
            strokePoints = max(1, strokePoints + steps)
        }
    }

    func setStroke(points: CGFloat) {
        strokePoints = points
        if model.selected != nil, model.selected?.kind != .text {
            model.updateSelected { $0.width = points * state.scale }
            changed()
        }
    }

    func setColor(_ value: ShotRGBA) {
        color = value
        if model.selected != nil {
            model.updateSelected { $0.color = value }
            changed()
        }
    }

    // MARK: Responder actions (menu items and key equivalents)

    @objc func copy(_ sender: Any?) { delegate?.canvasRequestCopy() }

    @objc func undo(_ sender: Any?) {
        model.undo()
        syncFrame()
        changed()
    }

    @objc func redo(_ sender: Any?) {
        model.redo()
        syncFrame()
        changed()
    }

    @objc func delete(_ sender: Any?) {
        model.removeSelected()
        changed()
    }

    @objc func paste(_ sender: Any?) {
        guard let image = ShotExporter.image(fromPasteboard: ShotExporter.pasteboard) else {
            delegate?.canvasToast("No image on the clipboard")
            return
        }
        insertImage(image)
    }

    func insertImage(_ image: CGImage) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let fit = min(1, min(state.crop.width / w, state.crop.height / h))
        let size = CGSize(width: w * fit, height: h * fit)
        let origin = CGPoint(x: state.crop.midX - size.width / 2, y: state.crop.midY - size.height / 2)
        var a = ShotAnnotation(kind: .image, start: origin,
                           end: CGPoint(x: origin.x + size.width, y: origin.y + size.height), color: color, width: 0)
        a.image = image
        model.add(a)
        delegate?.canvasSetTool(.select)
        model.selectedID = a.id
        changed()
    }

    // MARK: Text editing

    private func beginEditing(_ existing: ShotAnnotation?, at point: CGPoint = .zero) {
        let seed = existing ?? newAnnotation(.text, at: point)
        editingID = existing?.id
        editingOriginal = seed
        textOrigin = seed.start

        let fontSize = seed.fontSize * viewScale
        let view = ShotAnnotationTextView(frame: CGRect(origin: viewPoint(seed.start), size: CGSize(width: 40, height: fontSize * 1.3)))
        view.font = .systemFont(ofSize: fontSize, weight: .semibold)
        view.textColor = seed.color.nsColor
        view.insertionPointColor = seed.color.nsColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.size = CGSize(width: 100_000, height: 100_000)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.delegate = self
        view.onFinish = { [weak self] in self?.commitText() }
        view.string = seed.text
        addSubview(view)
        textView = view
        window?.makeFirstResponder(view)
        fitTextView()
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) { fitTextView() }

    private func fitTextView() {
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        view.setFrameSize(CGSize(width: max(20, ceil(used.width) + 6), height: max(view.font?.pointSize ?? 20, ceil(used.height))))
    }

    var isEditingText: Bool { textView != nil }

    /// Ends any open text box, turning it into an annotation.
    func commitText() {
        guard let view = textView, let seed = editingOriginal else { return }
        let text = view.string
        let existingID = editingID
        textView = nil
        editingID = nil
        editingOriginal = nil
        view.removeFromSuperview()
        window?.makeFirstResponder(self)

        if let existingID {
            model.selectedID = existingID
            if text.isEmpty {
                model.removeSelected()
            } else if text != seed.text {
                model.updateSelected { $0.text = text }
            }
        } else if !text.isEmpty {
            var a = seed
            a.text = text
            model.add(a)
            if tool == .select { model.selectedID = a.id }
        }
        changed()
    }
}

/// Return commits, Shift-Return inserts a line break, Esc commits.
final class ShotAnnotationTextView: NSTextView {
    var onFinish: (() -> Void)?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(cancelOperation(_:)), #selector(insertTab(_:)):
            onFinish?()
        default:
            super.doCommand(by: selector)
        }
    }
}
