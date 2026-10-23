import Foundation

/// Keys the simulator reports to the Host (InputEventBatch/1 key events). Codes are what the official
/// simulator sends for the Mac's arrows, Return and Escape; 1001–1003 are the Host's crown gestures.
enum AappKey: Equatable {
    case up, down, left, right, enter, escape
    case doubleTap, tripleTap, longHold
    case code(Int32)

    var code: Int32 {
        switch self {
        case .left: return 37
        case .up: return 38
        case .right: return 39
        case .down: return 40
        case .enter: return 13
        case .escape: return 27
        case .doubleTap: return 1001
        case .tripleTap: return 1002
        case .longHold: return 1003
        case .code(let c): return c
        }
    }
}

/// InputEnvelope B2/1: 24-byte header (u8 0xB2, u8 1, u8 opcode, u8 0, u32 requestId, u64 sessionId,
/// u32 sequence, u16 bodyLen, u16 0) + body ≤ 512 bytes.
struct AappInputEnvelope: Equatable {
    enum Op: UInt8 { case capabilities = 1, open, close, acquire, release, renew, reply = 0x80, batch, status }
    enum Code: UInt8 { case ok = 0, unsupported, invalidArgument, busy, notReady, staleSession, resourceLimit, hardwareFailure }

    static let headerBytes = 24, maxBody = 512

    var opcode: UInt8
    var requestId: UInt32
    var sessionId: UInt64
    var sequence: UInt32
    var body: Data

    func encoded() -> Data {
        var w = AappWriter()
        w.u8(0xb2); w.u8(1); w.u8(opcode); w.u8(0)
        w.u32(requestId); w.u64(sessionId); w.u32(sequence)
        w.u16(UInt16(body.count)); w.u16(0)
        w.bytes(body)
        return w.data
    }

    static func decode(_ data: Data) throws -> AappInputEnvelope {
        var r = AappReader(data)
        guard data.count >= headerBytes, data.count <= headerBytes + maxBody,
              try r.u8() == 0xb2, try r.u8() == 1 else { throw AappReaderError(description: "INVALID_INPUT_ENVELOPE") }
        let op = try r.u8()
        guard try r.u8() == 0 else { throw AappReaderError(description: "INVALID_INPUT_ENVELOPE") }
        let request = try r.u32(), session = try r.u64(), sequence = try r.u32()
        let length = Int(try r.u16())
        guard try r.u16() == 0, length == r.remaining else { throw AappReaderError(description: "INVALID_INPUT_ENVELOPE length") }
        return AappInputEnvelope(opcode: op, requestId: request, sessionId: session, sequence: sequence, body: try r.take(length))
    }

    /// Reply to a control request: body = [expectedOp, code, 0, 0] + data (data only when ok).
    static func reply(to request: AappInputEnvelope, code: Code, data: Data = Data()) -> AappInputEnvelope {
        var body = Data([request.opcode, code.rawValue, 0, 0])
        if code == .ok { body.append(data) }
        return AappInputEnvelope(opcode: Op.reply.rawValue, requestId: request.requestId, sessionId: request.sessionId,
                                 sequence: 0, body: body)
    }

    /// Capabilities with no IMU: version 1, masks 0, 512-byte batches, 32 events (matches the official
    /// simulator started without --simulate-imu).
    static let capabilitiesNoImu: Data = {
        var w = AappWriter()
        w.u8(1); w.u8(0); w.u8(0); w.u8(0); w.u16(512); w.u16(32); w.u16(0); w.u16(0); w.u32(0)
        return w.data
    }()
}

/// InputEventBatch/1 bodies pushed in `input` packets (opcode 0x81 envelopes).
enum AappInputBatch {
    static func keys(_ codes: [Int32]) -> Data {
        var w = AappWriter()
        w.u8(1); w.u8(0); w.u16(UInt16(codes.count))
        for c in codes { w.u8(1); w.u32(4); w.i32(c) }
        return w.data
    }

    /// Touch: phase 0 tap, 1 start, 2 move, 3 end, 4 cancel. Coordinates in the announced display space.
    static func touch(phase: UInt8, pointer: UInt32, x: Float, y: Float) -> Data {
        var w = AappWriter()
        w.u8(1); w.u8(0); w.u16(1)
        w.u8(2); w.u32(24)
        w.u8(phase); w.u8(0); w.u16(0); w.u32(phase == 0 ? 0 : pointer); w.u64(0); w.f32(x); w.f32(y)
        return w.data
    }
}

/// UI event batch for micro mode (`uiEvents`): u8 1, u16 count, then count × {u8 type, u32 len, data}.
enum AappUIEvents {
    /// Batch of events: click (type 1: u32 node, str key) and component (type 8: u32 node, str key, str JSON).
    enum Event { case click(UInt32, String), component(UInt32, String, [String: Any]) }

    static func batch(_ events: [Event]) -> Data {
        var w = AappWriter()
        w.u8(1); w.u16(UInt16(min(events.count, 0xffff)))
        for e in events.prefix(0xffff) {
            var body = AappWriter()
            switch e {
            case .click(let node, let key): body.u32(node); body.string(key); w.u8(1)
            case .component(let node, let key, let data):
                body.u32(node); body.string(key)
                body.string(String(data: AappPacket.json(data), encoding: .utf8) ?? "{}"); w.u8(8)
            }
            w.u32(UInt32(body.data.count)); w.bytes(body.data)
        }
        return w.data
    }

    static func click(node: UInt32, key: String) -> Data {
        var event = AappWriter()
        event.u32(node); event.string(key)
        var w = AappWriter()
        w.u8(1); w.u16(1)
        w.u8(1); w.u32(UInt32(event.data.count)); w.bytes(event.data)
        return w.data
    }
}
