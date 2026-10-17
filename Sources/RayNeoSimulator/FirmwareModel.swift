import AppKit
import CryptoKit
import Darwin
import Network
import SwiftUI

/// Owns the live emulator process (original firmware on Renode) and shows only frames
/// the emulated display controller actually scanned out.
@MainActor final class FirmwareModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var frame: NSImage?
    @Published private(set) var failure: String?
    @Published private(set) var status = ""
    private var process: Process?
    private var timer: Timer?
    private var lastFrame: Data?
    private var monitor: NWConnection?
    private let monitorPort: UInt16 = 23_456
    private var audio: AudioBridge?
    private var helper: Process?

    private static let firmwareKey = "firmwareDirectory"
    private static let fontsKey = "fontsDirectory"
    private static let voiceWakeKey = "voiceWakeup"

    /// 「小雷小雷」 voice wake, the RayNeo phone app's setting (PREF_AI_VOICE_WAKEUP), applied at each boot.
    @Published var voiceWakeup: Bool = UserDefaults.standard.object(forKey: "voiceWakeup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceWakeup, forKey: Self.voiceWakeKey); if running { restart() } }
    }

    /// Enrolment recordings for the HiFi4 stand-in's wake-word spotter, made once with the macOS voices.
    private var kwsDirectory: URL { dataDirectory.appendingPathComponent("kws", isDirectory: true) }
    private func prepareWakeWords(thenBoot: Bool) {
        guard let root = assetRoot else { return }
        status = "正在准备唤醒词模板（首次约一分钟）…"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [root.appendingPathComponent("scripts/make-kws-templates.sh").path, kwsDirectory.path]
        task.currentDirectoryURL = root
        task.terminationHandler = { [weak self] _ in Task { @MainActor in self?.helper = nil; if thenBoot { self?.boot() } } }
        helper = task   // keep the Process alive, otherwise its termination handler never runs
        try? task.run()
    }

    /// Folder with platform/ and scripts/: the app bundle's Resources, or the source checkout in development.
    private var assetRoot: URL? {
        let files = FileManager.default
        if let resources = Bundle.main.resourceURL,
           files.fileExists(atPath: resources.appendingPathComponent("scripts/emulate.sh").path) { return resources }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if files.fileExists(atPath: checkout.appendingPathComponent("scripts/emulate.sh").path) { return checkout }
        return nil
    }

    /// Renode: bundled copy, a per-user install, the development checkout (source build first), or /Applications.
    private func renodeExecutable() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("renode/Renode.app/Contents/MacOS/renode")) }
        candidates.append(dataDirectory.appendingPathComponent("renode/Renode.app/Contents/MacOS/renode"))
        if let root = assetRoot {
            candidates.append(root.appendingPathComponent(".local/renode-build/renode"))   // scripts/build-renode.sh
            candidates.append(root.appendingPathComponent(".local/renode/Renode.app/Contents/MacOS/renode"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Renode.app/Contents/MacOS/renode"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Writable per-user data (run logs, generated flash/NAND images). Never inside the app bundle.
    private var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RayNeo io on Mac", isDirectory: true)
    }

    var firmwareDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.firmwareKey) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("OtaFileInfo.json").path) ? url : nil
    }

    /// Asks the user for their own extracted StrixOS OTA folder. Firmware is never bundled.
    func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.title = "选择固件文件夹"
        panel.message = "选择你自己的 StrixOS 升级文件夹（包含 OtaFileInfo.json、nuttx_ap.bin 等）"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("OtaFileInfo.json").path) else {
            failure = "所选文件夹中没有 OtaFileInfo.json"; return
        }
        // Keep a private copy: later launches never need access to the user's folders
        // (Documents/Desktop/Downloads are privacy-protected and would block on a system prompt).
        let copy = dataDirectory.appendingPathComponent("firmware/\(url.lastPathComponent)", isDirectory: true)
        let files = FileManager.default
        try? files.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: copy)
        do { try files.copyItem(at: url, to: copy) } catch { failure = "复制固件失败：\(error.localizedDescription)"; return }
        UserDefaults.standard.set(copy.path, forKey: Self.firmwareKey)
        cachedStateDirectory = nil
        restart()
    }

    /// Glasses fonts (not in the OTA set): built once from the user's own RayNeo AI app plus
    /// upstream open fonts (scripts/prepare-fonts.sh) into Application Support.
    private var preparedFonts: URL { dataDirectory.appendingPathComponent("fonts", isDirectory: true) }
    private var fontsReady: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: preparedFonts.path).filter { $0.hasSuffix(".ttf") }.count) ?? 0 >= 18
    }

    /// The RayNeo AI iOS app installed on this Mac (Apple silicon), if any.
    private func installedRayNeoApp() -> URL? {
        let files = FileManager.default
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let names = try? files.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.lowercased().contains("rayneo") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                if files.fileExists(atPath: url.appendingPathComponent("Wrapper").path) || name.hasSuffix(".app") { return url }
            }
        }
        return nil
    }

    func chooseFonts() {
        let panel = NSOpenPanel()
        panel.title = "选择雷鸟 AI App"
        panel.message = "眼镜里的字体来自官方 App。请选择 RayNeo AI 的 .app（或解压后的 IPA 文件夹）"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareFonts(from: url, thenBoot: true)
    }

    private func prepareFonts(from source: URL, thenBoot: Bool) {
        guard let root = assetRoot, let venv = venvDirectory else { status = "需要先准备资源工具（固件菜单）"; return }
        status = "正在准备眼镜字体…"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [root.appendingPathComponent("scripts/prepare-fonts.sh").path, source.path, preparedFonts.path]
        task.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["RAYNEO_VENV"] = venv.path
        task.environment = environment
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                if finished.terminationStatus == 0 {
                    UserDefaults.standard.set(self.preparedFonts.path, forKey: Self.fontsKey)
                    self.status = "眼镜字体已就绪"
                    if thenBoot { self.restart() }
                } else { self.failure = "字体准备失败：请确认选择的是 RayNeo AI App" }
            }
        }
        try? FileManager.default.createDirectory(at: preparedFonts, withIntermediateDirectories: true)
        try? task.run()
    }

    /// Python venv with littlefs-python, used to build the NAND resource partitions.
    private var venvDirectory: URL? {
        var candidates = [dataDirectory.appendingPathComponent("venv")]
        if let root = assetRoot { candidates.append(root.appendingPathComponent(".local/venv")) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/python").path) }
    }

    /// One-time download of littlefs-python into Application Support (needs network, no upload).
    func installResourceTools() {
        guard let root = assetRoot else { return }
        status = "正在准备资源分区工具…"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [root.appendingPathComponent("scripts/setup-tools.sh").path, dataDirectory.appendingPathComponent("venv").path]
        task.currentDirectoryURL = root
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.status = finished.terminationStatus == 0 ? "资源分区工具已就绪，重新启动生效" : "资源分区工具安装失败"
            }
        }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? task.run()
    }

    /// Saved glasses (flash + NAND as the firmware left them), one per firmware build, so settings,
    /// pairing and files survive like on real glasses. Deleted by "恢复出厂设置".
    private var cachedStateDirectory: URL?
    private var stateDirectory: URL? {
        if let cachedStateDirectory { return cachedStateDirectory }
        guard let firmware = firmwareDirectory,
              let image = try? Data(contentsOf: firmware.appendingPathComponent("nuttx_ap.bin"), options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: image).prefix(8).map { String(format: "%02x", $0) }.joined()
        cachedStateDirectory = dataDirectory.appendingPathComponent("state/\(digest)", isDirectory: true)
        return cachedStateDirectory
    }

    /// Asks the running emulator to write its flash and NAND, then waits (bounded) for the files.
    private func saveState() {
        guard running, let state = stateDirectory else { return }
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let flash = state.appendingPathComponent("flash0.bin"), nand = state.appendingPathComponent("nand-state.bin")
        let before = [flash, nand].map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        command("pause")
        command("nor SaveImage @\(flash.path.replacingOccurrences(of: " ", with: "\\ "))")
        command("nand SaveState @\(nand.path.replacingOccurrences(of: " ", with: "\\ "))")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let after = [flash, nand].map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            if after[0] > before[0] && after[1] > before[1] { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func factoryReset() {
        stop()
        if let state = stateDirectory { try? FileManager.default.removeItem(at: state) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.boot() }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.boot() }
    }

    func boot() {
        guard process == nil else { return }
        guard let firmware = firmwareDirectory else {
            failure = "请选择固件文件夹（菜单：固件 → 选择固件文件夹…）"
            DispatchQueue.main.async { [weak self] in self?.chooseFirmware() }
            return
        }
        guard let root = assetRoot else { failure = "应用资源缺失（platform/scripts）"; return }
        if !fontsReady, UserDefaults.standard.string(forKey: Self.fontsKey) == nil, let app = installedRayNeoApp(), venvDirectory != nil {
            prepareFonts(from: app, thenBoot: true); return
        }
        if !FileManager.default.fileExists(atPath: kwsDirectory.appendingPathComponent("4").path) {
            prepareWakeWords(thenBoot: true); return
        }
        guard let renode = renodeExecutable() else {
            failure = "未找到 Renode。请把 Renode.app 放到 /Applications 或 \(dataDirectory.path)/renode/"; return
        }
        do {
            let files = FileManager.default
            let output = dataDirectory.appendingPathComponent("runs/ui-\(Int(Date().timeIntervalSince1970))")
            try files.createDirectory(at: output, withIntermediateDirectories: true)
            let log = output.appendingPathComponent("launcher.log")
            files.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.currentDirectoryURL = root
            // "0" = run until the window closes (Renode "start", monitor stays responsive).
            task.arguments = [root.appendingPathComponent("scripts/emulate.sh").path, firmware.path, "0", output.path]
            var environment = ProcessInfo.processInfo.environment
            environment["RENODE"] = renode.path
            environment["RENODE_MONITOR_PORT"] = String(monitorPort)
            if let fonts = UserDefaults.standard.string(forKey: Self.fontsKey) { environment["FONTS"] = fonts }
            if let venv = venvDirectory { environment["RAYNEO_VENV"] = venv.path }
            if let state = stateDirectory { environment["STATE"] = state.path }
            // Sound: the HiFi4 stand-in reads the Mac microphone from mic.raw and writes the speaker to speaker.raw.
            let bridge = AudioBridge(runDirectory: output)
            environment["MIC"] = bridge.micPath
            environment["MIC_LIVE"] = "1"
            environment["KWS"] = kwsDirectory.path
            environment["VOICE_WAKE"] = voiceWakeup ? "1" : "0"
            task.environment = environment
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = handle; task.standardError = handle
            task.terminationHandler = { [weak self] finished in
                try? handle.close()
                Task { @MainActor in
                    guard let self else { return }
                    self.timer?.invalidate(); self.timer = nil
                    self.monitor?.cancel(); self.monitor = nil
                    self.audio?.stop(); self.audio = nil
                    self.running = false; self.process = nil
                    if finished.terminationStatus != 0 && finished.terminationReason != .uncaughtSignal {
                        self.failure = "固件运行已中断，日志：\(output.path)"
                    }
                }
            }
            failure = nil; frame = nil; lastFrame = nil
            status = "启动中：\(firmware.lastPathComponent)"
            process = task
            try task.run()
            running = true
            bridge.wake.onKeyword = { [weak self] offset, event in
                Task { @MainActor in self?.command("hifi4 KeywordAt \(offset) \(event)") }
            }
            bridge.start(microphone: true)
            audio = bridge
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readFrame(output.appendingPathComponent("frame.pgm")) }
            }
        } catch {
            process = nil; running = false
            failure = error.localizedDescription
        }
    }

    func stop() {
        saveState()
        audio?.stop(); audio = nil
        timer?.invalidate(); timer = nil
        monitor?.cancel(); monitor = nil
        guard let process, process.isRunning else { return }
        // In app mode emulate.sh exec()s Renode, so this is the Renode process itself.
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
    }

    // MARK: input (crown key on GPIO0 P0_1, crown rotation via the OTS optical encoder)

    enum Input { case click, doubleClick, longPress, rotate(Int), press, release }

    func send(_ input: Input) {
        switch input {
        case .click: command("gpio0 Pulse 1 false 120")
        case .doubleClick: command("gpio0 Pulse 1 false 120"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.command("gpio0 Pulse 1 false 120") }
        case .longPress: command("gpio0 Pulse 1 false 1300")
        case .rotate(let steps): command("i2c0.ots Rotate \(steps * 400)")
        case .press: command("gpio0 SetInput 1 false")      // crown key held down (P0_1 active low)
        case .release: command("gpio0 SetInput 1 true")
        }
    }

    private func command(_ text: String) {
        guard running else { return }
        if monitor == nil {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: monitorPort)!, using: .tcp)
            connection.start(queue: .global())
            monitor = connection
        }
        monitor?.send(content: (text + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func readFrame(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data != lastFrame,
              let image = FirmwareFrame.decode(data) else { return }
        lastFrame = data
        status = "运行中 · 原固件画面 \(image.width)×\(image.height)"
        frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// The emulator writes a binary PGM (P5) whose bytes are the panel's grey levels
/// (two eyes side by side, 4-bit samples expanded to 0..255). Rendered green like the waveguide.
enum FirmwareFrame {
    static func decode(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        guard let first = bytes.firstIndex(of: 10), first == 2,
              Array(bytes.prefix(2)) == [80, 53],
              let second = bytes[(first + 1)...].firstIndex(of: 10),
              let third = bytes[(second + 1)...].firstIndex(of: 10),
              String(bytes: bytes[(second + 1)..<third], encoding: .ascii) == "255",
              let dimensions = String(bytes: bytes[(first + 1)..<second], encoding: .ascii) else { return nil }
        let values = dimensions.split(separator: " ").compactMap { Int($0) }
        guard values.count == 2, (1...4096).contains(values[0]), (1...4096).contains(values[1]),
              bytes.count - third - 1 == values[0] * values[1] else { return nil }
        let grey = bytes[(third + 1)...]
        var rgba = [UInt8](repeating: 255, count: values[0] * values[1] * 4)
        var i = 0
        for g in grey { rgba[i] = UInt8(UInt16(g) / 5); rgba[i + 1] = g; rgba[i + 2] = UInt8(UInt16(g) / 4); i += 4 }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: values[0], height: values[1], bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: values[0] * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
