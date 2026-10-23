import CoreGraphics
import Foundation
import Network

/// TCP server the Aapp Host connects to (DevTool → 显示设备 → 电脑模拟器), same port and protocol as the official
/// RTOS Simulator. One Host at a time: a new connection replaces the old one (a phone that reconnects after a
/// network drop must not wait for the stale socket to time out). Everything runs on `queue`.
final class AappServer {
    struct Callbacks {
        var log: (String) -> Void = { _ in }
        var frame: (CGImage?) -> Void = { _ in }
        var connection: (_ connected: Bool, _ peer: String?) -> Void = { _, _ in }
        var app: (_ name: String?, _ mode: String?) -> Void = { _, _ in }
    }

    let queue = DispatchQueue(label: "cool.spare.rayneo.aapp-server")
    let width: Int, height: Int
    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: AappSession?
    private var framer = AappFramer()
    private var idleTimer: DispatchSourceTimer?
    private var lastPacket = Date()
    private var callbacks: Callbacks
    /// The Host pings every 5 s; the official simulator drops a client after 20 s without a complete packet.
    static let idleTimeout: TimeInterval = 20

    init(width: Int = 540, height: Int = 220, callbacks: Callbacks) {
        self.width = width; self.height = height; self.callbacks = callbacks
    }

    /// Port actually bound (useful with port 0 in tests), once the listener is ready.
    private(set) var boundPort: UInt16?

    func start(port: UInt16, ready: ((Result<UInt16, Error>) -> Void)? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.boundPort = listener.port?.rawValue
                self.callbacks.log("Aapp 显示服务已启动，端口 \(listener.port?.rawValue ?? port)（手机 Host：DevTool → 显示设备 → 电脑模拟器）")
                ready?(.success(listener.port?.rawValue ?? port))
            case .failed(let error):
                self.callbacks.log("✗ Aapp 显示服务启动失败（端口 \(port)）：\(error)。官方 RTOS Simulator 是否也在用这个端口？")
                ready?(.failure(error))
                listener.cancel()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.connection != nil, Date().timeIntervalSince(self.lastPacket) > Self.idleTimeout else { return }
            self.drop(reason: "\(Int(Self.idleTimeout)) 秒没有收到完整数据包")
        }
        timer.resume()
        idleTimer = timer
    }

    func stop() {
        queue.async { [self] in
            idleTimer?.cancel(); idleTimer = nil
            drop(reason: "模拟器停止")
            listener?.cancel(); listener = nil
        }
    }

    private func peerName(_ c: NWConnection) -> String {
        if case .hostPort(let host, let port) = c.endpoint { return "\(host):\(port)" }
        return "\(c.endpoint)"
    }

    private func accept(_ new: NWConnection) {
        if connection != nil { drop(reason: "新的 Host 连接 \(peerName(new)) 取代旧连接") }
        connection = new
        framer = AappFramer()
        lastPacket = Date()
        let session = AappSession(width: width, height: height)
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .log(let s): self.callbacks.log(s)
            case .hello: break
            case .opened(let name, _, let mode): self.callbacks.app(name, mode)
            case .closed: self.callbacks.app(nil, nil)
            }
        }
        self.session = session
        let peer = peerName(new)
        capture = Self.captureDirectory.flatMap { AappCapture(directory: $0, peer: peer) }
        if let capture { callbacks.log("抓包写入 \(capture.path)") }
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new, self.connection === new else { return }
            switch state {
            case .ready:
                self.callbacks.log("Host 已连接：\(peer)")
                self.callbacks.connection(true, peer)
                self.receive(on: new)
            case .failed(let error): self.drop(reason: "连接出错：\(error)")
            case .cancelled: self.drop(reason: nil)
            default: break
            }
        }
        new.start(queue: queue)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak c] data, _, done, error in
            guard let self, let c, self.connection === c else { return }
            if let data, !data.isEmpty {
                self.framer.append(data)
                do {
                    while let packet = try self.framer.next() {
                        self.lastPacket = Date()
                        self.process(packet)
                        guard self.connection === c else { return }
                    }
                } catch {
                    self.drop(reason: "协议错误：\(error)"); return
                }
            }
            if done { self.drop(reason: "Host 断开连接"); return }
            if let error { self.drop(reason: "接收出错：\(error)"); return }
            self.receive(on: c)
        }
    }

    private func process(_ packet: AappPacket) {
        guard let session else { return }
        capture?.write(0, packet.encoded())
        apply(session.handle(packet))
    }

    private func apply(_ out: AappSession.Output) {
        if let frame = out.frame { callbacks.frame(frame) }
        guard let c = connection else { return }
        for reply in out.replies {
            let bytes = reply.encoded()
            capture?.write(1, bytes)
            c.send(content: bytes, completion: .contentProcessed { _ in })
        }
        if out.closeConnection { drop(reason: "会话结束") }
    }

    // MARK: packet capture (developer diagnostics, off by default)

    /// Raw packet log per connection: env AAPP_CAPTURE=<dir> or UserDefaults "aappCaptureDirectory".
    /// Records: u8 direction (0 Host→simulator, 1 simulator→Host), u64 µs since connect, u32 length, packet bytes
    /// (same format as the research proxy, split with aapp_wire.parse_stream).
    private var capture: AappCapture?

    static var captureDirectory: String? {
        if let env = ProcessInfo.processInfo.environment["AAPP_CAPTURE"], !env.isEmpty { return env }
        if let path = UserDefaults.standard.string(forKey: "aappCaptureDirectory"), !path.isEmpty { return path }
        return nil
    }

    private func drop(reason: String?) {
        guard let c = connection else { return }
        connection = nil
        c.stateUpdateHandler = nil
        c.cancel()
        session = nil
        framer = AappFramer()
        capture?.close(); capture = nil
        if let reason { callbacks.log("Host 已断开：\(reason)") }
        callbacks.connection(false, nil)
        callbacks.app(nil, nil)
        callbacks.frame(nil)
    }

    // MARK: input from the window (any thread)

    func key(_ key: AappKey) {
        queue.async { [self] in
            guard let session else { callbacks.log("按键忽略：手机 Host 未连接"); return }
            apply(session.key(key))
        }
    }

    func tap(x: Double, y: Double) {
        queue.async { [self] in
            guard let session else { return }
            apply(session.tap(x: x, y: y))
        }
    }
}

/// Append-only capture file of one connection (see AappServer.captureDirectory). Capped at 256 MiB.
final class AappCapture {
    let path: String
    private let handle: FileHandle
    private let start = DispatchTime.now().uptimeNanoseconds
    private var written = 0
    static let maxBytes = 256 << 20

    init?(directory: String, peer: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let safePeer = peer.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = (directory as NSString).appendingPathComponent("aapp-\(stamp)-\(safePeer).bin")
        guard FileManager.default.createFile(atPath: path, contents: nil), let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
    }

    func write(_ direction: UInt8, _ bytes: Data) {
        guard written < Self.maxBytes else { return }
        var w = AappWriter()
        w.u8(direction); w.u64((DispatchTime.now().uptimeNanoseconds - start) / 1000); w.u32(UInt32(bytes.count)); w.bytes(bytes)
        handle.write(w.data)
        written += w.data.count
    }

    func close() { try? handle.close() }
}
