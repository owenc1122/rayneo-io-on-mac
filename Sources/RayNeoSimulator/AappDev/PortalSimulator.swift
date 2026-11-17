import CoreGraphics
import Foundation

/// PRTL/1 (the official simulator core's private stdio protocol, simulator/src/portal_protocol.*): 28-byte
/// little-endian header `PRTL` u16 version u16 type u32 length u64 sequence u64 epoch, then the payload.
enum PortalWire {
    static let headerSize = 28
    enum Kind: UInt16 { case frame = 1, status = 2, inputResult = 3, key = 101, pointer = 102, stop = 103, resync = 104 }
    /// Wire key codes (portal_presenter.cpp keyFromWire): 1 ← 2 → 3 ↑ 4 ↓ 5 confirm 6 back 7 Home.
    enum Key: UInt8 { case left = 1, right, up, down, confirm, back, home }

    struct Message { var type: UInt16; var sequence: UInt64; var epoch: UInt64; var payload: Data }

    static func encode(_ type: Kind, sequence: UInt64, epoch: UInt64, payload: Data = Data()) -> Data {
        var out = Data("PRTL".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt16(1)); put(type.rawValue); put(UInt32(payload.count)); put(sequence); put(epoch)
        return out + payload
    }

    /// Incremental decoder; handles arbitrary pipe boundaries. Returns nil on a bad header (fail closed).
    struct Decoder {
        private var pending = Data()
        mutating func feed(_ data: Data) -> [Message]? {
            pending.append(data)
            var out: [Message] = []
            while pending.count >= headerSize {
                let p = [UInt8](pending.prefix(headerSize))
                func u(_ o: Int, _ n: Int) -> UInt64 { (0..<n).reduce(UInt64(0)) { $0 | UInt64(p[o + $1]) << (8 * $1) } }
                guard p[0] == 0x50, p[1] == 0x52, p[2] == 0x54, p[3] == 0x4c, u(4, 2) == 1 else { return nil }
                let length = Int(u(8, 4))
                guard length <= 16 * 1024 * 1024 else { return nil }
                guard pending.count >= headerSize + length else { break }
                let start = pending.startIndex
                out.append(Message(type: UInt16(u(6, 2)), sequence: u(12, 8), epoch: u(20, 8),
                                   payload: Data(pending[(start + headerSize)..<(start + headerSize + length)])))
                pending = Data(pending[(start + headerSize + length)...])
            }
            return out
        }
    }

    /// Frame payload: u16 width, u16 height, u16 format (1 = RGBA8888), u16 flags, then pixels.
    static func image(from payload: Data) -> CGImage? {
        guard payload.count >= 8 else { return nil }
        let b = [UInt8](payload.prefix(8))
        let width = Int(b[0]) | Int(b[1]) << 8, height = Int(b[2]) | Int(b[3]) << 8
        guard b[4] == 1, width > 0, height > 0, payload.count >= 8 + width * height * 4,
              let provider = CGDataProvider(data: Data(payload.dropFirst(8).prefix(width * height * 4)) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// 开发模式 display: runs the official simulator core (`lvgl_host --portal-stdio`) as a child process — it owns the
/// phone link on port 10002 (TLS, rapp-slave pairing, persistent identity) — and only shows its frames here.
@MainActor final class PortalSimulator: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var running = false
    @Published private(set) var connected = false
    @Published private(set) var appName: String?
    @Published private(set) var peer: String?
    /// `rapp-slave://…` invitation for manual connection (菜单 → 手动连接).
    @Published private(set) var invitation = ""
    @Published private(set) var lastStatus: [String: Any] = [:]
    var onLog: ((String, Bool) -> Void)?

    let width = 540, height = 220
    private var process: Process?
    private var input: FileHandle?
    private var sequence: UInt64 = 0
    private var inputGeneration: UInt64 = 0
    private var lastSummary = ""

    /// lvgl_host: `~/rapp-tools/sim/lvgl_host`, `RAPP_LVGL_HOST`, or a copy (ad-hoc signed, no sandbox
    /// entitlement) of the one inside Glasses Emulator.app kept in Application Support.
    nonisolated static func binary() -> URL? {
        let files = FileManager.default
        if let path = ProcessInfo.processInfo.environment["RAPP_LVGL_HOST"], files.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        let tools = files.homeDirectoryForCurrentUser.appendingPathComponent("rapp-tools/sim/lvgl_host")
        if files.isExecutableFile(atPath: tools.path) { return tools }
        let copy = dataDirectory.deletingLastPathComponent().appendingPathComponent("lvgl_host")
        if files.isExecutableFile(atPath: copy.path) { return copy }
        guard let source = ["/Applications/Glasses Emulator.app", files.homeDirectoryForCurrentUser.path + "/Applications/Glasses Emulator.app"]
            .lazy.compactMap({ app -> URL? in
                guard let walker = files.enumerator(atPath: app) else { return nil }
                for case let path as String in walker where (path as NSString).lastPathComponent == "lvgl_host" {
                    return URL(fileURLWithPath: app).appendingPathComponent(path)
                }
                return nil
            }).first else { return nil }
        try? files.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? files.copyItem(at: source, to: copy)) != nil else { return nil }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", copy.path]
        try? sign.run(); sign.waitUntilExit()
        return copy
    }

    /// Where lvgl_host keeps its persistent identity and pairings.
    nonisolated static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RayNeo io on Mac/simulator/data", isDirectory: true)
    }

    func start(port: UInt16 = 10002) {
        guard process == nil else { return }
        guard let binary = Self.binary() else {
            onLog?("找不到眼镜模拟器核心 lvgl_host（安装 Glasses Emulator 或放到 ~/rapp-tools/sim/lvgl_host）", true); return
        }
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = binary
        task.arguments = ["--portal-stdio", "--port", String(port), "--bind", "0.0.0.0",
                          "--proxy-data-dir", Self.dataDirectory.path, "--width", String(width), "--height", String(height)]
        let stdout = Pipe(), stdin = Pipe(), stderr = Pipe()
        task.standardOutput = stdout; task.standardInput = stdin; task.standardError = stderr
        var decoder = PortalWire.Decoder()
        let reader = DispatchQueue(label: "portal.reader")
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            reader.sync {
                guard let messages = decoder.feed(data) else {
                    handle.readabilityHandler = nil
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLog?("模拟器核心输出格式错误，已停止读取", true) } }
                    return
                }
                // Only the newest frame of a burst is decoded.
                var latestFrame: Data?, statuses: [Data] = []
                for message in messages {
                    if message.type == PortalWire.Kind.frame.rawValue { latestFrame = message.payload }
                    else if message.type == PortalWire.Kind.status.rawValue { statuses.append(message.payload) }
                }
                let image = latestFrame.flatMap(PortalWire.image(from:))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for status in statuses { self.apply(status: status) }
                        if let image { self.frame = image }
                    }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in text.split(separator: "\n") { self?.onLog?("[模拟器] \(line)", line.localizedCaseInsensitiveContains("error")) }
                }
            }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === finished else { return }
                    self.process = nil; self.input = nil; self.running = false; self.connected = false
                    self.onLog?("模拟器核心已退出（\(finished.terminationStatus)）", finished.terminationStatus != 0)
                }
            }
        }
        do {
            try task.run()
            process = task; input = stdin.fileHandleForWriting; running = true
            onLog?("模拟器核心已启动：\(binary.path)（端口 \(port)，pid \(task.processIdentifier)）", false)
        } catch {
            onLog?("模拟器核心启动失败：\(error.localizedDescription)", true)
        }
    }

    func stop() {
        guard let process else { return }
        send(.stop, payload: Data())
        try? input?.close()
        let task = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if task.isRunning { task.terminate() } }
        self.process = nil; input = nil; running = false
    }

    func sendKey(_ key: PortalWire.Key) { send(.key, payload: Data([key.rawValue])) }

    /// A tap at display coordinates (press then release).
    func sendTap(x: Double, y: Double) {
        let px = UInt16(max(0, min(Double(width - 1), x))), py = UInt16(max(0, min(Double(height - 1), y)))
        func pointer(down: Bool, tap: Bool) -> Data { Data([UInt8(px & 0xff), UInt8(px >> 8), UInt8(py & 0xff), UInt8(py >> 8), down ? 1 : 0, tap ? 1 : 0]) }
        send(.pointer, payload: pointer(down: true, tap: false))
        send(.pointer, payload: pointer(down: false, tap: true))
    }

    private func send(_ kind: PortalWire.Kind, payload: Data) {
        guard let input else { return }
        sequence += 1
        let data = PortalWire.encode(kind, sequence: sequence, epoch: inputGeneration, payload: payload)
        do { try input.write(contentsOf: data) } catch { onLog?("发送输入失败：\(error.localizedDescription)", true) }
    }

    private func apply(status payload: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
        lastStatus = json
        connected = json["connected"] as? Bool ?? false
        let name = json["appName"] as? String ?? ""
        appName = name.isEmpty ? nil : name
        let peer = json["peer"] as? String ?? ""
        self.peer = peer.isEmpty ? nil : peer
        invitation = json["pairingInvitation"] as? String ?? ""
        inputGeneration = (json["inputGeneration"] as? NSNumber)?.uint64Value ?? inputGeneration
        let summary = "眼镜模拟器：\(connected ? "已连接 \(peer)" : "等待连接")\(appName.map { " · \($0)" } ?? "")"
            + ((json["error"] as? String).flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")
        if summary != lastSummary { lastSummary = summary; onLog?(summary, false) }
    }
}
