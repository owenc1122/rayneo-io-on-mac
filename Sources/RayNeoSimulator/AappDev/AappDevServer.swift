import CoreImage
import Foundation

/// Developer server for the rApp DevTools (`rapp-dev.v3`, what `rapp dev` serves) with one-click connect: the
/// phone finds this Mac (Bonjour `_rapp-dev._tcp` or 127.0.0.1 over USB), asks to pair, the developer compares the
/// 6-digit code and allows it once; after that every build of the open project is installed and run on the phone's
/// Host automatically, with its logs streamed back. The phone reaches this Mac at 127.0.0.1 over
/// `adb reverse tcp:<port> tcp:<port>` / the iPhone USB bridge, or at the Mac's LAN address.
@MainActor final class AappDevServer: ObservableObject {
    nonisolated static let defaultPort: UInt16 = 17_890

    @Published private(set) var paired = false
    @Published private(set) var deviceName: String?
    @Published private(set) var status = "开发服务未启动"
    @Published private(set) var lastDeploy: String?
    /// Phone waiting for the developer to allow it (shown as a sheet with the comparison code).
    @Published private(set) var pendingRequest: (id: String, deviceName: String, code: String)?
    /// The connected phone reaches this Mac over USB.
    @Published private(set) var wired = false
    /// Building the open project right now.
    @Published private(set) var building = false
    @Published private(set) var buildFailed = false
    private var builder: RappProjectBuilder?
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
        case .pairingRequest(let id, let name, let code): pendingRequest = (id, name, code)
        case .pairingResolved(let id): if pendingRequest?.id == id { pendingRequest = nil }
        case .connection(_, let wired): self.wired = wired
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

    /// Allow / refuse the pending pairing request.
    func resolvePending(approve: Bool) {
        guard let request = pendingRequest else { return }
        core.resolve(request: request.id, approve: approve)
        pendingRequest = nil
    }

    /// 开发模式: builds the project now and whenever its sources change (`npm run build` / `npx --no-install rapp
    /// build`), and deploys every new `build/*.rpk`.
    func open(project: URL) {
        builder?.stop()
        let builder = RappProjectBuilder(project: project)
        builder.onLog = { [weak self] line, isError in self?.onLog?(line, isError) }
        builder.onState = { [weak self] building, failed in self?.building = building; self?.buildFailed = failed }
        self.builder = builder
        core.watch(project)
        builder.start()
    }

    var projectName: String? { builder?.project.lastPathComponent }

    func stopApp() { core.command("app.stop") }
    func restartApp() { core.command("app.restart") }
}
