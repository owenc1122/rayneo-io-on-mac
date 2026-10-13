import Foundation

/// IEEE CRC-32 (poly 0xEDB88320), as used in the SGN1 header.
enum SGNCRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func checksum<D: Sequence>(_ data: D) -> UInt32 where D.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

struct SGNPoint: Equatable { var x: Int16; var y: Int16 }

struct SGNRoad: Equatable {
    var cls: UInt8          // 0..3
    var points: [SGNPoint]  // 2..64
}

struct SGNFeature: Equatable {
    var kind: UInt8 // 1 stop sign, 2 traffic signal, 3 named building
    var point: SGNPoint
    var name: String = ""
}

struct SGNFlags: OptionSet, Equatable {
    let rawValue: UInt8
    static let rerouting = SGNFlags(rawValue: 1 << 0)
    static let gpsWeak = SGNFlags(rawValue: 1 << 1)
    static let arrived = SGNFlags(rawValue: 1 << 2)
    static let walking = SGNFlags(rawValue: 1 << 3)
    static let northUp = SGNFlags(rawValue: 1 << 4)
}

/// SGN1 SCENE payload (docs/PROTOCOL.md). Coordinates in 0.5 m units, local frame, x east / y north.
struct SGNScene: Equatable {
    var tMs: UInt32 = 0
    var pos = SGNPoint(x: 0, y: 0)
    var headingCd: UInt16 = 0
    var speedCms: UInt16 = 0
    var zoomMilli: UInt16 = 2000
    var flags: SGNFlags = []
    var icon: UInt8 = 0
    var maneuverDistM: UInt32 = 0
    var remainDistM: UInt32 = 0
    var remainTimeS: UInt32 = 0
    var man = SGNPoint(x: 0, y: 0)
    var road = ""
    var instr = ""
    var eta = ""
    var route: [SGNPoint] = []
    var roads: [SGNRoad] = []
    var features: [SGNFeature] = []
}

enum SGN1 {
    enum Op: UInt8 { case scene = 1, heartbeat = 2, stop = 3, pose = 4 }

    static let fileName = "spare-nav.sgn"
    static let headerSize = 32
    static let maxFileSize = 4096
    static let maxPayload = maxFileSize - headerSize
    static let maxRoutePoints = 256
    static let maxRoadPoints = 64
    static let maxRoadLen = 63, maxInstrLen = 47, maxEtaLen = 7
    /// Soft cap on total points (route + roads) for the glasses' render time.
    static let pointBudget = 520

    enum EncodeError: Error, Equatable { case tooLarge(Int), invalidRoad, tooManyRoutePoints, invalidFeature }

    /// Truncates UTF-8 to at most `max` bytes on a character boundary.
    static func utf8(_ s: String, max: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ch in s {
            // Firmware rejects control characters (PROTOCOL.md change 5): map whitespace controls to space, drop others.
            var c = ch
            if ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                guard ch.isWhitespace else { continue }
                c = " "
            }
            let b = Array(String(c).utf8)
            if out.count + b.count > max { break }
            out += b
        }
        return out
    }

    /// Fixed part + strings + route + road_count (without roads).
    static func baseSize(_ s: SGNScene) -> Int {
        36 + utf8(s.road, max: maxRoadLen).count + utf8(s.instr, max: maxInstrLen).count + utf8(s.eta, max: maxEtaLen).count
            + 2 + 4 * s.route.count + 2
    }

    static func roadSize(_ r: SGNRoad) -> Int { 2 + 4 * r.points.count }

    static func featureSize(_ s: SGNScene) -> Int {
        s.features.isEmpty ? 0 : 1 + s.features.reduce(0) { $0 + 6 + utf8($1.name, max: 31).count }
    }
    static func payloadSize(_ s: SGNScene) -> Int { baseSize(s) + s.roads.reduce(0) { $0 + roadSize($1) } + featureSize(s) }

    static func encodePayload(_ s: SGNScene) throws -> Data {
        guard s.route.count <= maxRoutePoints else { throw EncodeError.tooManyRoutePoints }
        var w = ByteWriter()
        w.u32(s.tMs)
        w.i16(s.pos.x); w.i16(s.pos.y)
        w.u16(s.headingCd % 36000)
        w.u16(s.speedCms)
        w.u16(s.zoomMilli)
        w.u8(s.flags.rawValue)
        w.u8(s.icon)
        w.u32(s.maneuverDistM); w.u32(s.remainDistM); w.u32(s.remainTimeS)
        w.i16(s.man.x); w.i16(s.man.y)
        let road = utf8(s.road, max: maxRoadLen), instr = utf8(s.instr, max: maxInstrLen), eta = utf8(s.eta, max: maxEtaLen)
        w.u8(UInt8(road.count)); w.u8(UInt8(instr.count)); w.u8(UInt8(eta.count)); w.u8(s.features.isEmpty ? 0 : 1)
        w.bytes(road); w.bytes(instr); w.bytes(eta)
        w.u16(UInt16(s.route.count))
        for p in s.route { w.i16(p.x); w.i16(p.y) }
        w.u16(UInt16(s.roads.count))
        for r in s.roads {
            guard r.points.count >= 2, r.points.count <= maxRoadPoints, r.cls <= 3 else { throw EncodeError.invalidRoad }
            w.u8(r.cls); w.u8(UInt8(r.points.count))
            for p in r.points { w.i16(p.x); w.i16(p.y) }
        }
        guard s.features.count <= 16 else { throw EncodeError.invalidFeature }
        if !s.features.isEmpty {
            w.u8(UInt8(s.features.count))
            for f in s.features {
                guard (1...3).contains(f.kind) else { throw EncodeError.invalidFeature }
                let name = utf8(f.name, max: 31)
                w.u8(f.kind); w.u8(UInt8(name.count)); w.i16(f.point.x); w.i16(f.point.y); w.bytes(name)
            }
        }
        guard w.data.count <= maxPayload else { throw EncodeError.tooLarge(w.data.count) }
        return w.data
    }

    /// POSE (firmware v2): u32 t_ms, i16 pos_x, i16 pos_y, u16 heading_cd, u16 speed_cms — applied to the committed scene.
    static func posePayload(_ s: SGNScene) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { u16(UInt16(v & 0xffff)); u16(UInt16(v >> 16)) }
        u32(s.tMs); u16(UInt16(bitPattern: s.pos.x)); u16(UInt16(bitPattern: s.pos.y)); u16(s.headingCd); u16(s.speedCms)
        return d
    }

    static func packet(op: Op, sid: UInt32, seq: UInt32, payload: Data = Data()) -> Data {
        var w = ByteWriter()
        w.bytes(Array("SGN1".utf8))
        w.u8(1); w.u8(op.rawValue); w.u16(0)
        w.u32(sid); w.u32(seq)
        w.u32(UInt32(payload.count))
        w.u32(payload.isEmpty ? 0 : SGNCRC32.checksum(payload))
        w.u32(0); w.u32(0)
        w.data.append(payload)
        return w.data
    }

    static func scenePacket(_ s: SGNScene, sid: UInt32, seq: UInt32) throws -> Data {
        packet(op: .scene, sid: sid, seq: seq, payload: try encodePayload(s))
    }

    // MARK: Decoding (used by the on-phone glasses preview and tests; mirrors firmware bounds checks)

    struct Header: Equatable { var op: UInt8; var sid: UInt32; var seq: UInt32; var payloadLen: UInt32; var crc: UInt32 }

    static func decodeHeader(_ d: Data) -> Header? {
        guard d.count >= headerSize, d.count <= maxFileSize else { return nil }
        var r = ByteReader(Array(d))
        guard r.bytes(4) == Array("SGN1".utf8), r.u8() == 1, let op = r.u8(), r.u16() != nil,
              let sid = r.u32(), let seq = r.u32(), let len = r.u32(), let crc = r.u32() else { return nil }
        guard Int(len) == d.count - headerSize else { return nil }
        let payload = d.subdata(in: (d.startIndex + headerSize)..<d.endIndex)
        if len > 0, SGNCRC32.checksum(payload) != crc { return nil }
        return Header(op: op, sid: sid, seq: seq, payloadLen: len, crc: crc)
    }

    static func decodeScene(packet d: Data) -> SGNScene? {
        guard let h = decodeHeader(d), h.op == Op.scene.rawValue else { return nil }
        return decodePayload(d.subdata(in: (d.startIndex + headerSize)..<d.endIndex))
    }

    static func decodePayload(_ d: Data) -> SGNScene? {
        var r = ByteReader(Array(d))
        var s = SGNScene()
        guard let t = r.u32(), let px = r.i16(), let py = r.i16(), let hd = r.u16(), let sp = r.u16(), let zm = r.u16(),
              let fl = r.u8(), let ic = r.u8(), let md = r.u32(), let rd = r.u32(), let rt = r.u32(),
              let mx = r.i16(), let my = r.i16(), let rl = r.u8(), let il = r.u8(), let el = r.u8(), let ext = r.u8(), ext <= 1
        else { return nil }
        guard rl <= maxRoadLen, il <= maxInstrLen, el <= maxEtaLen,
              let rb = r.bytes(Int(rl)), let ib = r.bytes(Int(il)), let eb = r.bytes(Int(el)) else { return nil }
        s.tMs = t; s.pos = SGNPoint(x: px, y: py); s.headingCd = hd; s.speedCms = sp; s.zoomMilli = zm
        s.flags = SGNFlags(rawValue: fl); s.icon = ic; s.maneuverDistM = md; s.remainDistM = rd; s.remainTimeS = rt
        s.man = SGNPoint(x: mx, y: my)
        s.road = String(decoding: rb, as: UTF8.self); s.instr = String(decoding: ib, as: UTF8.self); s.eta = String(decoding: eb, as: UTF8.self)
        guard let rn = r.u16(), rn <= maxRoutePoints else { return nil }
        for _ in 0..<rn { guard let x = r.i16(), let y = r.i16() else { return nil }; s.route.append(SGNPoint(x: x, y: y)) }
        guard let rc = r.u16() else { return nil }
        for _ in 0..<rc {
            guard let cls = r.u8(), let n = r.u8(), cls <= 3, n >= 2, n <= maxRoadPoints else { return nil }
            var pts: [SGNPoint] = []
            for _ in 0..<n { guard let x = r.i16(), let y = r.i16() else { return nil }; pts.append(SGNPoint(x: x, y: y)) }
            s.roads.append(SGNRoad(cls: cls, points: pts))
        }
        if ext == 1 {
            guard let count = r.u8(), count <= 16 else { return nil }
            for _ in 0..<count {
                guard let kind = r.u8(), (1...3).contains(kind), let len = r.u8(), len <= 31,
                      let x = r.i16(), let y = r.i16(), let bytes = r.bytes(Int(len)),
                      let name = String(bytes: bytes, encoding: .utf8) else { return nil }
                s.features.append(SGNFeature(kind: kind, point: SGNPoint(x: x, y: y), name: name))
            }
        }
        guard r.remaining == 0 else { return nil }
        return s
    }
}

/// SGR1 reply from the glasses (32 bytes, cmd `spare_nav_v1`).
struct SGR1Reply: Equatable {
    enum Result: UInt8 { case ok = 0, badPacket, busy, stale, uiFailed }
    enum State: UInt8 { case idle = 0, waitingForPhone, navigating, exitedByUser }
    enum Event: UInt32 { case none = 0, userOpenedNavPage, userExited, needFullScene }

    var result: UInt8
    var state: UInt8
    var sid: UInt32
    var seq: UInt32
    var event: UInt32

    var resultValue: Result? { Result(rawValue: result) }
    var stateValue: State? { State(rawValue: state) }
    var eventValue: Event? { Event(rawValue: event) }

    init(result: UInt8, state: UInt8, sid: UInt32, seq: UInt32, event: UInt32) {
        self.result = result; self.state = state; self.sid = sid; self.seq = seq; self.event = event
    }

    init?(data: Data) {
        guard data.count >= 32 else { return nil }
        var r = ByteReader(Array(data.prefix(32)))
        guard r.bytes(4) == Array("SGR1".utf8), r.u8() == 1, let res = r.u8(), let st = r.u8(), r.u8() != nil,
              let sid = r.u32(), let seq = r.u32(), let ev = r.u32() else { return nil }
        self.init(result: res, state: st, sid: sid, seq: seq, event: ev)
    }

    func encoded() -> Data {
        var w = ByteWriter()
        w.bytes(Array("SGR1".utf8)); w.u8(1); w.u8(result); w.u8(state); w.u8(0)
        w.u32(sid); w.u32(seq); w.u32(event)
        w.bytes([UInt8](repeating: 0, count: 12))
        return w.data
    }
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}

struct ByteReader {
    let buf: [UInt8]
    var pos = 0
    init(_ b: [UInt8]) { buf = b }
    var remaining: Int { buf.count - pos }
    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, remaining >= n else { return nil }
        defer { pos += n }
        return Array(buf[pos..<(pos + n)])
    }
    mutating func u8() -> UInt8? { bytes(1)?[0] }
    mutating func u16() -> UInt16? { bytes(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 } }
    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    mutating func u32() -> UInt32? { bytes(4).map { $0.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } } }
}
