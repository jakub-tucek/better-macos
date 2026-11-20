import AppKit

/// Ported from Shottie's core tests: rendering, editing, collage, export and Recent Captures.
enum ScreenshotCoreChecks {
    static let red = ShotRGBA(hex: 0xFF0000)

    static func solid(_ color: ShotRGBA, width: Int, height: Int) -> CGImage {
        let ctx = ShotRenderer.makeContext(width: width, height: height)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func hex(_ image: CGImage, _ x: Int, _ y: Int) -> String {
        ShotExporter.sample(image, x: x, y: y)!.hexString
    }

    static func testRectStrokeLandsAtTopLeftOrigin() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 200, height: 100), scale: 1)
        model.add(ShotAnnotation(kind: .rect, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 80, y: 50), color: red, width: 4))
        let out = ShotRenderer.flatten(model.state)
        expect(hex(out, 50, 10) == "#FF0000", "Screenshots rect stroke lands at top left origin: top edge")
        expect(hex(out, 50, 50) == "#FF0000", "Screenshots rect stroke lands at top left origin: bottom edge")
        expect(hex(out, 50, 30) == "#FFFFFF", "Screenshots rect stroke lands at top left origin: interior stays clear")
        expect(hex(out, 50, 90) == "#FFFFFF", "Screenshots rect stroke lands at top left origin: nothing mirrored to the bottom")
    }

    static func testCropChangesOutputSizeAndOffsetsAnnotations() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 200, height: 100), scale: 1)
        model.add(ShotAnnotation(kind: .rect, start: CGPoint(x: 60, y: 40), end: CGPoint(x: 100, y: 80), color: red, width: 4))
        model.applyCrop(CGRect(x: 50, y: 30, width: 100, height: 60))
        let out = ShotRenderer.flatten(model.state)
        expect(out.width == 100, "Screenshots crop changes output size and offsets annotations #1")
        expect(out.height == 60, "Screenshots crop changes output size and offsets annotations #2")
        expect(hex(out, 30, 10) == "#FF0000", "Screenshots crop changes output size and offsets annotations #3")
        model.undo()
        expect(ShotRenderer.flatten(model.state).width == 200, "Screenshots crop changes output size and offsets annotations #4")
    }

    static func testUndoRedo() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 50, height: 50), scale: 1)
        let a = ShotAnnotation(kind: .line, start: .zero, end: CGPoint(x: 10, y: 10), color: red, width: 1)
        model.add(a)
        model.selectedID = a.id
        model.undo()
        expect(model.state.annotations.isEmpty, "Screenshots undo redo #1")
        expect(model.selectedID == nil, "Screenshots undo redo: selection of an undone annotation is dropped")
        model.redo()
        expect(model.state.annotations.count == 1, "Screenshots undo redo #3")
    }

    static func testTextDrawsUprightInsideItsBounds() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 300, height: 100), scale: 1)
        var text = ShotAnnotation(kind: .text, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 10), color: red, width: 1)
        text.text = "Hello"
        text.fontSize = 30
        model.add(text)
        let out = ShotRenderer.flatten(model.state)
        let box = text.bounds
        var inside = 0
        for x in stride(from: Int(box.minX), to: Int(box.maxX), by: 1) {
            for y in stride(from: Int(box.minY), to: Int(box.maxY), by: 1) where hex(out, x, y) == "#FF0000" { inside += 1 }
        }
        expect(inside > 50, "Screenshots text draws upright inside its bounds #1")
        for x in stride(from: 0, to: 300, by: 3) { expect(hex(out, x, 90) == "#FFFFFF", "Screenshots text draws upright inside its bounds: no ink below the box") }
    }

    static func testBlurDestroysDetail() {
        let ctx = ShotRenderer.makeContext(width: 100, height: 100)
        for x in 0..<100 {
            ctx.setFillColor((x % 2 == 0 ? ShotRGBA(hex: 0) : ShotRGBA(hex: 0xFFFFFF)).cgColor)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 100))
        }
        let model = ShotEditorModel(image: ctx.makeImage()!, scale: 1)
        model.add(ShotAnnotation(kind: .blur, start: .zero, end: CGPoint(x: 100, y: 100), color: red, width: 1))
        let out = ShotRenderer.flatten(model.state)
        expect(hex(out, 40, 40) == hex(out, 41, 40), "Screenshots blur destroys detail: adjacent stripes merge")
    }

    static func testSpotlightDimsOutsideOnly() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 100, height: 100), scale: 1)
        model.add(ShotAnnotation(kind: .spotlight, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 60), color: red, width: 1))
        let out = ShotRenderer.flatten(model.state)
        expect(hex(out, 40, 40) == "#FFFFFF", "Screenshots spotlight dims outside only #1")
        expect(hex(out, 80, 80) != "#FFFFFF", "Screenshots spotlight dims outside only #2")
    }

    static func testMeasureSnapsToAxis() {
        var a = ShotAnnotation(kind: .measure, start: .zero, end: CGPoint(x: 100, y: 12), color: red, width: 1)
        a.snapMeasure()
        expect(a.end == CGPoint(x: 100, y: 0), "Screenshots measure snaps to axis #1")
    }

    static func testHandleResizeKeepsOppositeCorner() {
        var a = ShotAnnotation(kind: .rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50), color: red, width: 1)
        a.moveHandle(3, to: CGPoint(x: 90, y: 70))
        expect(a.rect == CGRect(x: 10, y: 10, width: 80, height: 60), "Screenshots handle resize keeps opposite corner #1")
    }

    static func testHitTesting() {
        let line = ShotAnnotation(kind: .line, start: .zero, end: CGPoint(x: 100, y: 100), color: red, width: 2)
        expect(line.hitTest(CGPoint(x: 50, y: 52), tolerance: 3), "Screenshots hit testing #1")
        expect(!(line.hitTest(CGPoint(x: 50, y: 80), tolerance: 3)), "Screenshots hit testing #2")
    }

    static func testCounterNumbersIncrement() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 50, height: 50), scale: 1)
        var c = ShotAnnotation(kind: .counter, start: .zero, end: .zero, color: red, width: 1)
        c.number = model.nextCounterNumber
        model.add(c)
        expect(model.nextCounterNumber == 2, "Screenshots counter numbers increment #1")
    }

    static func testCollageHorizontalLayoutAndGap() {
        let a = solid(ShotRGBA(hex: 0xFF0000), width: 40, height: 40)
        let b = solid(ShotRGBA(hex: 0x0000FF), width: 60, height: 20)
        let out = ShotCollage.stitch([a, b], layout: .horizontal, gap: 10)!
        expect(out.width == 110, "Screenshots collage horizontal layout and gap #1")
        expect(out.height == 40, "Screenshots collage horizontal layout and gap #2")
        expect(hex(out, 5, 5) == "#FF0000", "Screenshots collage horizontal layout and gap #3")
        expect(hex(out, 60, 20) == "#0000FF", "Screenshots collage horizontal layout and gap: shorter image is vertically centered")
        expect(ShotExporter.sample(out, x: 45, y: 20)!.a == 0, "Screenshots collage horizontal layout and gap: gap is transparent")
        expect(ShotExporter.sample(out, x: 60, y: 2)!.a == 0, "Screenshots collage horizontal layout and gap: above centered image is transparent")
    }

    static func testCollageGrid() {
        let images = (0..<5).map { _ in solid(ShotRGBA(hex: 0x00FF00), width: 10, height: 10) }
        expect(ShotCollage.gridColumns(for: 5) == 3, "Screenshots collage grid #1")
        let out = ShotCollage.stitch(images, layout: .grid(columns: 3), gap: 2)!
        expect(out.width == 34, "Screenshots collage grid #2")
        expect(out.height == 22, "Screenshots collage grid #3")
    }

    static func testAppendToCollageBakesAnnotationsAndUndoes() {
        let model = ShotEditorModel(image: solid(.init(hex: 0xFFFFFF), width: 50, height: 50), scale: 1)
        model.add(ShotAnnotation(kind: .rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 40, y: 40), color: red, width: 4))
        model.appendToCollage(solid(ShotRGBA(hex: 0x0000FF), width: 50, height: 50), direction: .below, gap: 0)
        expect(model.state.annotations.count == 0, "Screenshots append to collage bakes annotations and undoes #1")
        let out = ShotRenderer.flatten(model.state)
        expect(out.height == 100, "Screenshots append to collage bakes annotations and undoes #2")
        expect(hex(out, 25, 10) == "#FF0000", "Screenshots append to collage bakes annotations and undoes #3")
        expect(hex(out, 25, 75) == "#0000FF", "Screenshots append to collage bakes annotations and undoes #4")
        model.undo()
        expect(model.state.annotations.count == 1, "Screenshots append to collage bakes annotations and undoes #5")
        expect(ShotRenderer.flatten(model.state).height == 50, "Screenshots append to collage bakes annotations and undoes #6")
    }

    static func testBeautifyOutputAndCorners() {
        var state = ShotDocumentState(base: solid(ShotRGBA(hex: 0x123456), width: 100, height: 100), scale: 2)
        state.beautify = ShotBeautifyStyle(background: 5, padding: 10)
        let out = ShotRenderer.flatten(state)
        expect(out.width == 140, "Screenshots beautify output and corners #1")
        expect(hex(out, 70, 70) == "#123456", "Screenshots beautify output and corners #2")
        expect(hex(out, 21, 21) != "#123456", "Screenshots beautify output and corners: corner is rounded")
    }

    static func testBeautifyDoesNotBlackenTransparentContent() {
        let gap = ShotCollage.stitch([solid(ShotRGBA(hex: 0xFF0000), width: 20, height: 20), solid(ShotRGBA(hex: 0xFF0000), width: 20, height: 20)], layout: .horizontal, gap: 20)!
        var state = ShotDocumentState(base: gap, scale: 1)
        state.beautify = ShotBeautifyStyle(background: 5, padding: 40)
        expect(ShotExporter.sample(ShotRenderer.flatten(state), x: 70, y: 50)!.r > 0.8, "Screenshots beautify does not blacken transparent content: gap shows the backdrop")
    }

    static func testCollageDropsBeautifyAfterBakingIt() {
        let model = ShotEditorModel(image: solid(ShotRGBA(hex: 0xFFFFFF), width: 50, height: 50), scale: 1)
        model.mutate { $0.beautify = ShotBeautifyStyle(background: 0, padding: 10) }
        model.appendToCollage(solid(ShotRGBA(hex: 0x0000FF), width: 70, height: 70), direction: .right, gap: 0)
        expect(model.state.beautify == nil, "Screenshots collage drops beautify after baking it #1")
        expect(model.state.base.width == 140, "Screenshots collage drops beautify after baking it #2")
    }

    static func testRecentDocumentRoundTripsEveryField() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ShotRecentCaptures.folderOverride = folder
        defer {
            ShotRecentCaptures.flush()
            ShotRecentCaptures.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let url = ShotRecentCaptures.add(ShotCapturedImage(image: solid(ShotRGBA(hex: 0x00FF00), width: 200, height: 100), scale: 2))

        var state = ShotDocumentState(base: solid(ShotRGBA(hex: 0x00FF00), width: 200, height: 100), scale: 2)
        state.crop = CGRect(x: 10, y: 10, width: 150, height: 80)
        state.beautify = ShotBeautifyStyle(background: 3, padding: 24)
        var text = ShotAnnotation(kind: .text, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 20, y: 20), color: red, width: 6)
        text.text = "Ahoj ✎"
        text.fontSize = 44
        var pen = ShotAnnotation(kind: .pen, start: .zero, end: .zero, color: red, width: 6)
        pen.points = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        var counter = ShotAnnotation(kind: .counter, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 5, y: 5), color: red, width: 6)
        counter.number = 7
        var pasted = ShotAnnotation(kind: .image, start: .zero, end: CGPoint(x: 30, y: 30), color: red, width: 0)
        pasted.image = solid(ShotRGBA(hex: 0x0000FF), width: 30, height: 30)
        state.annotations = [text, pen, counter, pasted]

        expect(!(ShotRecentCaptures.hasEdits(url)), "Screenshots recent document round trips every field #1")
        ShotRecentCaptures.save(state, to: url, writeBase: false)
        guard let loaded = ShotRecentCaptures.load(url) else { expect(false, "Screenshots recent document loads"); return }
        expect(ShotRecentCaptures.hasEdits(url), "Screenshots recent document round trips every field #2")
        expect(loaded.crop == state.crop, "Screenshots recent document round trips every field #3")
        expect(loaded.scale == 2, "Screenshots recent document round trips every field #4")
        expect(loaded.beautify == state.beautify, "Screenshots recent document round trips every field #5")
        expect(loaded.annotations.map(\.kind) == [.text, .pen, .counter, .image], "Screenshots recent document round trips every field #6")
        expect(loaded.annotations[0].text == "Ahoj ✎", "Screenshots recent document round trips every field #7")
        expect(loaded.annotations[1].points == pen.points, "Screenshots recent document round trips every field #8")
        expect(loaded.annotations[2].number == 7, "Screenshots recent document round trips every field #9")
        expect(loaded.annotations[3].image.map { hex($0, 5, 5) } == "#0000FF", "Screenshots recent document round trips every field #10")
        expect(ShotRenderer.flatten(loaded).width == ShotRenderer.flatten(state).width, "Screenshots recent document round trips every field #11")
    }

    static func testRecentPruningRemovesSidecars() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ShotRecentCaptures.folderOverride = folder
        defer {
            ShotRecentCaptures.flush()
            ShotRecentCaptures.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let image = ShotCapturedImage(image: solid(ShotRGBA(hex: 0), width: 4, height: 4), scale: 1)
        let first = ShotRecentCaptures.add(image)
        ShotRecentCaptures.save(ShotDocumentState(base: image.image, scale: 1), to: first, writeBase: false)
        for _ in 0..<22 { ShotRecentCaptures.add(image) }
        ShotRecentCaptures.flush()
        expect(ShotRecentCaptures.list().count == 20, "Screenshots recent pruning removes sidecars #1")
        expect(!(ShotRecentCaptures.hasEdits(first)), "Screenshots recent pruning removes sidecars #2")
    }

    static func testPNGRoundTripPreservesPixelsAndScale() {
        let image = solid(ShotRGBA(hex: 0x1C2022), width: 20, height: 10)
        let data = ShotExporter.encode(image, scale: 2)!
        let loaded = ShotExporter.load(data: data)!
        expect(loaded.scale == 2, "Screenshots pnground trip preserves pixels and scale #1")
        expect(hex(loaded.image, 3, 3) == "#1C2022", "Screenshots pnground trip preserves pixels and scale #2")
    }
}
