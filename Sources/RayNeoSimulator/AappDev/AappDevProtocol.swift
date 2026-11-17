import Compression
import CryptoKit
import Foundation

/// The computer side of the RayNeo rApp developer link `rapp-dev.v3` (what `rapp dev` serves), as the Host's
/// DevTools app (com.rayneo.aapp.devtools) and runtime (dev_protocol.dart) expect it. Pure values and
/// formatting only; no I/O, so it is unit-testable.
enum AappDevProtocol {
    static let version = "rapp-dev.v3"
    /// DevTools downloads packages in 16 KiB ranges and requires a 206 with exactly that many bytes.
    static let rangeBytes = 16 * 1024
    /// AappPackageManager.maxPackageBytes on the Host.
    static let maxPackageBytes = 100 * 1024 * 1024
    /// Largest JSON body we accept from the phone (the Host bounds dev messages to 1 MiB).
    static let maxRequestBody = 1024 * 1024 + 4096

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64url(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    static func randomHex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return hex(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    /// One pairing (QR / pasted text). The compact form is what DevTools scans; it resolves the full ticket
    /// with `POST /dev/pairing/describe` (Bearer token) over the certificate-pinned TLS link.
    struct Pairing: Equatable {
        var host: String               // literal IPv4 (127.0.0.1 over adb reverse, or the Mac's LAN address)
        var port: UInt16
        var certificateSHA256: Data    // SHA-256 of the server certificate's DER
        var token: String              // 43 chars [A-Za-z0-9_-]
        var serverId: String           // 32 hex
        var computer: String
        var manifest: [String: Any]
        var expiresAt: Date

        static func == (a: Pairing, b: Pairing) -> Bool {
            a.host == b.host && a.port == b.port && a.certificateSHA256 == b.certificateSHA256 && a.token == b.token
                && a.serverId == b.serverId && a.computer == b.computer && a.expiresAt == b.expiresAt
                && NSDictionary(dictionary: a.manifest).isEqual(to: b.manifest)
        }

        var endpoint: String { "https://\(host):\(port)/dev" }

        /// `rapp-dev://pair?v=3&e=<IPv4>:<port>&f=<base64url sha256>&t=<token>` (≤ 512 chars).
        var compact: String { "rapp-dev://pair?v=3&e=\(host):\(port)&f=\(base64url(certificateSHA256))&t=\(token)" }

        /// `rapp-dev://pair?data=<base64url(JSON)>`: the ticket returned by describe (also accepted directly).
        var full: String {
            let json: [String: Any] = [
                "v": 3,
                "endpoint": endpoint,
                "fingerprint": hex(certificateSHA256),
                "serverId": serverId,
                "token": token,
                "computer": String(computer.prefix(128)),
                "manifest": manifest,
                "expiresAt": Int64(expiresAt.timeIntervalSince1970 * 1000),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
            return "rapp-dev://pair?data=\(base64url(data))"
        }

        /// Problems DevTools would reject the pairing for (empty = acceptable).
        var problems: [String] {
            var out: [String] = []
            let octets = host.split(separator: ".")
            if octets.count != 4 || !octets.allSatisfy({ UInt8($0) != nil }) { out.append("地址必须是 IPv4") }
            if token.count != 43 || !token.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }) { out.append("令牌格式不对") }
            if certificateSHA256.count != 32 { out.append("证书指纹不对") }
            if serverId.count != 32 || !serverId.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { out.append("serverId 不对") }
            if manifest["package"] as? String == nil { out.append("应用清单缺少 package") }
            if compact.count > 512 { out.append("配对文本过长") }
            return out
        }
    }

    /// The `deploy.begin` SSE event for one package build.
    struct Deployment: Equatable {
        var deploymentId: String       // ≤ 80
        var buildId: String            // ≤ 80
        var appId: String              // = the paired app (manifest package)
        var version: String
        var sha256: String             // 64 lowercase hex
        var bytes: Int
        var transferId: UInt32         // 1 ... 2^32-1
        var generation: Int            // ≥ 1, never below the previous one

        var event: [String: Any] {
            ["type": "deploy.begin", "deploymentId": deploymentId, "buildId": buildId, "appId": appId,
             "version": version, "sha256": sha256, "bytes": bytes, "transferId": Int(transferId), "generation": generation]
        }
    }

    /// `bytes=a-b` → the closed range, validated against the package size.
    static func parseRange(_ header: String?, size: Int) -> ClosedRange<Int>? {
        guard let header = header?.trimmingCharacters(in: .whitespaces).lowercased(), header.hasPrefix("bytes="),
              !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : Int(parts[1]) ?? -1
        guard end >= start else { return nil }
        let clamped = min(end, size - 1, start + rangeBytes * 4 - 1)
        return start...clamped
    }

    /// Phone → computer telemetry rendered for the developer console. Returns (line, isError) pairs.
    static func describeTelemetry(_ message: [String: Any]) -> [(String, Bool)] {
        let type = message["type"] as? String ?? "?"
        switch type {
        case "logs":
            var lines: [(String, Bool)] = []
            for entry in (message["entries"] as? [[String: Any]] ?? []).prefix(200) {
                let kind = entry["type"] as? String ?? "log"
                let text = String((entry["message"] as? String ?? "").prefix(1536))
                let app = entry["appId"] as? String ?? ""
                let build = entry["buildId"] as? String
                let prefix = kind == "runtime.error" ? "运行错误" : "日志"
                lines.append(("\(prefix) · \(app)\(build.map { "#\($0)" } ?? "") · \(text)", kind == "runtime.error"))
            }
            if let dropped = message["dropped"] as? Int, dropped > 0 { lines.append(("手机端丢弃了 \(dropped) 条日志（缓冲已满）", true)) }
            return lines
        case "deploy.status":
            let phase = message["phase"] as? String ?? "?"
            var line = "部署 \(message["buildId"] as? String ?? "")：\(phaseName(phase))"
            if message["firstFrame"] as? String == "submitted" { line += "（首帧已发出）" }
            if let text = message["message"] as? String { line += " · \(text)" }
            return [(line, phase == "failed" || phase == "rolled_back")]
        case "deploy.result":
            let ok = message["ok"] as? Bool ?? false
            let phase = message["phase"] as? String ?? (ok ? "running" : "failed")
            var line = "部署结果 \(message["buildId"] as? String ?? "")：\(ok ? "成功" : "失败") · \(phaseName(phase))"
            if let text = message["message"] as? String { line += " · \(text)" }
            return [(line, !ok)]
        case "session.status":
            let automatic = message["automatic"] as? Bool
            var line = "手机已就绪"
            if automatic == false { line += " · 自动部署已暂停（在手机开发工具里打开）" }
            if let error = message["installedError"] as? String { return [(line, false), ("已安装版本有问题：\(error)", true)] }
            return [(line, false)]
        case "command.result":
            let ok = message["ok"] as? Bool ?? false
            var line = "命令 \(message["requestId"] as? String ?? "")：\(ok ? "完成" : "失败")"
            if let code = message["code"] as? String { line += " · \(code)" }
            if let text = message["message"] as? String { line += " · \(text)" }
            return [(line, !ok)]
        case "host.display":
            let display = message["display"] as? [String: Any] ?? [:]
            let target = display["target"] as? String ?? "?"
            let connected = display["connected"] as? Bool ?? false
            return [("眼镜画面：\(target == "simulator" ? "电脑模拟器" : target == "glasses" ? "真眼镜" : target) · \(connected ? "已连接" : "未连接")", false)]
        case "host.automatic":
            return [((message["enabled"] as? Bool ?? true) ? "手机恢复自动部署" : "手机暂停了自动部署", false)]
        default:
            return [("手机消息：\(type)", false)]
        }
    }

    static func phaseName(_ phase: String) -> String {
        [
            "verifying": "校验中", "prepared": "已校验", "staged": "已暂存", "waitingForTarget": "等待显示设备",
            "awaitingPermission": "等待手机上确认权限", "switching": "切换中", "installed": "已安装",
            "runtime_started": "运行时已启动", "running": "运行中", "unchanged": "未变化（同一版本）",
            "rolled_back": "已回滚", "failed": "失败", "cancelled": "已取消",
        ][phase] ?? phase
    }

    /// One SSE frame. `data:` must be a single line (JSON has no raw newlines once serialised).
    static func sseFrame(seq: Int, payload: [String: Any]) -> Data {
        var body = payload
        body["seq"] = seq
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Data("id: \(seq)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func errorBody(_ message: String) -> Data { json(["error": ["message": message]]) }

    /// The 6-digit comparison code both sides show while a phone asks to pair (ONE_CLICK_PROTOCOL §3):
    /// sha256(fingerprint ‖ utf8(deviceId) ‖ nonce), first 4 bytes big-endian mod 1 000 000, zero-padded.
    static func pairingCode(fingerprint: Data, deviceId: String, nonce: Data) -> String {
        let digest = Array(SHA256.hash(data: fingerprint + Data(deviceId.utf8) + nonce))
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }

    /// base64url (no padding) → bytes.
    static func base64urlDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// The manifest's version as text: rApp manifests carry `{"name": "1.0.0", "build": 3}`, older ones a string.
    static func versionText(_ manifest: [String: Any]) -> String? {
        if let text = manifest["version"] as? String { return text }
        guard let version = manifest["version"] as? [String: Any] else { return nil }
        let name = version["name"] as? String ?? ""
        let build = (version["build"] as? NSNumber).map { "+\($0)" } ?? ""
        return name.isEmpty ? nil : name + build
    }
}

/// Minimal reader for one file of an .aapk (zip, stored or deflated): used to read aapp.json.
enum AapkReader {
    enum Failure: Error, LocalizedError {
        case notZip, missing(String), unsupported, tooLarge
        var errorDescription: String? {
            switch self {
            case .notZip: return "不是有效的应用包（zip）"
            case .missing(let name): return "应用包里没有 \(name)"
            case .unsupported: return "应用包使用了不支持的压缩方式"
            case .tooLarge: return "应用包超过 100 MB"
            }
        }
    }

    /// The package manifest: `manifest.json` in an .rpk (rApp), `aapp.json` in an older .aapk.
    static func manifest(of url: URL) throws -> [String: Any] {
        let name = url.pathExtension == "aapk" ? "aapp.json" : "manifest.json"
        let data = try entry(name, in: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.missing(name) }
        return object
    }

    static func entry(_ name: String, in url: URL) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= AappDevProtocol.maxPackageBytes else { throw Failure.tooLarge }
        let zip = try Data(contentsOf: url, options: .mappedIfSafe)
        return try entry(name, inZip: zip)
    }

    static func entry(_ name: String, inZip zip: Data) throws -> Data {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < bytes.count ? u16(o) | u16(o + 2) << 16 : 0 }
        // End of central directory: last 22..65557 bytes.
        guard bytes.count >= 22 else { throw Failure.notZip }
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        let count = u16(eocd + 10), directory = u32(eocd + 16)
        var p = directory
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { throw Failure.notZip }
            let method = u16(p + 10), compressed = u32(p + 20), uncompressed = u32(p + 24)
            let nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLength <= bytes.count else { throw Failure.notZip }
            let entryName = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            if entryName == name {
                guard local + 30 <= bytes.count, u32(local) == 0x0403_4b50, uncompressed <= 16 * 1024 * 1024 else { throw Failure.notZip }
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                guard start + compressed <= bytes.count else { throw Failure.notZip }
                let payload = Data(bytes[start..<(start + compressed)])
                switch method {
                case 0: return payload
                case 8: return try inflate(payload, expected: uncompressed)
                default: throw Failure.unsupported
                }
            }
            p += 46 + nameLength + extra + comment
        }
        throw Failure.missing(name)
    }

    private static func inflate(_ data: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw Failure.unsupported }
        return output
    }
}

