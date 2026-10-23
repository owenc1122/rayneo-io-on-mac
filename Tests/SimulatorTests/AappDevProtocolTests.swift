import XCTest
@testable import RayNeoSimulator

final class AappDevProtocolTests: XCTestCase {
    private func pairing() -> AappDevProtocol.Pairing {
        AappDevProtocol.Pairing(host: "127.0.0.1", port: 10443, certificateSHA256: Data(repeating: 0xAB, count: 32),
                                token: AappDevProtocol.randomToken(), serverId: AappDevProtocol.randomHex(bytes: 16),
                                computer: "Mac", manifest: ["package": "com.example.hello", "version": "0.1.0+2"],
                                expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testCompactPairingMatchesDevToolsRules() throws {
        let p = pairing()
        XCTAssertEqual(p.problems, [])
        let text = p.compact
        XCTAssertLessThanOrEqual(text.count, 512)
        let components = try XCTUnwrap(URLComponents(string: text))
        XCTAssertEqual(components.scheme, "aapp-dev"); XCTAssertEqual(components.host, "pair")
        let q = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["v"], "3")
        XCTAssertEqual(q["e"], "127.0.0.1:10443")
        XCTAssertNotNil(q["f"]?.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
        XCTAssertNotNil(q["t"]?.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
    }

    func testFullTicketDecodesToMatchingIdentity() throws {
        let p = pairing()
        let data = try XCTUnwrap(p.full.components(separatedBy: "data=").last)
        var b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: b64))) as? [String: Any])
        XCTAssertEqual(json["v"] as? Int, 3)
        XCTAssertEqual(json["endpoint"] as? String, "https://127.0.0.1:10443/dev")
        XCTAssertEqual(json["fingerprint"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(json["token"] as? String, p.token)
        XCTAssertEqual(json["serverId"] as? String, p.serverId)
        XCTAssertEqual((json["manifest"] as? [String: Any])?["package"] as? String, "com.example.hello")
        XCTAssertEqual(json["expiresAt"] as? Int, 2_000_000_000_000)
    }

    func testPairingProblems() {
        var p = pairing(); p.host = "localhost"
        XCTAssertFalse(p.problems.isEmpty)
        p = pairing(); p.manifest = [:]
        XCTAssertFalse(p.problems.isEmpty)
    }

    func testRangeParsing() {
        XCTAssertEqual(AappDevProtocol.parseRange("bytes=0-16383", size: 20_000), 0...16383)
        XCTAssertEqual(AappDevProtocol.parseRange("bytes=16384-19999", size: 20_000), 16384...19999)
        XCTAssertEqual(AappDevProtocol.parseRange("bytes=16384-", size: 20_000), 16384...19999)
        XCTAssertEqual(AappDevProtocol.parseRange("bytes=19000-99999", size: 20_000), 19000...19999)
        XCTAssertNil(AappDevProtocol.parseRange("bytes=20000-20001", size: 20_000))
        XCTAssertNil(AappDevProtocol.parseRange("bytes=5-1", size: 20_000))
        XCTAssertNil(AappDevProtocol.parseRange("bytes=0-1,4-5", size: 20_000))
        XCTAssertNil(AappDevProtocol.parseRange("items=0-1", size: 20_000))
        XCTAssertNil(AappDevProtocol.parseRange(nil, size: 20_000))
    }

    func testDeploymentEventFields() {
        let d = AappDevProtocol.Deployment(deploymentId: "d1", buildId: "b1", appId: "com.example.hello", version: "1",
                                           sha256: String(repeating: "0", count: 64), bytes: 10, transferId: 7, generation: 3)
        let e = d.event
        XCTAssertEqual(e["type"] as? String, "deploy.begin")
        for key in ["deploymentId", "buildId", "appId", "version", "sha256", "bytes", "transferId", "generation"] { XCTAssertNotNil(e[key], key) }
    }

    func testSSEFrameIsOneDataLine() throws {
        let frame = String(decoding: AappDevProtocol.sseFrame(seq: 5, payload: ["type": "welcome", "text": "a\nb"]), as: UTF8.self)
        XCTAssertTrue(frame.hasPrefix("id: 5\ndata: {"))
        XCTAssertTrue(frame.hasSuffix("}\n\n"))
        let dataLine = try XCTUnwrap(frame.split(separator: "\n").first { $0.hasPrefix("data: ") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dataLine.dropFirst(6).utf8)) as? [String: Any])
        XCTAssertEqual(json["seq"] as? Int, 5)
        XCTAssertEqual(json["text"] as? String, "a\nb")
    }

    func testTelemetryFormatting() {
        let logs = AappDevProtocol.describeTelemetry(["type": "logs", "dropped": 2, "entries": [
            ["type": "log", "appId": "a", "buildId": "b1", "message": "hi"],
            ["type": "runtime.error", "appId": "a", "message": "boom"]]])
        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs[0].0, "日志 · a#b1 · hi"); XCTAssertFalse(logs[0].1)
        XCTAssertTrue(logs[1].1); XCTAssertTrue(logs[2].1)
        let status = AappDevProtocol.describeTelemetry(["type": "deploy.status", "buildId": "b1", "phase": "running", "firstFrame": "submitted"])
        XCTAssertEqual(status.first?.0, "部署 b1：运行中（首帧已发出）")
        XCTAssertTrue(AappDevProtocol.describeTelemetry(["type": "deploy.result", "ok": false, "phase": "failed"]).first!.1)
        XCTAssertFalse(AappDevProtocol.describeTelemetry(["type": "whatever"]).isEmpty)
    }

    func testRequestParserContentLengthChunkedAndLimits() {
        var parser = AappDevRequestParser()
        parser.append(Data("POST /dev/device-connections/x/telemetry?after=3 HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}".utf8))
        parser.append(Data("GET /dev/a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n".utf8))
        guard case .request(let first) = parser.next() else { return XCTFail("first") }
        XCTAssertEqual(first.method, "POST"); XCTAssertEqual(first.path, "/dev/device-connections/x/telemetry")
        XCTAssertEqual(first.query["after"], "3"); XCTAssertEqual(first.bearer, "abc"); XCTAssertEqual(first.body, Data("{}".utf8))
        guard case .request(let second) = parser.next() else { return XCTFail("second") }
        XCTAssertEqual(second.body, Data("abc".utf8))
        guard case .needMore = parser.next() else { return XCTFail("empty") }

        var big = AappDevRequestParser()
        big.append(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8))
        guard case .failure(413, _) = big.next() else { return XCTFail("413") }
        var junk = AappDevRequestParser()
        junk.append(Data("GARBAGE\r\n\r\n".utf8))
        guard case .failure(400, _) = junk.next() else { return XCTFail("400") }
        var huge = AappDevRequestParser()
        huge.append(Data(repeating: 65, count: AappDevRequestParser.maxHead + 10))
        guard case .failure(431, _) = huge.next() else { return XCTFail("431") }
    }

    func testRequestParserNeverCrashesOnRandomInput() {
        var generator = SystemRandomNumberGenerator()
        let seeds = ["POST /dev/x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello", "GET /dev/y?after=1 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"]
        for _ in 0..<5_000 {
            var bytes = [UInt8](seeds.randomElement(using: &generator)!.utf8)
            for _ in 0..<Int.random(in: 0...6, using: &generator) where !bytes.isEmpty {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if Bool.random(using: &generator) { bytes += (0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) } }
            var parser = AappDevRequestParser()
            parser.append(Data(bytes))
            for _ in 0..<4 { if case .needMore = parser.next() { break } }
        }
    }

    func testAapkManifestReader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aapk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"package":"com.example.t","version":"1.2.3","name":"T"}"#.utf8).write(to: dir.appendingPathComponent("aapp.json"))
        try Data(repeating: 120, count: 5000).write(to: dir.appendingPathComponent("main.js"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-9", "app.aapk", "aapp.json", "main.js"]
        try zip.run(); zip.waitUntilExit()
        let manifest = try AapkReader.manifest(of: dir.appendingPathComponent("app.aapk"))
        XCTAssertEqual(manifest["package"] as? String, "com.example.t")
        XCTAssertEqual(try AapkReader.entry("main.js", in: dir.appendingPathComponent("app.aapk")).count, 5000)
        XCTAssertThrowsError(try AapkReader.entry("missing.txt", in: dir.appendingPathComponent("app.aapk")))
        XCTAssertThrowsError(try AapkReader.entry("aapp.json", inZip: Data("not a zip at all, definitely not".utf8)))
    }
}
