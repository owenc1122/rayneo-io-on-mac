import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Images (PNG/JPEG as stored in the app) and Lottie files the Host sent with `resource` / `lottieResource`,
/// keyed by resource id (`@drawable/name`, `res/...`, `network:…`). Bounded: least recently used entries are
/// evicted beyond `maxBytes`. Not thread-safe; owned by the session's queue.
final class AappResources {
    let maxBytes: Int
    private var data: [String: Data] = [:]
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private(set) var totalBytes = 0

    init(maxBytes: Int = 64 << 20) { self.maxBytes = maxBytes }

    var count: Int { data.count }

    func store(_ id: String, _ bytes: Data) {
        remove(id)
        data[id] = bytes; order.append(id); totalBytes += bytes.count
        while totalBytes > maxBytes, let oldest = order.first, oldest != id { remove(oldest) }
    }

    /// An already decoded image (raw RGBA/RGB565 stream resources).
    func store(_ id: String, image: CGImage) {
        store(id, Data(count: image.width * image.height * 4))   // accounts its decoded size
        images[id] = image
    }

    func remove(_ id: String) {
        guard let old = data.removeValue(forKey: id) else { return }
        totalBytes -= old.count; images[id] = nil
        order.removeAll { $0 == id }
    }

    func removeAll() { data.removeAll(); images.removeAll(); order.removeAll(); totalBytes = 0 }

    func contains(_ id: String) -> Bool { data[id] != nil }

    /// Decoded image (cached); nil if missing or not a decodable image ≤ 2048×2048.
    func image(_ id: String) -> CGImage? {
        if let image = images[id] { return image }
        guard let bytes = data[id], let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= 2048, image.height <= 2048 else { return nil }
        images[id] = image
        if let i = order.firstIndex(of: id) { order.remove(at: i); order.append(id) }
        return image
    }
}

/// Rasterises ADRF frames with Core Graphics in the frame's top-left, y-down coordinates.
enum AappCanvas {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A cleared (black) RGBA context of the display size, flipped to y-down.
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Renders a whole frame to an image of the display size (the frame's viewport is scaled to fit).
    static func render(_ frame: ADRFFrame, width: Int, height: Int, resources: AappResources, warn: (String) -> Void) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.scaleBy(x: CGFloat(width) / CGFloat(frame.width), y: CGFloat(height) / CGFloat(frame.height))
        draw(frame, in: ctx, resources: resources, warn: warn)
        return ctx.makeImage()
    }

    /// Plays the command list into `ctx` (already transformed so the frame viewport is at the origin).
    static func draw(_ frame: ADRFFrame, in ctx: CGContext, resources: AappResources, warn: (String) -> Void) {
        var layers: [Bool] = []   // per save: true = saveLayer (transparency layer)
        ctx.saveGState()
        defer {
            for layer in layers.reversed() { if layer { ctx.endTransparencyLayer() }; ctx.restoreGState() }
            ctx.restoreGState()
        }
        func apply(_ p: ADRFPaint) {
            let color = CGColor(srgbRed: p.red, green: p.green, blue: p.blue, alpha: p.alpha)
            ctx.setFillColor(color); ctx.setStrokeColor(color)
            ctx.setLineWidth(CGFloat(p.strokeWidth))
            ctx.setLineCap([CGLineCap.butt, .round, .square][p.cap])
            ctx.setLineJoin([CGLineJoin.miter, .round, .bevel][p.join])
            ctx.setMiterLimit(CGFloat(p.miter))
            ctx.setShouldAntialias(p.antialias)
            ctx.setBlendMode(blendMode(p.blendMode))
        }
        for command in frame.commands {
            switch command {
            case .clear(let color):
                guard let rgb = ADRFColor.parse(color) else { continue }
                ctx.saveGState()
                ctx.concatenate(ctx.ctm.inverted())
                ctx.setBlendMode(.copy)
                ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                ctx.restoreGState()
            case .save:
                guard layers.count < 64 else { warn("ADRF save depth over 64 ignored"); continue }
                ctx.saveGState(); layers.append(false)
            case .saveLayer(let opacity):
                guard layers.count < 64 else { warn("ADRF save depth over 64 ignored"); continue }
                ctx.saveGState(); ctx.setAlpha(CGFloat(opacity)); ctx.beginTransparencyLayer(auxiliaryInfo: nil); layers.append(true)
            case .restore:
                guard let layer = layers.popLast() else { continue }
                if layer { ctx.endTransparencyLayer() }
                ctx.restoreGState()
            case .translate(let x, let y): ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
            case .scale(let x, let y): ctx.scaleBy(x: CGFloat(x), y: CGFloat(y))
            case .rotate(let r): ctx.rotate(by: CGFloat(r))
            case .clip(let x, let y, let w, let h, let radii):
                ctx.addPath(roundedRect(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h)), radii))
                ctx.clip()
            case .line(let p, let x, let y, let x2, let y2):
                ctx.saveGState(); apply(frame.paints[p])
                ctx.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y))); ctx.addLine(to: CGPoint(x: CGFloat(x2), y: CGFloat(y2)))
                ctx.strokePath(); ctx.restoreGState()
            case .rect(let p, let x, let y, let w, let h, let radii):
                let paint = frame.paints[p]
                ctx.saveGState(); apply(paint)
                ctx.addPath(roundedRect(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h)), radii))
                if paint.stroke { ctx.strokePath() } else { ctx.fillPath() }
                ctx.restoreGState()
            case .circle(let p, let cx, let cy, let r):
                let paint = frame.paints[p]
                ctx.saveGState(); apply(paint)
                ctx.addEllipse(in: CGRect(x: CGFloat(cx - r), y: CGFloat(cy - r), width: CGFloat(2 * r), height: CGFloat(2 * r)))
                if paint.stroke { ctx.strokePath() } else { ctx.fillPath() }
                ctx.restoreGState()
            case .path(let p, let index):
                let paint = frame.paints[p], path = frame.paths[index]
                ctx.saveGState(); apply(paint)
                ctx.addPath(cgPath(path))
                if paint.stroke { ctx.strokePath() } else { ctx.fillPath(using: path.evenOdd ? .evenOdd : .winding) }
                ctx.restoreGState()
            case .text(let t):
                ctx.saveGState(); apply(frame.paints[t.paint])
                let paint = frame.paints[t.paint]
                drawText(t.text, x: CGFloat(t.x), y: CGFloat(t.y), size: CGFloat(t.size), font: paint.font,
                         color: CGColor(srgbRed: paint.red, green: paint.green, blue: paint.blue, alpha: paint.alpha), in: ctx)
                ctx.restoreGState()
            case .image(let i):
                guard let image = resources.image(i.resource) else {
                    warn(resources.contains(i.resource) ? "图片资源无法解码：\(i.resource)" : "缺少图片资源：\(i.resource)"); continue
                }
                drawImage(image, in: CGRect(x: CGFloat(i.x), y: CGFloat(i.y), width: CGFloat(i.width), height: CGFloat(i.height)),
                          fit: i.fit, align: i.align, justify: i.justify, ctx: ctx)
            case .lottie(let l):
                warn("Lottie 动画暂不支持，显示为占位框：\(l.resource)")
                placeholder(CGRect(x: CGFloat(l.x), y: CGFloat(l.y), width: CGFloat(l.width), height: CGFloat(l.height)), label: "Lottie", ctx: ctx)
            }
        }
    }

    static func blendMode(_ name: String?) -> CGBlendMode {
        switch name?.lowercased() {
        case nil, "source-over", "srcover", "src-over", "normal": return .normal
        case "multiply": return .multiply
        case "screen": return .screen
        case "overlay": return .overlay
        case "darken": return .darken
        case "lighten": return .lighten
        case "plus", "add", "lighter", "plus-lighter": return .plusLighter
        case "copy", "src", "source": return .copy
        case "clear": return .clear
        case "xor": return .xor
        case "destination-out", "dst-out", "dstout": return .destinationOut
        case "destination-in", "dst-in", "dstin": return .destinationIn
        case "source-in", "src-in", "srcin": return .sourceIn
        case "source-atop", "src-atop", "srcatop": return .sourceAtop
        case "difference": return .difference
        default: return .normal
        }
    }

    static func roundedRect(_ r: CGRect, _ radii: ADRFRadii) -> CGPath {
        let rect = r.standardized
        let limit = min(rect.width, rect.height) / 2
        let tl = min(CGFloat(radii.topLeft), limit), tr = min(CGFloat(radii.topRight), limit)
        let br = min(CGFloat(radii.bottomRight), limit), bl = min(CGFloat(radii.bottomLeft), limit)
        let path = CGMutablePath()
        if tl == 0 && tr == 0 && br == 0 && bl == 0 { path.addRect(rect); return path }
        // y-down: minY is the top edge.
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }

    static func cgPath(_ p: ADRFPath) -> CGPath {
        let path = CGMutablePath()
        var i = 0
        func pt(_ k: Int) -> CGPoint { CGPoint(x: CGFloat(p.points[i + k]), y: CGFloat(p.points[i + k + 1])) }
        for verb in p.verbs {
            switch verb {
            case 0: path.move(to: pt(0)); i += 2
            case 1: if path.isEmpty { path.move(to: pt(0)) } else { path.addLine(to: pt(0)) }; i += 2
            case 2: if !path.isEmpty { path.addQuadCurve(to: pt(2), control: pt(0)) }; i += 4
            case 3: if !path.isEmpty { path.addCurve(to: pt(4), control1: pt(0), control2: pt(2)) }; i += 6
            default: if !path.isEmpty { path.closeSubpath() }
            }
        }
        return path
    }

    // MARK: text

    /// Font for an ADRF/micro font name (nil = the glasses UI font). CJK falls back through Core Text cascading.
    static func font(_ name: String?, size: CGFloat, weight: Double? = nil) -> CTFont {
        let size = max(1, min(size, 512))
        var base: CTFont
        switch name?.lowercased() {
        case "monospace", "mono", "menlo", "courier": base = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        case .some(let n) where !n.isEmpty:
            let candidate = CTFontCreateWithName(name! as CFString, size, nil)
            let family = (CTFontCopyFamilyName(candidate) as String).lowercased()
            base = family.contains(n.prefix(4)) ? candidate : CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        default: base = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        }
        if let weight, weight >= 600, let bold = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { base = bold }
        return base
    }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
    }

    /// Draws `text` with its line box's top-left at (x, y) in the y-down context; "\n" starts a new line.
    static func drawText(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, font name: String?, color: CGColor, in ctx: CGContext, weight: Double? = nil) {
        let font = font(name, size: size, weight: weight)
        let ascent = CTFontGetAscent(font), lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (n, part) in text.components(separatedBy: "\n").prefix(256).enumerated() {
            ctx.textPosition = CGPoint(x: x, y: y + ascent + CGFloat(n) * lineHeight)
            CTLineDraw(line(part, font: font, color: color), ctx)
        }
        ctx.restoreGState()
    }

    // MARK: images

    /// fit: 0 fill (stretch), 1 fit (contain), 2 crop (cover), 3 center (natural size), 4 scale (contain, never
    /// enlarge). align = horizontal and justify = vertical placement: 0 start, 1 center, 2 end.
    static func drawImage(_ image: CGImage, in box: CGRect, fit: Int, align: Int, justify: Int, ctx: CGContext) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, box.width > 0, box.height > 0 else { return }
        var size: CGSize
        switch fit {
        case 1: let k = min(box.width / iw, box.height / ih); size = CGSize(width: iw * k, height: ih * k)
        case 2: let k = max(box.width / iw, box.height / ih); size = CGSize(width: iw * k, height: ih * k)
        case 3: size = CGSize(width: iw, height: ih)
        case 4: let k = min(1, min(box.width / iw, box.height / ih)); size = CGSize(width: iw * k, height: ih * k)
        default: size = box.size
        }
        func place(_ free: CGFloat, _ mode: Int) -> CGFloat { mode == 0 ? 0 : mode == 2 ? free : free / 2 }
        let origin = CGPoint(x: box.minX + place(box.width - size.width, align), y: box.minY + place(box.height - size.height, justify))
        ctx.saveGState()
        ctx.clip(to: box)
        ctx.interpolationQuality = .medium
        // The context is y-down; flip locally so the image is drawn upright.
        ctx.translateBy(x: origin.x, y: origin.y + size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    /// Dashed outline with a label, for content the simulator cannot draw yet.
    static func placeholder(_ rect: CGRect, label: String, ctx: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.75, blue: 0.5, alpha: 0.8))
        ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
        drawText(label, x: rect.minX + 3, y: rect.minY + 2, size: min(12, max(8, rect.height - 4)), font: nil,
                 color: CGColor(srgbRed: 0.45, green: 0.75, blue: 0.5, alpha: 0.9), in: ctx)
    }
}
