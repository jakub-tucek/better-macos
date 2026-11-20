import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ShotRenderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws into a context whose CTM is y-down in base-image pixels.
    static func render(_ state: ShotDocumentState, in ctx: CGContext, hiding hidden: UUID? = nil, extra: ShotAnnotation? = nil) {
        draw(state.base, in: CGRect(x: 0, y: 0, width: state.base.width, height: state.base.height), ctx: ctx)

        var items = state.annotations.filter { $0.id != hidden }
        if let extra { items.append(extra) }

        for a in items where a.kind == .blur { drawBlur(a, state: state, ctx: ctx) }

        let spots = items.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: state.base.width, height: state.base.height))
            for s in spots { path.addRect(s.rect) }
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in items where a.kind != .blur && a.kind != .spotlight { draw(a, ctx: ctx, scale: state.scale) }
    }

    /// Draws the whole output, beautify included, into a y-down context whose origin is the output's top left.
    static func compose(_ state: ShotDocumentState, in ctx: CGContext, hiding hidden: UUID? = nil, extra: ShotAnnotation? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let padding = state.paddingPixels
        let content = CGRect(x: padding, y: padding, width: state.crop.width, height: state.crop.height)
        if let style = state.beautify {
            let radius = style.cornerRadius * state.scale
            let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
            drawBackdrop(style, size: state.outputSize, ctx: ctx)
            // Shadow metrics ignore the CTM, so scale them to look the same at every zoom.
            let device = abs(ctx.userSpaceToDeviceSpaceTransform.a) * state.scale
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * device), blur: 36 * device, color: CGColor(gray: 0, alpha: 0.5))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.clip()
            // Transparent parts of the image, like collage gaps, show the backdrop rather than the shadow's fill.
            drawBackdrop(style, size: state.outputSize, ctx: ctx)
        }
        ctx.translateBy(x: padding - state.crop.minX, y: padding - state.crop.minY)
        ctx.clip(to: state.crop)
        render(state, in: ctx, hiding: hidden, extra: extra)
    }

    private static func drawBackdrop(_ style: ShotBeautifyStyle, size: CGSize, ctx: CGContext) {
        let colors = ShotBeautifyStyle.backgrounds[min(max(style.background, 0), ShotBeautifyStyle.backgrounds.count - 1)]
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: [colors.from.cgColor, colors.to.cgColor] as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        ctx.restoreGState()
    }

    /// Renders the output to an image.
    static func flatten(_ state: ShotDocumentState) -> CGImage {
        let w = Int(state.outputSize.width), h = Int(state.outputSize.height)
        let ctx = makeContext(width: w, height: h)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        compose(state, in: ctx)
        return ctx.makeImage()!
    }

    static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Draws upright in a y-down context.
    static func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func draw(_ a: ShotAnnotation, ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .rect:
            ctx.addPath(CGPath(roundedRect: a.rect, cornerWidth: a.width, cornerHeight: a.width, transform: nil))
            ctx.strokePath()
        case .ellipse:
            ctx.strokeEllipse(in: a.rect)
        case .line:
            ctx.strokeLineSegments(between: [a.start, a.end])
        case .arrow:
            drawArrow(a, ctx: ctx)
        case .pen, .highlighter:
            if a.kind == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setLineCap(.butt)
                ctx.setStrokeColor(a.color.nsColor.withAlphaComponent(0.55).cgColor)
            }
            ctx.addLines(between: a.points)
            ctx.strokePath()
        case .text:
            drawText(a, ctx: ctx)
        case .counter:
            drawCounter(a, ctx: ctx)
        case .measure:
            drawMeasure(a, ctx: ctx, scale: scale)
        case .image:
            if let image = a.image { draw(image, in: a.rect, ctx: ctx) }
        case .blur, .spotlight:
            break
        }
    }

    private static func drawArrow(_ a: ShotAnnotation, ctx: CGContext) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let ux = dx / length, uy = dy / length
        let head = min(length * 0.6, a.width * 5)
        let halfHead = head * 0.55
        let neck = CGPoint(x: a.end.x - ux * head * 0.8, y: a.end.y - uy * head * 0.8)
        let base = CGPoint(x: a.end.x - ux * head, y: a.end.y - uy * head)
        func side(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x - uy * d, y: p.y + ux * d) }

        // Shaft tapers from a thin tail into the head.
        let path = CGMutablePath()
        path.addLines(between: [
            side(a.start, a.width * 0.2), side(neck, a.width * 0.55),
            side(base, halfHead), a.end, side(base, -halfHead),
            side(neck, -a.width * 0.55), side(a.start, -a.width * 0.2),
        ])
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setLineWidth(a.width * 0.25)
        ctx.drawPath(using: .fillStroke)
    }

    static func textAttributes(_ a: ShotAnnotation, outline: Bool) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)]
        if outline {
            attrs[.foregroundColor] = a.color.contrasting.nsColor
            attrs[.strokeColor] = a.color.contrasting.nsColor
            attrs[.strokeWidth] = 22
        } else {
            attrs[.foregroundColor] = a.color.nsColor
        }
        return attrs
    }

    static func textSize(_ a: ShotAnnotation) -> CGSize {
        let size = (a.text as NSString).size(withAttributes: textAttributes(a, outline: false))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ a: ShotAnnotation, ctx: CGContext) {
        withNSContext(ctx) {
            let text = a.text as NSString
            text.draw(at: a.start, withAttributes: textAttributes(a, outline: true))
            text.draw(at: a.start, withAttributes: textAttributes(a, outline: false))
        }
    }

    private static func drawCounter(_ a: ShotAnnotation, ctx: CGContext) {
        let r = a.counterRadius
        ctx.fillEllipse(in: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
            .foregroundColor: a.color.contrasting.nsColor,
        ]
        let label = "\(a.number)" as NSString
        let size = label.size(withAttributes: attrs)
        withNSContext(ctx) {
            label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)
        }
    }

    private static func drawMeasure(_ a: ShotAnnotation, ctx: CGContext, scale: CGFloat) {
        let horizontal = abs(a.end.x - a.start.x) >= abs(a.end.y - a.start.y)
        let cap = a.width * 3
        let w = a.width * 0.6
        ctx.setLineWidth(w)
        ctx.setLineCap(.butt)
        ctx.strokeLineSegments(between: [a.start, a.end])
        for p in [a.start, a.end] {
            if horizontal {
                ctx.strokeLineSegments(between: [CGPoint(x: p.x, y: p.y - cap), CGPoint(x: p.x, y: p.y + cap)])
            } else {
                ctx.strokeLineSegments(between: [CGPoint(x: p.x - cap, y: p.y), CGPoint(x: p.x + cap, y: p.y)])
            }
        }

        let pts = Int((hypot(a.end.x - a.start.x, a.end.y - a.start.y) / scale).rounded())
        let fontSize = 12 * scale
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: a.color.contrasting.nsColor,
        ]
        let label = "\(pts)" as NSString
        let size = label.size(withAttributes: attrs)
        let mid = CGPoint(x: (a.start.x + a.end.x) / 2, y: (a.start.y + a.end.y) / 2)
        let pill = CGRect(x: mid.x - size.width / 2 - fontSize * 0.4, y: mid.y - size.height / 2 - fontSize * 0.15,
                          width: size.width + fontSize * 0.8, height: size.height + fontSize * 0.3)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: fontSize * 0.3, cornerHeight: fontSize * 0.3, transform: nil))
        ctx.fillPath()
        withNSContext(ctx) {
            label.draw(at: CGPoint(x: mid.x - size.width / 2, y: mid.y - size.height / 2), withAttributes: attrs)
        }
    }

    private static func drawBlur(_ a: ShotAnnotation, state: ShotDocumentState, ctx: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: state.base.width, height: state.base.height)
        let region = a.rect.integral.intersection(bounds)
        guard region.width >= 1, region.height >= 1, let piece = state.base.cropping(to: region) else { return }
        let block = max(8, 10 * state.scale)
        let tiny = makeContext(width: Int((region.width / block).rounded(.up)),
                               height: Int((region.height / block).rounded(.up)))
        tiny.interpolationQuality = .medium
        tiny.draw(piece, in: CGRect(x: 0, y: 0, width: tiny.width, height: tiny.height))
        guard let small = tiny.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        draw(small, in: region, ctx: ctx)
        ctx.restoreGState()
    }
}

enum ShotExporter {
    /// Replaced by tests so they do not touch the user's clipboard.
    nonisolated(unsafe) static var pasteboard = NSPasteboard.general

    static func encode(_ image: CGImage, type: UTType = .png, scale: CGFloat = 1) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        // Same DPI tagging as macOS screenshots, so a 2x capture pastes at its point size.
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        var source = image
        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.92
            source = opaque(image)
        }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func opaque(_ image: CGImage) -> CGImage {
        let ctx = ShotRenderer.makeContext(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    @discardableResult
    static func copy(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let png = encode(image, scale: scale) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }

    static func copy(string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func image(fromPasteboard pb: NSPasteboard) -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let image = load(data: data)?.image { return image }
        }
        if let url = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL {
            return load(url: url)?.image
        }
        return nil
    }

    static func load(url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: src)
    }

    static func load(data: Data) -> (image: CGImage, scale: CGFloat)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: src)
    }

    private static func load(source src: CGImageSource) -> (image: CGImage, scale: CGFloat)? {
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        return (image, max(1, (dpi / 72).rounded()))
    }

    /// sRGB color of one pixel, or nil when outside the image.
    static func sample(_ image: CGImage, x: Int, y: Int) -> ShotRGBA? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: ShotRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        return ShotRGBA(r: CGFloat(bytes[0]) / 255, g: CGFloat(bytes[1]) / 255, b: CGFloat(bytes[2]) / 255, a: CGFloat(bytes[3]) / 255)
    }
}

enum ShotCollage {
    enum Layout: Equatable { case horizontal, vertical, grid(columns: Int) }

    static func gridColumns(for count: Int) -> Int { max(1, Int(Double(count).squareRoot().rounded(.up))) }

    /// Lays images out with a transparent background, each centered in its cell.
    static func stitch(_ images: [CGImage], layout: Layout, gap: Int) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let columns: Int
        switch layout {
        case .horizontal: columns = images.count
        case .vertical: columns = 1
        case .grid(let c): columns = max(1, c)
        }
        let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
        var colWidths = [Int](repeating: 0, count: columns)
        var rowHeights = [Int](repeating: 0, count: rows)
        for (i, image) in images.enumerated() {
            colWidths[i % columns] = max(colWidths[i % columns], image.width)
            rowHeights[i / columns] = max(rowHeights[i / columns], image.height)
        }
        let width = colWidths.reduce(0, +) + gap * (columns - 1)
        let height = rowHeights.reduce(0, +) + gap * (rows - 1)
        let ctx = ShotRenderer.makeContext(width: width, height: height)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            let cellX = colWidths[..<col].reduce(0, +) + gap * col
            let cellY = rowHeights[..<row].reduce(0, +) + gap * row
            let x = cellX + (colWidths[col] - image.width) / 2
            let y = cellY + (rowHeights[row] - image.height) / 2
            ShotRenderer.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height), ctx: ctx)
        }
        return ctx.makeImage()
    }
}
