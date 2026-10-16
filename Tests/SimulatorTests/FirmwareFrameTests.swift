import XCTest
@testable import RayNeoSimulator

final class FirmwareFrameTests: XCTestCase {
    func testFramePreservesPixelsAndRejectsPartialWrites() throws {
        let header = Data("P5\n2 1\n255\n".utf8)
        let data = header + Data([10, 255])
        let image = try XCTUnwrap(FirmwareFrame.decode(data))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.dataProvider?.data as Data?, Data([2, 10, 2, 255, 51, 255, 63, 255]))  // grey rendered green
        for count in 0..<data.count { XCTAssertNil(FirmwareFrame.decode(data.prefix(count))) }
        XCTAssertNil(FirmwareFrame.decode(Data("P5\n9999999 2\n255\n".utf8)))
        XCTAssertNil(FirmwareFrame.decode(Data("P6\n2 1\n255\n".utf8) + Data([10, 255])))
    }
}
