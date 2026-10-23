import CoreGraphics
import XCTest
@testable import RayNeoSimulator

/// Fixtures captured from the real Aapp Host 0.13.8 (Pixel 5) talking to this simulator.
final class AappRealHostTests: XCTestCase {
    /// 场景交互 sample, first micro batch: UIRoot without `active`, Column → Text, Space, Row(Text 增加, Space, Text 重置),
    /// Space, Text; clickable focusable Texts; ModalLayer/PopupLayer Stacks; focusWrapEnabled=false.
    static let sceneInteraction = Data(hex: "0101000000060000005549526f6f740401000000050000007769647468020000000000e08040040100000006000000686569676874020000000000806b40010200000006000000436f6c756d6e0402000000050000007370616365020000000000000000040200000005000000616c69676e030500000073746172740402000000070000006a75737469667903050000007374617274020200000001000000000000000103000000040000005465787404030000000400000074657874030a000000e8aea1e695b0efbc9a30040300000008000000666f6e7453697a6502000000000000364004030000000900000074657874436f6c6f72020000e0ffffffef41020300000002000000000000000104000000050000005370616365040400000009000000737061636553697a6502000000000000284002040000000200000001000000010500000003000000526f770405000000050000007370616365020000000000000000040500000005000000616c69676e030500000073746172740405000000070000006a757374696679030500000073746172740205000000020000000200000001060000000400000054657874040600000004000000746578740306000000e5a29ee58aa0050600000005000000636c69636b0406000000050000007769647468020000000000805b4004060000000600000068656967687402000000000000464004060000000900000074657874436f6c6f72020000e0ffffffef41040600000009000000666f63757361626c650101020600000005000000000000000107000000050000005370616365040700000009000000737061636553697a650200000000000030400207000000050000000100000001080000000400000054657874040800000004000000746578740306000000e9878de7bdae050800000005000000636c69636b0408000000050000007769647468020000000000805b4004080000000600000068656967687402000000000000464004080000000900000074657874436f6c6f72020000e0ffffffef41040800000009000000666f63757361626c650101020800000005000000020000000109000000050000005370616365040900000009000000737061636553697a6502000000000000284002090000000200000003000000010a0000000400000054657874040a00000004000000746578740327000000e782b9e587bbe68c89e992aeefbc8ce68896e5b7a6e58fb3e994aee5908ee58d95e587bbe38082040a00000008000000666f6e7453697a65020000000000003040040a0000000900000074657874436f6c6f72020000e0ffffffef41020a0000000200000004000000010b00000005000000537461636b040b0000000700000067726176697479030600000063656e746572040b000000080000006e6f6465526f6c65030a0000004d6f64616c4c61796572040b0000000500000077696474680200000000000059c0040b000000060000006865696768740200000000000059c0040b0000000700000067726176697479030600000063656e746572040b0000000c000000696e707574456e61626c65640100010c00000005000000537461636b040c0000000700000067726176697479030600000063656e746572040c000000080000006e6f6465526f6c65030a000000506f7075704c61796572040c0000000500000077696474680200000000000059c0040c000000060000006865696768740200000000000059c0040c0000000700000067726176697479030c000000626f74746f6d43656e746572040c0000000c000000696e707574456e61626c65640101020b0000000100000001000000020c0000000100000002000000040100000010000000666f63757357726170456e61626c65640100")

    private func openMicro(_ session: AappSession) {
        _ = session.handle(AappPacket(.open, session: 2, request: 4, payload: AappProtocolTests.json(["name": "场景交互", "appId": "com.aapp.samples.sceneinteraction", "renderMode": "micro"])))
        var open = AappWriter(); open.u8(2); open.u8(0); open.u8(0); open.u8(0); open.u64(2)
        _ = session.handle(AappPacket(.inputControl, session: 2, request: 5, payload: AappInputEnvelope(opcode: 2, requestId: 5, sessionId: 2, sequence: 0, body: open.data).encoded()))
    }

    func testRealSceneInteractionTreeDraws() throws {
        let session = AappSession()
        openMicro(session)
        let out = session.handle(AappPacket(.microCommands, session: 2, request: 6, payload: Self.sceneInteraction))
        XCTAssertEqual(out.replies.first?.message, .ack)
        let px = Pixels(try XCTUnwrap(out.frame ?? nil))
        // "计数：0" (22 pt white) at the top-left: some bright pixels in the first 30 rows.
        var lit = 0
        for y in 0..<30 { for x in 0..<120 where px.rgb(x, y)[0] > 200 { lit += 1 } }
        XCTAssertGreaterThan(lit, 50, "counter text drawn")
        // Enter clicks 增加 (node 6), → then Enter clicks 重置 (node 8): what the app answered with 计数：1 / 计数：0.
        XCTAssertEqual(session.key(.enter).replies.first?.payload, AappUIEvents.click(node: 6, key: "click"))
        _ = session.key(.right)
        XCTAssertEqual(session.key(.enter).replies.first?.payload, AappUIEvents.click(node: 8, key: "click"))
        // focusWrapEnabled=false: → past the last item stays on it.
        _ = session.key(.right)
        XCTAssertEqual(session.key(.enter).replies.first?.payload, AappUIEvents.click(node: 8, key: "click"))
    }

    func testWheelPickerReportsChanges() throws {
        let session = AappSession()
        openMicro(session)
        var w = AappWriter()
        w.u8(1); w.u32(1); w.string("UIRoot")
        w.u8(1); w.u32(2); w.string("WheelPicker")
        w.u8(4); w.u32(2); w.string("wheelConfig"); w.u8(3)
        w.string(#"{"items":[{"value":5,"label":"5 分钟"},{"value":10,"label":"10 分钟"},{"value":15,"label":"15 分钟"}],"value":10,"loop":true,"visibleCount":3,"version":1}"#)
        w.u8(2); w.u32(2); w.u32(1); w.u32(0)
        let out = session.handle(AappPacket(.microCommands, session: 2, request: 6, payload: w.data))
        XCTAssertEqual(out.replies.count, 2, "ack + initial wheel state")
        func wheelEvents(_ o: AappSession.Output) -> [[String: Any]] {
            o.replies.filter { $0.message == .uiEvents }.flatMap { packet -> [[String: Any]] in
                var r = AappReader(packet.payload)
                guard (try? r.u8()) == 1, let count = try? r.u16() else { return [] }
                return (0..<Int(count)).compactMap { _ in
                    guard let type = try? r.u8(), let len = try? r.u32(), let body = try? r.take(Int(len)), type == 8 else { return nil }
                    var b = AappReader(body); _ = try? b.u32(); _ = try? b.string()
                    return (try? b.string()).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                }
            }
        }
        XCTAssertEqual(wheelEvents(out).first?["phase"] as? String, "state")
        XCTAssertEqual(wheelEvents(session.key(.enter)).first?["adjusting"] as? Bool, true)
        let change = try XCTUnwrap(wheelEvents(session.key(.down)).first)
        XCTAssertEqual(change["phase"] as? String, "change"); XCTAssertEqual(change["value"] as? Int, 15)
        XCTAssertEqual(change["version"] as? Int, 1); XCTAssertEqual(change["revision"] as? Int, 3)
        let commit = try XCTUnwrap(wheelEvents(session.key(.enter)).first)
        XCTAssertEqual(commit["phase"] as? String, "commit"); XCTAssertEqual(commit["adjusting"] as? Bool, false)
    }

    func testStreamResourceImageIsBoundAndDrawn() throws {
        let session = AappSession()
        openMicro(session)
        let png = AppProtocolPNG.red8
        func asr(_ op: UInt8, _ body: Data) -> AappPacket {
            AappPacket(.streamResource, session: 2, request: 9, payload: AappStreamResources.frame(op, body: body))
        }
        func replyBody(_ out: AappSession.Output, _ op: UInt8) -> Data? {
            guard let p = out.replies.first, p.message == .ack, p.payload.count >= 12, p.payload[p.payload.startIndex + 5] == op | 0x80,
                  p.payload.leU16(at: p.payload.startIndex + 6) == 0 else { return nil }
            return Data(p.payload.dropFirst(12))
        }
        var ensure = AappWriter(); ensure.u32(7)
        XCTAssertEqual(replyBody(session.handle(asr(0x11, ensure.data)), 0x11)?.hexString, "070000000000000000000000")
        var write = AappWriter(); write.u32(7); write.u64(0); write.bytes(png)
        XCTAssertNotNil(replyBody(session.handle(asr(0x12, write.data)), 0x12))
        var cursor = AappWriter(); cursor.u32(7); cursor.u32(3); cursor.u64(UInt64(png.count)); cursor.u32(1)
        XCTAssertEqual(replyBody(session.handle(asr(0x13, cursor.data)), 0x13), cursor.data)
        let id = Data("network:abc".utf8)
        var bind = AappWriter(); bind.u32(3); bind.u16(1); bind.u16(1); bind.u32(UInt32(id.count)); bind.u32(16); bind.bytes(id)
        bind.u16(1); bind.u16(0); bind.u32(8); bind.u32(8); bind.u32(0)
        XCTAssertEqual(replyBody(session.handle(asr(0x15, bind.data)), 0x15)?.hexString, "03000000")
        var tree = AappWriter()
        tree.u8(1); tree.u32(1); tree.string("UIRoot")
        tree.u8(1); tree.u32(2); tree.string("Image")
        tree.u8(4); tree.u32(2); tree.string("res"); tree.u8(3); tree.string("network:abc")
        tree.u8(4); tree.u32(2); tree.string("width"); tree.u8(2); tree.f64(40)
        tree.u8(4); tree.u32(2); tree.string("height"); tree.u8(2); tree.f64(40)
        tree.u8(2); tree.u32(2); tree.u32(1); tree.u32(0)
        let out = session.handle(AappPacket(.microCommands, session: 2, request: 10, payload: tree.data))
        XCTAssertEqual(Pixels(try XCTUnwrap(out.frame ?? nil)).rgb(20, 20), [255, 0, 0])
        // Writing at a wrong offset is an error status, not a crash.
        var bad = AappWriter(); bad.u32(7); bad.u64(1); bad.bytes(Data([1, 2]))
        XCTAssertNil(replyBody(session.handle(asr(0x12, bad.data)), 0x12))
    }

    func testMutatedRealTrafficNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let session = AappSession()
        openMicro(session)
        _ = session.handle(AappPacket(.microCommands, session: 2, request: 6, payload: Self.sceneInteraction))
        for round in 0..<20000 {
            var bytes = Self.sceneInteraction
            for _ in 0..<Int.random(in: 1...12, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            if Bool.random(using: &rng) { bytes = bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)) }
            _ = session.handle(AappPacket(.microCommands, session: 2, request: UInt32(round), payload: bytes))
            var asr = AappStreamResources.frame(UInt8.random(in: 0x10...0x16, using: &rng), body: Data((0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
            if Bool.random(using: &rng) { asr[Int.random(in: 0..<asr.count, using: &rng)] ^= 0xff }
            _ = session.handle(AappPacket(.streamResource, session: 2, request: UInt32(round), payload: asr))
            _ = session.key([.up, .down, .left, .right, .enter, .escape].randomElement(using: &rng)!)
            _ = session.tap(x: Double.random(in: -10...600, using: &rng), y: Double.random(in: -10...300, using: &rng))
        }
    }

    func testHelloAdvertisesImageStreams() throws {
        let hello = AappSession().helloReply
        XCTAssertEqual(hello["streamResourceVersion"] as? Int, 1)
        XCTAssertEqual(hello["imageResourceDescriptorVersion"] as? Int, 1)
        XCTAssertEqual(hello["imageResourceFormats"] as? Int, 15)
    }
}

enum AppProtocolPNG {
    static let red8 = AappProtocolTests.solidPNG(red: 255, green: 0, blue: 0, size: 8)
}
