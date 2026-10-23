import CoreGraphics
import Darwin
import XCTest
@testable import RayNeoSimulator

/// Fixtures are byte streams that rendered correctly on the official RTOS Simulator (research fake Host).
final class AappProtocolTests: XCTestCase {
    /// drawFrame test frame: white text, green stroked rounded rect, filled green circle, white line (540×220).
    static let shapesFrame = Data(hex: "4144524602000000074400005c43050000000100000043000000040000000700000023303030303030070000002346464646464607000000233030464638381a000000537061726520e58d8fe8aeaee6b58be8af952041445246207632020000001d0000000300000002000000080109000000080218012500000040020000000802030000000400000000000000040000007f000000000000000200000008000b00000013000000080010031d0000804125000040412d0000c041080000001b000000080115000080411d0000704225000048432d0000a042350000404109000000110000000802150000a0431d0000c84225000010420700000016000000080015000080411d0000344325000002442d00003443050000000400000000000000")
    /// micro tree: UIRoot(active) → Column(540×220, centred) → Text + Button(Text) with a click event.
    static let microTree = Data(hex: "0101000000060000005549526f6f7404010000000a0000006261636b67726f756e64020000000000e0ef410401000000060000006163746976650101010200000006000000436f6c756d6e0402000000050000007769647468020000000000e08040040200000006000000686569676874020000000000806b40040200000005000000616c69676e030600000063656e7465720402000000070000006a757374696679030600000063656e746572010300000004000000546578740403000000040000007465787403120000006d6963726f20e6a8a1e5bc8f2048656c6c6f040300000008000000666f6e7453697a65020000000000003c4004030000000900000074657874436f6c6f72020000e0ffffffef41010400000006000000427574746f6e040400000005000000776964746802000000000000644004040000000600000068656967687402000000000000464004040000000a0000006261636b67726f756e64020000a049efe3ef4104040000000c000000626f72646572526164697573020000000000002440040400000009000000666f63757361626c65010101050000000400000054657874040500000004000000746578740306000000e68c89e992ae040500000008000000666f6e7453697a6502000000000000344004050000000900000074657874436f6c6f72020000e0ffffffef41050400000005000000636c69636b02020000000100000000000000020300000002000000000000000204000000020000000100000002050000000400000000000000")

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: framing

    func testFramerSplitsAndReassemblesPackets() throws {
        let a = AappPacket(.ping, session: 0, request: 7)
        let b = AappPacket(.frame, session: 1, request: 5, payload: Self.shapesFrame)
        XCTAssertEqual(b.encoded().prefix(16).hexString, "2d010000010006000100000005000000")   // research doc example header
        let stream = a.encoded() + b.encoded()
        var framer = AappFramer()
        var got: [AappPacket] = []
        for byte in stream { framer.append(Data([byte])); while let p = try framer.next() { got.append(p) } }
        XCTAssertEqual(got, [a, b])
        XCTAssertTrue(framer.buffer.isEmpty)
    }

    func testFramerRejectsBadLengthAndVersion() {
        var framer = AappFramer()
        framer.append(Data([11, 0, 0, 0]))
        XCTAssertThrowsError(try framer.next())
        framer = AappFramer()
        var w = AappWriter(); w.u32(UInt32(AappPacket.maxLength + 1))
        framer.append(w.data)
        XCTAssertThrowsError(try framer.next())
        framer = AappFramer()
        var v = AappWriter(); v.u32(12); v.u16(2); v.u16(8); v.u32(0); v.u32(1)
        framer.append(v.data)
        XCTAssertThrowsError(try framer.next())
    }

    // MARK: handshake and input

    func testHelloAdvertisesWhatTheHostRequires() throws {
        let session = AappSession()
        let out = session.handle(AappPacket(.hello, request: 1, payload: Self.json(["inputEventVersion": 1, "inputEnvelopeVersion": 1])))
        XCTAssertEqual(out.replies.count, 1)
        let reply = out.replies[0]
        XCTAssertEqual(reply.message, .ack); XCTAssertEqual(reply.request, 1)
        let hello = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.payload) as? [String: Any])
        XCTAssertEqual(hello["inputEventVersion"] as? Int, 1)
        XCTAssertEqual(hello["inputEnvelopeVersion"] as? Int, 1)
        XCTAssertEqual(hello["drawFrameVersion"] as? Int, 2)
        XCTAssertEqual(hello["microCommandVersion"] as? Int, 1)
        XCTAssertEqual(hello["uiEventVersion"] as? Int, 1)
        XCTAssertEqual(hello["renderModes"] as? [String], ["drawFrame", "micro"])
        XCTAssertNotNil(hello["name"] as? String)
        XCTAssertEqual(hello["width"] as? Int, 540); XCTAssertEqual(hello["height"] as? Int, 220)
    }

    func testInputControlRepliesMatchOfficialSimulator() throws {
        let session = AappSession()
        _ = session.handle(AappPacket(.open, session: 1, request: 2, payload: Self.json(["name": "t", "appId": "a", "renderMode": "drawFrame"])))
        let caps = AappInputEnvelope(opcode: 1, requestId: 3, sessionId: 0, sequence: 0, body: Data())
        var out = session.handle(AappPacket(.inputControl, session: 0, request: 3, payload: caps.encoded()))
        XCTAssertEqual(out.replies[0].message, .inputControl)
        XCTAssertEqual(out.replies[0].payload.hexString,
                       "b201800003000000000000000000000000000000140000000100000001000000000220000000000000000000")
        var open = AappWriter(); open.u8(1); open.u8(0); open.u8(0); open.u8(0); open.u64(1)
        let openEnvelope = AappInputEnvelope(opcode: 2, requestId: 4, sessionId: 1, sequence: 0, body: open.data)
        out = session.handle(AappPacket(.inputControl, session: 1, request: 4, payload: openEnvelope.encoded()))
        XCTAssertEqual(out.replies[0].payload.hexString, "b2018000040000000100000000000000000000000400000002000000")
        // → key push, as the official simulator sends it.
        out = session.key(.right)
        XCTAssertEqual(out.replies.count, 1)
        XCTAssertEqual(out.replies[0].message, .input)
        XCTAssertEqual(out.replies[0].session, 1); XCTAssertEqual(out.replies[0].request, 0)
        XCTAssertEqual(out.replies[0].payload.hexString, "b2018100000000000100000000000000010000000d000000010001000104000000" + "27000000")
        // Sequence increases.
        out = session.key(.enter)
        XCTAssertEqual(try AappInputEnvelope.decode(out.replies[0].payload).sequence, 2)
    }

    func testAcquireImuIsUnsupported() throws {
        let session = AappSession()
        var body = AappWriter(); body.u32(1); body.u8(1); body.u8(1); body.u16(50); body.u16(6000); body.u16(0)
        let env = AappInputEnvelope(opcode: 4, requestId: 9, sessionId: 1, sequence: 0, body: body.data)
        let out = session.handle(AappPacket(.inputControl, session: 1, request: 9, payload: env.encoded()))
        let reply = try AappInputEnvelope.decode(out.replies[0].payload)
        XCTAssertEqual(reply.opcode, 0x80)
        XCTAssertEqual([UInt8](reply.body), [4, 1, 0, 0])
    }

    // MARK: drawFrame

    func testShapesFrameDecodesAndRenders() throws {
        let frame = try ADRFDecoder.decode(Self.shapesFrame)
        XCTAssertEqual(frame.width, 540); XCTAssertEqual(frame.height, 220)
        XCTAssertEqual(frame.commands.count, 5)
        let session = AappSession()
        _ = session.handle(AappPacket(.open, session: 1, request: 2, payload: Self.json(["name": "t", "appId": "a", "renderMode": "drawFrame"])))
        let out = session.handle(AappPacket(.frame, session: 1, request: 5, payload: Self.shapesFrame))
        XCTAssertEqual(String(data: out.replies[0].payload, encoding: .utf8), #"{"frame":1,"status":"submitted"}"#)
        let image = try XCTUnwrap(out.frame ?? nil)
        XCTAssertEqual(image.width, 540); XCTAssertEqual(image.height, 220)
        let px = Pixels(image)
        XCTAssertEqual(px.rgb(320, 100), [0, 255, 136], "filled circle centre is #00FF88")
        XCTAssertEqual(px.rgb(100, 100), [0, 0, 0], "inside the stroked rect stays black")
        XCTAssertGreaterThan(px.rgb(16, 100)[1], 100, "left edge of the stroked rect is green")
        XCTAssertGreaterThan(px.rgb(300, 180)[0], 100, "the line at y=180 is drawn")
        XCTAssertEqual(px.rgb(400, 30), [0, 0, 0])
    }

    func testBadFrameIsAnErrorReplyNotACrash() {
        let session = AappSession()
        var bad = Self.shapesFrame; bad[0] = 0
        let out = session.handle(AappPacket(.frame, session: 1, request: 6, payload: bad))
        XCTAssertEqual(out.replies.first?.message, .error)
        XCTAssertEqual(out.replies.first?.request, 6)
    }

    func testImageResourceIsDrawn() throws {
        let png = Self.solidPNG(red: 255, green: 0, blue: 0, size: 8)
        let session = AappSession()
        _ = session.handle(AappPacket(.open, session: 1, request: 1, payload: Self.json(["name": "i", "appId": "i", "renderMode": "drawFrame"])))
        var w = AappWriter(); w.string("res/red.png"); w.bytes(png)
        XCTAssertEqual(session.handle(AappPacket(.resource, session: 1, request: 2, payload: w.data)).replies.first?.message, .ack)
        let frame = TestADRF(width: 540, height: 220)
        frame.image("res/red.png", x: 20, y: 20, w: 64, h: 64, fit: 0)
        let out = session.handle(AappPacket(.frame, session: 1, request: 3, payload: frame.encode()))
        XCTAssertEqual(Pixels(try XCTUnwrap(out.frame ?? nil)).rgb(50, 50), [255, 0, 0])
    }

    // MARK: micro

    func testMicroTreeRendersAndClicks() throws {
        let session = AappSession()
        _ = session.handle(AappPacket(.open, session: 1, request: 2, payload: Self.json(["name": "m", "appId": "m", "renderMode": "micro"])))
        let out = session.handle(AappPacket(.microCommands, session: 1, request: 3, payload: Self.microTree))
        XCTAssertEqual(out.replies.first?.message, .ack)
        let px = Pixels(try XCTUnwrap(out.frame ?? nil))
        // Button 160×44 centred under the text: its background #1F7A4D around (270, 130).
        XCTAssertEqual(px.rgb(220, 140), [0x1f, 0x7a, 0x4d])
        XCTAssertEqual(px.rgb(20, 20), [0, 0, 0])
        // Enter clicks the focused button: same bytes as the official simulator.
        let click = session.key(.enter)
        XCTAssertEqual(click.replies.first?.message, .uiEvents)
        XCTAssertEqual(click.replies.first?.payload.hexString, "010100010d0000000400000005000000636c69636b")
    }

    func testMicroRootShowsUnlessActiveFalse() throws {
        // The real Host never sends `active` on UIRoot; the tree must still draw. active=false hides it.
        let session = AappSession()
        _ = session.handle(AappPacket(.open, session: 1, request: 2, payload: Self.json(["name": "m", "appId": "m", "renderMode": "micro"])))
        var w = AappWriter()
        w.u8(1); w.u32(1); w.string("UIRoot")
        w.u8(4); w.u32(1); w.string("background"); w.u8(2); w.f64(Double(0xffff0000 as UInt32))
        var out = session.handle(AappPacket(.microCommands, session: 1, request: 3, payload: w.data))
        XCTAssertEqual(Pixels(try XCTUnwrap(out.frame ?? nil)).rgb(10, 10), [255, 0, 0], "root without active draws")
        var off = AappWriter()
        off.u8(4); off.u32(1); off.string("active"); off.u8(1); off.u8(0)
        out = session.handle(AappPacket(.microCommands, session: 1, request: 4, payload: off.data))
        XCTAssertEqual(Pixels(try XCTUnwrap(out.frame ?? nil)).rgb(10, 10), [0, 0, 0], "active=false hides the tree")
    }

    // MARK: robustness

    func testRandomInputNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let session = AappSession()
        _ = session.handle(AappPacket(.open, session: 1, request: 1, payload: Self.json(["name": "f", "appId": "f", "renderMode": "micro"])))
        for round in 0..<20000 {
            let length = Int.random(in: 0...300, using: &rng)
            var bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            // Mutations of valid inputs reach deeper than pure noise.
            if round % 3 == 0 {
                bytes = round % 2 == 0 ? Self.shapesFrame : Self.microTree
                for _ in 0..<Int.random(in: 1...8, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
                if Bool.random(using: &rng) { bytes = bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)) }
            }
            _ = try? ADRFDecoder.decode(bytes)
            _ = try? MicroCommand.parse(bytes)
            _ = try? AappInputEnvelope.decode(bytes)
            var framer = AappFramer(); framer.append(bytes); _ = try? framer.next()
            let type = AappMessage.allCases.randomElement(using: &rng)!
            _ = session.handle(AappPacket(type, session: 1, request: UInt32(round), payload: bytes))
            _ = session.key([.up, .down, .enter, .escape].randomElement(using: &rng)!)
        }
    }

    // MARK: server over a real socket

    func testServerHandshakeOverTCP() throws {
        let ready = expectation(description: "listening")
        var port: UInt16 = 0
        var frames: [CGImage?] = []
        let lock = NSLock()
        let server = AappServer(callbacks: .init(frame: { image in lock.lock(); frames.append(image); lock.unlock() }))
        try server.start(port: 0) { result in if case .success(let p) = result { port = p }; ready.fulfill() }
        wait(for: [ready], timeout: 5)
        defer { server.stop() }
        XCTAssertNotEqual(port, 0)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(connected, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        func send(_ p: AappPacket) { let d = p.encoded(); _ = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, d.count, 0) } }
        var framer = AappFramer()
        func receive() throws -> AappPacket {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                if let p = try framer.next() { return p }
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0 else { throw AappReaderError(description: "recv \(n)") }
                framer.append(Data(buffer[0..<n]))
            }
        }
        send(AappPacket(.hello, request: 1, payload: Self.json(["inputEventVersion": 1, "inputEnvelopeVersion": 1])))
        let hello = try receive()
        XCTAssertEqual(hello.message, .ack); XCTAssertEqual(hello.request, 1)
        send(AappPacket(.open, session: 1, request: 2, payload: Self.json(["name": "t", "appId": "a", "renderMode": "drawFrame"])))
        XCTAssertEqual(try receive().request, 2)
        send(AappPacket(.frame, session: 1, request: 3, payload: Self.shapesFrame))
        let ack = try receive()
        XCTAssertEqual(ack.request, 3)
        XCTAssertEqual(String(data: ack.payload, encoding: .utf8), #"{"frame":1,"status":"submitted"}"#)
        // Garbage closes the connection instead of crashing or growing a buffer.
        send(AappPacket(rawType: 8, session: 0, request: 4, payload: Data()))
        XCTAssertEqual(try receive().request, 4)
        var junk = AappWriter(); junk.u32(3); junk.u32(0xdeadbeef)
        _ = junk.data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, junk.data.count, 0) }
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(recv(fd, &byte, 1, 0), 0, "server closes the corrupt stream")
        lock.lock(); let rendered = frames.compactMap { $0 }.count; lock.unlock()
        XCTAssertGreaterThanOrEqual(rendered, 1)
    }

    // MARK: helpers

    static func solidPNG(red: UInt8, green: UInt8, blue: UInt8, size: Int) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        return data as Data
    }
}

/// Reads sRGB pixels of a rendered frame (top-left origin).
struct Pixels {
    let bytes: [UInt8], width: Int
    init(_ image: CGImage) {
        width = image.width
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bytes = buffer
    }
    func rgb(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * width + x) * 4; return Array(bytes[i..<(i + 3)]) }
}

/// Minimal ADRF v2 encoder for tests (mirrors the research codec).
final class TestADRF {
    let width: Float, height: Float
    var strings: [String] = [], commands = Data()
    init(width: Float, height: Float) { self.width = width; self.height = height }
    func s(_ t: String) -> Int { if let i = strings.firstIndex(of: t) { return i }; strings.append(t); return strings.count - 1 }
    private func varint(_ v: Int, _ w: inout AappWriter) { var v = UInt64(v); while v >= 0x80 { w.u8(UInt8(v & 0x7f) | 0x80); v >>= 7 }; w.u8(UInt8(v)) }
    func image(_ res: String, x: Float, y: Float, w: Float, h: Float, fit: Int) {
        var f = AappWriter()
        varint(1 << 3, &f); varint(s(res), &f)
        for (n, v) in [x, y, w, h].enumerated() { varint((n + 2) << 3 | 5, &f); f.f32(v) }
        varint(6 << 3, &f); varint(fit, &f)
        var c = AappWriter(); c.u16(10); c.u16(0); c.u32(UInt32(f.data.count)); c.bytes(f.data)
        commands.append(c.data)
    }
    func encode() -> Data {
        var strTable = AappWriter(); strTable.u32(UInt32(strings.count)); for t in strings { strTable.string(t) }
        var empty = AappWriter(); empty.u32(0)
        let sections: [(UInt16, Data)] = [(1, strTable.data), (2, empty.data), (3, empty.data), (4, commands), (5, empty.data)]
        var w = AappWriter()
        w.u32(0x46524441); w.u16(2); w.f32(width); w.f32(height); w.u32(UInt32(sections.count))
        for (kind, body) in sections { w.u16(kind); w.u16(0); w.u32(UInt32(body.count)); w.bytes(body) }
        return w.data
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        self.init(bytes)
    }
}
