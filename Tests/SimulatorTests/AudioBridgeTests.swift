import XCTest
@testable import RayNeoSimulator

final class AudioBridgeTests: XCTestCase {
    func testWholeUtterancesOnly() {
        // a stream that started at 0 and is still being produced: nothing until a full chunk exists
        XCTAssertEqual(AudioBridge.playableLimit(events: "0 start aplay1\n", fileSize: 500, played: 0, chunk: 1000), 0)
        XCTAssertEqual(AudioBridge.playableLimit(events: "0 start aplay1\n", fileSize: 2500, played: 0, chunk: 1000), 2000)
        // once it ended, all of it plays
        XCTAssertEqual(AudioBridge.playableLimit(events: "0 start aplay1\n2500 end aplay1\n", fileSize: 2500, played: 2000, chunk: 1000), 2500)
        // a second stream after a finished one
        XCTAssertEqual(AudioBridge.playableLimit(events: "0 start a\n100 end a\n100 start b\n", fileSize: 150, played: 100, chunk: 1000), 100)
        // no events file: play what exists
        XCTAssertEqual(AudioBridge.playableLimit(events: nil, fileSize: 42, played: 0), 42)
    }
}
