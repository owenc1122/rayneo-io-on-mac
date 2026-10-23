import Foundation

/// ADRF v2 DrawFrame: the display list an Aapp sends in `frame` messages (plain/普通 mode) and embeds in micro
/// `setCustomContent`. Layout (LE): u32 "ADRF", u16 2, f32 width, f32 height, u32 sectionCount, then sections
/// {u16 kind, u16 flags, u32 len, body}: 1 strings, 2 paints, 3 paths, 4 commands, 5 required features.
/// Paint/path/command bodies are protobuf-style fields (varint tags; wire types 0, 1, 2, 5).
struct ADRFFrame {
    var width: Float
    var height: Float
    var paints: [ADRFPaint]
    var paths: [ADRFPath]
    var commands: [ADRFCommand]
    /// Resource ids the frame draws (images, Lottie).
    var resources: Set<String> {
        Set(commands.compactMap { if case .image(let i) = $0 { return i.resource }; if case .lottie(let l) = $0 { return l.resource }; return nil })
    }
}

struct ADRFPaint {
    var red: Double, green: Double, blue: Double
    var alpha: Double = 1
    var stroke = false
    var strokeWidth: Double = 1
    var blendMode: String?
    var antialias = true
    var font: String?
    var cap: Int = 0     // 0 butt, 1 round, 2 square
    var join: Int = 0    // 0 miter, 1 round, 2 bevel
    var miter: Double = 4
}

struct ADRFPath {
    var evenOdd: Bool
    var verbs: [UInt8]     // 0 move, 1 line, 2 quad, 3 cubic, 4 close
    var points: [Float]
}

struct ADRFRadii: Equatable { var topLeft: Float = 0, topRight: Float = 0, bottomRight: Float = 0, bottomLeft: Float = 0 }

struct ADRFImage { var resource: String; var x, y, width, height: Float; var fit: Int; var align: Int; var justify: Int }
struct ADRFText { var paint: Int; var text: String; var x, y, size: Float }
struct ADRFLottie { var resource: String; var progress, x, y, width, height: Float; var fit: Int }

enum ADRFCommand {
    case clear(String)
    case save, restore
    case translate(Float, Float), scale(Float, Float), rotate(Float)
    case clip(x: Float, y: Float, width: Float, height: Float, radii: ADRFRadii)
    case line(paint: Int, x: Float, y: Float, toX: Float, toY: Float)
    case rect(paint: Int, x: Float, y: Float, width: Float, height: Float, radii: ADRFRadii)
    case circle(paint: Int, cx: Float, cy: Float, r: Float)
    case image(ADRFImage)
    case text(ADRFText)
    case path(paint: Int, index: Int)
    case saveLayer(Float)
    case lottie(ADRFLottie)
}

struct ADRFError: Error, CustomStringConvertible {
    let description: String
    init(_ detail: String) { description = "ADRF \(detail)" }
}

enum ADRFDecoder {
    /// Generous receiver limits (the Host itself caps frames at 64 KiB, 512 commands, save depth 32).
    static let maxFrameBytes = 1 << 20, maxCommands = 4096, maxStrings = 4096, maxPaints = 1024, maxPaths = 16384

    static func decode(_ data: Data) throws -> ADRFFrame {
        guard !data.isEmpty else { throw ADRFError("Empty frame") }
        guard data.count <= maxFrameBytes else { throw ADRFError("Frame size \(data.count)") }
        var r = AappReader(data)
        guard try r.u32() == 0x46524441 else { throw ADRFError("Magic") }
        let version = try r.u16()
        guard version == 2 else { throw ADRFError("Version \(version)") }
        let width = try r.f32(), height = try r.f32()
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 65535, height <= 65535 else { throw ADRFError("Viewport") }
        let count = Int(try r.u32())
        guard count <= r.remaining / 8 else { throw ADRFError("Section count") }
        var sections: [UInt16: Data] = [:]
        for _ in 0..<count {
            let kind = try r.u16(), flags = try r.u16()
            let body = try r.block()
            if kind < 1 || kind > 5 {
                if flags & 1 != 0 { continue }
                throw ADRFError("Required section \(kind)")
            }
            guard sections[kind] == nil else { throw ADRFError("Duplicate section") }
            sections[kind] = body
        }
        guard sections.count == 5 else { throw ADRFError("Missing section") }

        var sr = AappReader(sections[1]!)
        let stringCount = Int(try sr.u32())
        guard stringCount <= maxStrings else { throw ADRFError("String count") }
        var strings: [String] = []
        strings.reserveCapacity(stringCount)
        for _ in 0..<stringCount { strings.append(try sr.string(max: 1 << 16)) }
        func text(_ index: UInt64) throws -> String {
            guard index < UInt64(strings.count) else { throw ADRFError("String index \(index)") }
            return strings[Int(index)]
        }

        var pr = AappReader(sections[2]!)
        let paintCount = Int(try pr.u32())
        guard paintCount <= maxPaints else { throw ADRFError("Paint count") }
        var paints: [ADRFPaint] = []
        for _ in 0..<paintCount { paints.append(try paint(ADRFFields(try pr.block()), text)) }

        var qr = AappReader(sections[3]!)
        let pathCount = Int(try qr.u32())
        guard pathCount <= maxPaths else { throw ADRFError("Path count") }
        var paths: [ADRFPath] = []
        for _ in 0..<pathCount { paths.append(try path(ADRFFields(try qr.block()))) }

        var cr = AappReader(sections[4]!)
        var commands: [ADRFCommand] = []
        while !cr.isAtEnd {
            guard commands.count < maxCommands else { throw ADRFError("Command count") }
            let op = try cr.u16(), flags = try cr.u16()
            let f = try ADRFFields(try cr.block())
            func p(_ field: Int) throws -> Int {
                let i = try f.uint(field)
                guard i < UInt64(paints.count) else { throw ADRFError("Paint index \(i)") }
                return Int(i)
            }
            switch op {
            case 0: commands.append(.clear(try text(try f.uint(1))))
            case 1: commands.append(.save)
            case 2: commands.append(.restore)
            case 3: commands.append(.translate(try f.float(1), try f.float(2)))
            case 4: commands.append(.scale(try f.float(1), try f.float(2)))
            case 5: commands.append(.rotate(try f.float(1)))
            case 6: commands.append(.clip(x: try f.float(1), y: try f.float(2), width: try f.float(3), height: try f.float(4), radii: f.radii(from: 5)))
            case 7: commands.append(.line(paint: try p(1), x: try f.float(2), y: try f.float(3), toX: try f.float(4), toY: try f.float(5)))
            case 8: commands.append(.rect(paint: try p(1), x: try f.float(2), y: try f.float(3), width: try f.float(4), height: try f.float(5), radii: f.radii(from: 6)))
            case 9: commands.append(.circle(paint: try p(1), cx: try f.float(2), cy: try f.float(3), r: try f.float(4)))
            case 10:
                commands.append(.image(ADRFImage(resource: try text(try f.uint(1)), x: try f.float(2), y: try f.float(3),
                                                 width: try f.float(4), height: try f.float(5),
                                                 fit: Int(clamping: f.uint(6, default: 0)), align: Int(clamping: f.uint(7, default: 1)), justify: Int(clamping: f.uint(8, default: 1)))))
            case 11:
                commands.append(.text(ADRFText(paint: try p(1), text: try text(try f.uint(2)), x: try f.float(3), y: try f.float(4), size: try f.float(5))))
            case 12:
                let index = try f.uint(2)
                guard index < UInt64(paths.count) else { throw ADRFError("Path index \(index)") }
                commands.append(.path(paint: try p(1), index: Int(index)))
            case 13: commands.append(.saveLayer(max(0, min(1, try f.float(1)))))
            case 14:
                commands.append(.lottie(ADRFLottie(resource: try text(try f.uint(1)), progress: try f.float(2), x: try f.float(3), y: try f.float(4),
                                                   width: try f.float(5), height: try f.float(6), fit: Int(clamping: f.uint(7, default: 0)))))
            default:
                if flags & 1 != 0 { continue }   // optional unknown command
                throw ADRFError("Required opcode \(op)")
            }
        }
        return ADRFFrame(width: width, height: height, paints: paints, paths: paths, commands: commands)
    }

    private static func paint(_ f: ADRFFields, _ text: (UInt64) throws -> String) throws -> ADRFPaint {
        let colorIndex = f.uint(1, default: 0xffff)
        let color = colorIndex == 0xffff ? "#000000" : try text(colorIndex)
        guard let rgb = ADRFColor.parse(color) else { throw ADRFError("Color \(color)") }
        var paint = ADRFPaint(red: rgb.0, green: rgb.1, blue: rgb.2)
        paint.alpha = Double(max(0, min(1, f.float(2, default: 1))))
        paint.stroke = f.uint(3, default: 0) == 1
        paint.strokeWidth = Double(max(0, f.float(4, default: 1)))
        let blend = f.uint(5, default: 0xffff)
        paint.blendMode = blend == 0xffff ? nil : try text(blend)
        paint.antialias = f.uint(6, default: 1) != 0
        let font = f.uint(7, default: 0xffff)
        paint.font = font == 0xffff ? nil : try text(font)
        paint.cap = Int(min(2, f.uint(8, default: 0)))
        paint.join = Int(min(2, f.uint(9, default: 0)))
        paint.miter = Double(max(1, f.float(10, default: 4)))
        return paint
    }

    private static func path(_ f: ADRFFields) throws -> ADRFPath {
        let verbs = [UInt8](f.bytes(2) ?? Data())
        let raw = f.bytes(3) ?? Data()
        guard raw.count % 4 == 0 else { throw ADRFError("Path point bytes") }
        var points: [Float] = []
        points.reserveCapacity(raw.count / 4)
        var r = AappReader(raw)
        while !r.isAtEnd { points.append(try r.f32()) }
        var needed = 0
        for v in verbs {
            guard v <= 4 else { throw ADRFError("Path verb \(v)") }
            needed += [2, 2, 4, 6, 0][Int(v)]
        }
        guard needed == points.count else { throw ADRFError("Path point count") }
        return ADRFPath(evenOdd: f.uint(1, default: 0) == 1, verbs: verbs, points: points)
    }
}

enum ADRFColor {
    /// "#RRGGBB" → components 0…1.
    static func parse(_ s: String) -> (Double, Double, Double)? {
        guard s.count == 7, s.first == "#", let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}

/// Protobuf-style field set of one paint/path/command body.
struct ADRFFields {
    enum Value { case varint(UInt64), fixed32(UInt32), fixed64(UInt64), bytes(Data) }
    private(set) var values: [Int: Value] = [:]

    init(_ data: Data) throws {
        var r = AappReader(data)
        func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                let b = try r.u8()
                guard shift < 64 else { throw ADRFError("Varint too long") }
                value |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
            }
        }
        while !r.isAtEnd {
            let tag = try varint()
            let field = Int(truncatingIfNeeded: tag >> 3)
            switch tag & 7 {
            case 0: values[field] = .varint(try varint())
            case 1: values[field] = .fixed64(try r.u64())
            case 2:
                let n = try varint()
                guard n <= UInt64(r.remaining) else { throw ADRFError("Field length") }
                values[field] = .bytes(try r.take(Int(n)))
            case 5: values[field] = .fixed32(try r.u32())
            default: throw ADRFError("Wire type \(tag & 7)")
            }
        }
    }

    func uint(_ field: Int) throws -> UInt64 {
        guard let v = values[field] else { throw ADRFError("Missing field \(field)") }
        switch v {
        case .varint(let x): return x
        case .fixed32(let x): return UInt64(x)
        default: throw ADRFError("Field \(field) type")
        }
    }
    func uint(_ field: Int, default d: UInt64) -> UInt64 { (try? uint(field)) ?? d }

    func float(_ field: Int) throws -> Float {
        guard let v = values[field] else { throw ADRFError("Missing field \(field)") }
        let x: Float
        switch v {
        case .fixed32(let bits): x = Float(bitPattern: bits)
        case .varint(let n): x = Float(n)
        case .fixed64(let bits): x = Float(Double(bitPattern: bits))
        case .bytes: throw ADRFError("Field \(field) type")
        }
        guard x.isFinite else { throw ADRFError("Field \(field) not finite") }
        return x
    }
    func float(_ field: Int, default d: Float) -> Float { (try? float(field)) ?? d }

    func bytes(_ field: Int) -> Data? { if case .bytes(let b) = values[field] { return b }; return nil }

    /// Corner radii in fields start…start+3 (tl, tr, br, bl); missing ones default to tl.
    func radii(from start: Int) -> ADRFRadii {
        let tl = max(0, float(start, default: 0))
        return ADRFRadii(topLeft: tl, topRight: max(0, float(start + 1, default: tl)),
                         bottomRight: max(0, float(start + 2, default: tl)), bottomLeft: max(0, float(start + 3, default: tl)))
    }
}
