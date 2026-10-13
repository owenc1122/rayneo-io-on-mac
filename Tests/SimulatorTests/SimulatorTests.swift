import XCTest
import AppKit
import NavigationCore
@testable import RayNeoSimulator

final class SimulatorTests: XCTestCase {
    func testFeaturesRoundTripAndFirmwareValidation() throws {
        var s = SGNScene()
        s.features = [SGNFeature(kind: 1,point: .init(x: 80,y: 200)), SGNFeature(kind: 2,point: .init(x: -100,y: 280)), SGNFeature(kind: 3,point: .init(x: -350,y: 180),name: "自然博物馆")]
        let data = try SGN1.encodePayload(s)
        XCTAssertEqual(SGN1.decodePayload(data),s)
        var parsed = SGScene()
        XCTAssertTrue(data.withUnsafeBytes { sg_scene_parse($0.bindMemory(to: UInt8.self).baseAddress,data.count,&parsed) })
        XCTAssertEqual(parsed.feature_count,3)
        for length in 0..<data.count {
            XCTAssertFalse(data.withUnsafeBytes { sg_scene_parse($0.bindMemory(to: UInt8.self).baseAddress,length,nil) })
        }
        var broken = data; broken[broken.count-1] = 0xff
        XCTAssertFalse(broken.withUnsafeBytes { sg_scene_parse($0.bindMemory(to: UInt8.self).baseAddress,broken.count,nil) })
        s.features = Array(repeating:s.features[0],count:17)
        XCTAssertThrowsError(try SGN1.encodePayload(s))
    }
    func testOldSceneAndRendererControls() throws {
        var s = SGNScene(); s.route = [.init(x: 0,y: 0),.init(x: 0,y: 400),.init(x: 400,y: 400)]
        let packet = try SGN1.scenePacket(s,sid: 1,seq: 1)
        let core = try XCTUnwrap(rn_create()); defer { rn_destroy(core) }
        XCTAssertEqual(packet.withUnsafeBytes { rn_receive(core,$0.bindMemory(to: UInt8.self).baseAddress,packet.count,0) },0)
        rn_orientation(core,0,0)
        let before = Data(bytes:rn_draw(core,0)!,count:512*128)
        rn_zoom(core,1,10); rn_orientation(core,90,1000)
        _ = rn_draw(core,1000); rn_orientation(core,90,1100)
        let after = Data(bytes:rn_draw(core,1100)!,count:512*128)
        XCTAssertNotEqual(before,after)
        XCTAssertLessThan(rn_mpp(core),2)
        XCTAssertEqual(packet.withUnsafeBytes { rn_receive(core,$0.bindMemory(to: UInt8.self).baseAddress,packet.count,1200) },Int32(SG_STALE.rawValue))
    }
    func testFeatureAnchorsRemainCentered() throws {
        var s = SGNScene()
        s.features = [SGNFeature(kind: 1, point: .init(x: 40, y: 120))]
        let packet = try SGN1.scenePacket(s, sid: 1, seq: 1)
        let core = try XCTUnwrap(rn_create()); defer { rn_destroy(core) }
        XCTAssertEqual(packet.withUnsafeBytes { rn_receive(core, $0.bindMemory(to: UInt8.self).baseAddress, packet.count, 0) }, 0)
        rn_orientation(core, 0, 0); _ = rn_draw(core, 0)
        var labels = [SGFeatureLabel](repeating: SGFeatureLabel(), count: 8)
        XCTAssertEqual(rn_labels(core, &labels), 1)
        XCTAssertEqual(Int(labels[0].x) + 9, 331 + 10)
        XCTAssertEqual(Int(labels[0].y) + 9, Int(SG_MAP_CY) - 30)
        rn_orientation(core, 90, 10000); _ = rn_draw(core, 10000)
        for t in stride(from: 11000, through: 20000, by: 1000) {
            rn_orientation(core, 90, UInt32(t)); _ = rn_draw(core, UInt32(t))
        }
        XCTAssertEqual(rn_labels(core, &labels), 1)
        XCTAssertEqual(Int(labels[0].x) + 9, 331 - 30, accuracy: 1)
        XCTAssertEqual(Int(labels[0].y) + 9, Int(SG_MAP_CY) - 10, accuracy: 1)
    }
    @MainActor func testGreenFrameAndExactExportSize() throws {
        let model = SimulatorModel()
        let bitmap = try XCTUnwrap(model.frame?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 512); XCTAssertEqual(bitmap.pixelsHigh, 128)
        var lit = 0
        for y in 0..<128 { for x in 0..<512 {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.greenComponent > 0.2 else { continue }
            XCTAssertGreaterThan(c.greenComponent, c.redComponent)
            XCTAssertGreaterThan(c.greenComponent, c.blueComponent); lit += 1
        } }
        XCTAssertGreaterThan(lit, 100)
    }
    func testScenarioRejectsInvalidCoordinate() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("Examples/campus.json"))
        let scene = try JSONDecoder().decode(Scenario.self,from:data).scene()
        XCTAssertEqual(scene.features.count,5)
        let bad = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"[0, 0]",with:"[999999, 0]")
        XCTAssertThrowsError(try JSONDecoder().decode(Scenario.self,from:Data(bad.utf8)).scene())
    }
}
