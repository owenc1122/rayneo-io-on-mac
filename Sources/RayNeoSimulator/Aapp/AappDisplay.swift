import CoreGraphics
import Foundation

/// Lets the RayNeo Aapp Host (phone app, DevTool → 显示设备 → 电脑模拟器) use this simulator as its display,
/// like the official RTOS Simulator: same port (10002) and protocol. Apps render into `frame`; keys and taps
/// from the window go back to the Host. Main-actor facade over `AappServer` (which runs on its own queue).
@MainActor final class AappDisplay: ObservableObject {
    /// Latest rendered Aapp frame (display size), nil when no app is shown.
    @Published private(set) var frame: CGImage?
    @Published private(set) var connected = false
    /// One-line state for the status bar, e.g. "已连接 127.0.0.1:52144 · 倒计时（普通）".
    @Published private(set) var sessionInfo = "未启动"
    /// Name of the Aapp currently open on the Host, nil when none.
    @Published private(set) var appName: String?
    /// "drawFrame" (普通) or "micro" (流畅) for the open app.
    @Published private(set) var renderMode: String?
    @Published private(set) var port: UInt16?

    /// Developer log lines (connections, app open/close, frame statistics, protocol errors), on the main actor.
    var onLog: ((String) -> Void)?

    let width: Int, height: Int
    private var server: AappServer?
    private var peer: String?

    init(width: Int = 540, height: Int = 220) { self.width = width; self.height = height }

    /// Starts listening (0.0.0.0, all interfaces). Throws if the port number is invalid; a port already in use
    /// (e.g. the official simulator is running) is reported through `onLog` and `sessionInfo`.
    func start(port: UInt16 = 10002) throws {
        stop()
        let callbacks = AappServer.Callbacks(
            log: { [weak self] line in DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLog?(line) } } },
            frame: { [weak self] image in DispatchQueue.main.async { MainActor.assumeIsolated { self?.frame = image } } },
            connection: { [weak self] connected, peer in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connected = connected; self?.peer = peer; self?.refreshInfo() } }
            },
            app: { [weak self] name, mode in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.appName = name; self?.renderMode = mode; self?.refreshInfo() } }
            })
        let server = AappServer(width: width, height: height, callbacks: callbacks)
        try server.start(port: port) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let bound): self.port = bound; self.sessionInfo = "等待手机 Host 连接（端口 \(bound)）"
                    case .failure: self.port = nil; self.sessionInfo = "端口 \(port) 被占用"
                    }
                }
            }
        }
        self.server = server
        sessionInfo = "启动中…"
    }

    func stop() {
        server?.stop(); server = nil
        connected = false; appName = nil; renderMode = nil; frame = nil; port = nil; peer = nil
        sessionInfo = "未启动"
    }

    func sendKey(_ key: AappKey) { server?.key(key) }

    /// A tap at display coordinates (0…width, 0…height).
    func sendTap(x: Double, y: Double) { server?.tap(x: x, y: y) }

    private func refreshInfo() {
        guard server != nil else { sessionInfo = "未启动"; return }
        guard connected else { sessionInfo = "等待手机 Host 连接（端口 \(port.map(String.init) ?? "?")）"; return }
        var info = "已连接 \(peer ?? "Host")"
        if let appName { info += " · \(appName)（\(renderMode == "micro" ? "流畅" : "普通")）" }
        sessionInfo = info
    }
}
