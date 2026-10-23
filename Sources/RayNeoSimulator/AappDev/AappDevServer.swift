import CoreImage
import Foundation

/// Developer server for the RayNeo Aapp DevTools 「扫码连接电脑」 flow (`aapp-dev.v3`, what `aapp dev` serves):
/// pair a phone once, then every .aapk you choose (or every new build in a watched project) is downloaded,
/// verified, installed and run on the phone's Host automatically, with its logs streamed back.
/// The phone reaches this Mac at 127.0.0.1 over `adb reverse tcp:<port> tcp:<port>` (or the Mac's LAN IPv4).
@MainActor final class AappDevServer: ObservableObject {
    nonisolated static let defaultPort: UInt16 = 10_443

    @Published private(set) var paired = false
    @Published private(set) var deviceName: String?
    @Published private(set) var status = "开发服务未启动"
    @Published private(set) var lastDeploy: String?
    /// Dev-link events and the app's own log entries, ready for a console: (line, isError).
    var onLog: ((String, Bool) -> Void)?

    let port: UInt16
    private let core: AappDevCore
    private var started = false

    init(port: UInt16 = AappDevServer.defaultPort) {
        self.port = port
        core = AappDevCore(port: port)
        core.emit = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
    }

    private func handle(_ event: AappDevCore.Event) {
        switch event {
        case .log(let line, let isError): onLog?(line, isError)
        case .state(let paired, let device, let status):
            self.paired = paired; self.deviceName = device; self.status = status
        case .deployed(let text): lastDeploy = text
        }
    }

    /// Starts the HTTPS + SSE listener (creating the TLS identity on first use). Idempotent.
    func start() throws {
        guard !started else { return }
        try core.start()
        started = true
    }

    func stop() {
        guard started else { return }
        core.stop()
        started = false
    }

    /// Pairing text for a phone reaching this Mac over `adb reverse` (127.0.0.1). Empty until an app is chosen
    /// (the pairing names the app). Paste it in DevTools → 「无法扫码？粘贴配对信息」, or show it as a QR code.
    var pairingText: String { pairingText(host: "127.0.0.1") }

    /// Pairing text for a phone on the same network (`host` = this Mac's IPv4 address).
    func pairingText(host: String) -> String { core.pairing(host: host)?.compact ?? "" }

    /// QR code of `pairingText` (or of the text for `host`), for DevTools → 扫码连接电脑.
    func pairingQRCode(host: String = "127.0.0.1") -> CGImage? {
        let text = pairingText(host: host)
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }

    /// Installs and runs `aapk` on the paired phone (or as soon as one pairs).
    func deploy(aapk: URL) { core.deploy(aapk) }

    /// Save-to-reload: deploys the newest `build/*.aapk` of the project now and on every change.
    func watch(projectDirectory: URL) { core.watch(projectDirectory) }

    func stopApp() { core.command("app.stop") }
    func restartApp() { core.command("app.restart") }
}
