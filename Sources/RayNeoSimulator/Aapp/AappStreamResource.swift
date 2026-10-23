import CoreGraphics
import Foundation

/// ASR/1 stream-resource replication (`streamResource` messages): how the Host delivers images to a micro-mode
/// display (network images, decoded variants). Frame: u32 "ASR1", u8 1, u8 opcode, u16 status, u32 bodyLen, body
/// (≤ 64 KiB). The Host writes a stream in ranges, publishes a cursor (stream, cursorKey, endOffset, finished) and
/// binds that cursor to an image resource id with a format descriptor. Replies carry opcode | 0x80.
final class AappStreamResources {
    enum Op: UInt8 { case ensureStream = 0x11, writeRange = 0x12, publishCursor = 0x13, releaseReplica = 0x14, bindResource = 0x15 }
    static let magic: UInt32 = 0x31525341, maxFrameBytes = 65536
    /// Total bytes held for all replicated streams (advertised as streamResourceBudgetBytes).
    static let budgetBytes = 8 << 20

    private var streams: [UInt32: Data] = [:]
    private var cursors: [UInt32: (stream: UInt32, end: Int)] = [:]
    private var totalBytes = 0
    var onBind: (_ id: String, _ data: Data?, _ image: CGImage?) -> Void = { _, _, _ in }
    var log: (String) -> Void = { _ in }

    func reset() { streams.removeAll(); cursors.removeAll(); totalBytes = 0 }

    static func frame(_ opcode: UInt8, status: UInt16 = 0, body: Data = Data()) -> Data {
        var w = AappWriter()
        w.u32(magic); w.u8(1); w.u8(opcode); w.u16(status); w.u32(UInt32(body.count)); w.bytes(body)
        return w.data
    }

    /// Reply frame for one request frame (an error status with an empty body on failure).
    func handle(_ data: Data) -> Data {
        var r = AappReader(data)
        guard data.count >= 12, data.count <= Self.maxFrameBytes,
              (try? r.u32()) == Self.magic, (try? r.u8()) == 1, let opcode = try? r.u8(), let _ = try? r.u16(),
              let length = try? r.u32(), Int(length) == r.remaining else { return Self.frame(0x80, status: 2) }
        let reply = opcode | 0x80
        func fail(_ status: UInt16, _ why: String) -> Data { log("✗ 流式资源 0x\(String(opcode, radix: 16))：\(why)"); return Self.frame(reply, status: status) }
        do {
            switch Op(rawValue: opcode) {
            case .ensureStream:
                let key = try r.u32()
                guard key != 0 else { return fail(2, "stream key 0") }
                if streams[key] == nil { streams[key] = Data() }
                var w = AappWriter(); w.u32(key); w.u64(UInt64(streams[key]!.count))
                return Self.frame(reply, body: w.data)
            case .writeRange:
                let key = try r.u32(), start = try r.u64(), bytes = try r.take(r.remaining)
                guard var stream = streams[key] else { return fail(5, "unknown stream \(key)") }
                guard start == UInt64(stream.count) else { return fail(5, "offset \(start) ≠ \(stream.count)") }
                guard totalBytes + bytes.count <= Self.budgetBytes else { return fail(6, "超过 \(Self.budgetBytes) 字节预算") }
                stream.append(bytes); streams[key] = stream; totalBytes += bytes.count
                var w = AappWriter(); w.u32(key); w.u64(UInt64(stream.count))
                return Self.frame(reply, body: w.data)
            case .publishCursor:
                let body = try r.take(r.remaining)
                guard body.count == 20 else { return fail(2, "cursor length") }
                var c = AappReader(body)
                let stream = try c.u32(), cursorKey = try c.u32(), end = try c.u64(), _ = try c.u32()
                guard let data = streams[stream], end <= UInt64(data.count) else { return fail(5, "cursor beyond stream") }
                cursors[cursorKey] = (stream, Int(end))
                return Self.frame(reply, body: body)
            case .releaseReplica:
                let key = try r.u32()
                if let old = streams.removeValue(forKey: key) { totalBytes -= old.count }
                cursors = cursors.filter { $0.value.stream != key }
                var w = AappWriter(); w.u32(key)
                return Self.frame(reply, body: w.data)
            case .bindResource:
                let cursorKey = try r.u32(), _ = try r.u16(), _ = try r.u16()
                let idLength = Int(try r.u32()), descriptorLength = Int(try r.u32())
                guard idLength > 0, idLength <= 4096, descriptorLength == 16 else { return fail(2, "bind lengths") }
                guard let id = String(data: try r.take(idLength), encoding: .utf8) else { return fail(2, "bind id") }
                var d = AappReader(try r.take(descriptorLength))
                let format = try d.u16(), _ = try d.u16(), width = Int(try d.u32()), height = Int(try d.u32()), stride = Int(try d.u32())
                guard let cursor = cursors[cursorKey], let stream = streams[cursor.stream] else { return fail(5, "unknown cursor \(cursorKey)") }
                let bytes = Data(stream.prefix(cursor.end))
                switch format {
                case 1, 2: onBind(id, bytes, nil)
                case 3, 4:
                    guard width > 0, height > 0, width <= 2048, height <= 2048, stride * height <= bytes.count,
                          let image = Self.rawImage(bytes, width: width, height: height, stride: stride, rgb565: format == 4) else { return fail(4, "raw image") }
                    onBind(id, nil, image)
                default: return fail(1, "image format \(format)")
                }
                log("流式图片 \(id)（\(bytes.count) 字节，格式 \(["", "PNG", "JPEG", "RGBA8888", "RGB565"][Int(min(format, 4))]) \(width)×\(height)）")
                var w = AappWriter(); w.u32(cursorKey)
                return Self.frame(reply, body: w.data)
            case nil:
                return fail(1, "unsupported opcode")
            }
        } catch {
            return fail(2, "\(error)")
        }
    }

    static func rawImage(_ bytes: Data, width: Int, height: Int, stride: Int, rgb565: Bool) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        bytes.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    if rgb565 {
                        let i = y * stride + x * 2
                        let p = UInt16(src[i]) | UInt16(src[i + 1]) << 8
                        rgba[o] = UInt8((p >> 11) & 0x1f) << 3; rgba[o + 1] = UInt8((p >> 5) & 0x3f) << 2; rgba[o + 2] = UInt8(p & 0x1f) << 3
                    } else {
                        let i = y * stride + x * 4
                        rgba[o] = src[i]; rgba[o + 1] = src[i + 1]; rgba[o + 2] = src[i + 2]; rgba[o + 3] = src[i + 3]
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: AappCanvas.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
