import XCTest
@testable import RayNeoSimulator

final class FirmwareFrameTests: XCTestCase {
    func testStereoFramePreservesPixelsAndRejectsPartialWrites() throws {
        let header = Data("P5\n2 1\n255\n".utf8)
        let data = header + Data([10, 255])
        let image = try XCTUnwrap(FirmwareFrame.decodeStereo(data))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.dataProvider?.data as Data?, Data([2, 10, 2, 255, 51, 255, 63, 255]))  // grey rendered green
        for count in 0..<data.count { XCTAssertNil(FirmwareFrame.decode(data.prefix(count))) }
        XCTAssertNil(FirmwareFrame.decode(Data("P5\n9999999 2\n255\n".utf8)))
        XCTAssertNil(FirmwareFrame.decode(Data("P6\n2 1\n255\n".utf8) + Data([10, 255])))
    }

    func testSingleEyeShowsLeftEye() throws {
        // 4x1 canvas: left eye [0, 200], right eye [120, 0] (shifted for depth) -> the left eye only.
        let data = Data("P5\n4 1\n255\n".utf8) + Data([0, 200, 120, 0])
        let decoded = try XCTUnwrap(FirmwareFrame.decode(data))
        XCTAssertEqual(decoded.image.width, 2)
        XCTAssertFalse(decoded.blank)
        XCTAssertEqual(decoded.image.dataProvider?.data as Data?, Data([0, 0, 0, 255, 40, 200, 50, 255]))
    }

    func testRightEyeWhenLeftIsBlank() throws {
        let data = Data("P5\n4 1\n255\n".utf8) + Data([0, 0, 120, 0])
        let decoded = try XCTUnwrap(FirmwareFrame.decode(data))
        XCTAssertEqual(decoded.image.dataProvider?.data as Data?, Data([24, 120, 30, 255, 0, 0, 0, 255]))
    }

    func testBlankFrame() throws {
        let decoded = try XCTUnwrap(FirmwareFrame.decode(Data("P5\n4 1\n255\n".utf8) + Data([0, 3, 0, 0])))
        XCTAssertTrue(decoded.blank)
    }
}
