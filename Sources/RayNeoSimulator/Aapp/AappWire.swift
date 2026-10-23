import Foundation

/// Aapp Host ↔ simulator TCP protocol, version 1 (the official "RTOS Simulator" / lvgl_host speaks the same).
/// Packet, all little-endian: u32 length (= 12 + payload) | u16 version 1 | u16 type | u32 session | u32 request | payload.
/// The Host is the client; it sends requests and expects `ack` (or `inputControl` for `inputControl`) with the same
/// request id. The simulator pushes `input`, `uiEvents` (request 0) and `remoteInputState` (own request space).
enum AappMessage: UInt16, CaseIterable {
    case hello = 0, open, close, resource, releaseResource, clearResources, frame, clear, ping
    case ack, error, input, microCommands, uiEvents, streamResource, reserved15, lottieResource
    case inputControl, remoteInput, remoteInputState
}

struct AappPacket: Equatable {
    var type: UInt16
    var session: UInt32
    var request: UInt32
    var payload: Data

    static let headerBytes = 16
    /// Largest `length` field the Host and the official simulator accept (12 + payload).
    static let maxLength = 16 * 1024 * 1024

    init(_ type: AappMessage, session: UInt32 = 0, request: UInt32 = 0, payload: Data = Data()) {
        self.type = type.rawValue; self.session = session; self.request = request; self.payload = payload
    }
    init(rawType: UInt16, session: UInt32, request: UInt32, payload: Data) {
        self.type = rawType; self.session = session; self.request = request; self.payload = payload
    }

    var message: AappMessage? { AappMessage(rawValue: type) }

    /// A JSON reply payload; an empty object is sent as `{}` like the official simulator.
    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    func encoded() -> Data {
        var w = AappWriter()
        w.u32(UInt32(12 + payload.count)); w.u16(1); w.u16(type); w.u32(session); w.u32(request)
        w.bytes(payload)
        return w.data
    }
}

enum AappWireError: Error, Equatable, CustomStringConvertible {
    case invalidLength(Int)
    case unsupportedVersion(Int)
    var description: String {
        switch self {
        case .invalidLength(let n): return "Invalid TCP message length \(n)"
        case .unsupportedVersion(let v): return "Unsupported TCP version \(v)"
        }
    }
}

/// Splits a TCP byte stream into packets. Bounded: a length outside 12…16 MiB is a protocol error (the
/// connection must be closed), so the buffer never holds more than one maximal packet plus one read.
struct AappFramer {
    private(set) var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Next complete packet, nil if more bytes are needed. Throws on a corrupt stream.
    mutating func next() throws -> AappPacket? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer.leU32(at: start))
        guard length >= 12, length <= AappPacket.maxLength else { throw AappWireError.invalidLength(length) }
        guard buffer.count >= 4 + length else { return nil }
        let version = Int(buffer.leU16(at: start + 4))
        guard version == 1 else { throw AappWireError.unsupportedVersion(version) }
        let packet = AappPacket(rawType: buffer.leU16(at: start + 6), session: buffer.leU32(at: start + 8),
                                request: buffer.leU32(at: start + 12),
                                payload: Data(buffer[(start + 16)..<(start + 4 + length)]))
        buffer = Data(buffer[(start + 4 + length)...])
        return packet
    }
}

// MARK: little-endian helpers

struct AappWriter {
    private(set) var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func string(_ s: String) { let b = Data(s.utf8); u32(UInt32(b.count)); data.append(b) }
}

struct AappReaderError: Error, CustomStringConvertible {
    let description: String
}

/// Bounds-checked reader; every read past the end throws instead of trapping.
struct AappReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex }

    var remaining: Int { data.endIndex - offset }
    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw AappReaderError(description: "Unexpected end of data") }
        let slice = data[offset..<(offset + n)]
        offset += n
        return slice
    }
    mutating func u8() throws -> UInt8 { let d = try take(1); return d[d.startIndex] }
    mutating func u16() throws -> UInt16 { let d = try take(2); return d.leU16(at: d.startIndex) }
    mutating func u32() throws -> UInt32 { let d = try take(4); return d.leU32(at: d.startIndex) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func u64() throws -> UInt64 { let d = try take(8); return d.leU64(at: d.startIndex) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    /// u32 length + bytes.
    mutating func block(max: Int = AappPacket.maxLength) throws -> Data {
        let n = Int(try u32())
        guard n <= max else { throw AappReaderError(description: "Block of \(n) bytes exceeds \(max)") }
        return try take(n)
    }
    mutating func string(max: Int = 1 << 20) throws -> String {
        let bytes = try block(max: max)
        guard let s = String(data: bytes, encoding: .utf8) else { throw AappReaderError(description: "Invalid UTF-8") }
        return s
    }
}

extension Data {
    func leU16(at i: Index) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func leU32(at i: Index) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func leU64(at i: Index) -> UInt64 { UInt64(leU32(at: i)) | UInt64(leU32(at: i + 4)) << 32 }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
