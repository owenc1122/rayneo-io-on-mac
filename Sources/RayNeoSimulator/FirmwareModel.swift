import AppKit
import CryptoKit
import Darwin
import Network
import SwiftUI
import UniformTypeIdentifiers

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
    /// Developer log console (firmware trace + emulator + app events).
    let console = LogConsole()
    /// Aapp display link (port 10002): the RayNeo Aapp Host on a phone draws SDK apps on this simulator.
    let aapp = AappDisplay()
    /// rapp-dev.v3 server (port 17890): the phone's DevTools pairs with it (one-click connect) and installs/runs/reloads builds.
    let dev = AappDevServer()
    @Published var showPairing = false

    /// Starts the Aapp display server once (the official Aapp Simulator must not be holding the port).
    func startAapp() {
        guard aapp.port == nil else { return }
        aapp.onLog = { [weak self] text in self?.console.append(.aapp, text.contains("错误") || text.contains("失败") || text.contains("占用") ? .warning : .info, text) }
        do { try aapp.start(port: 10002) } catch { console.append(.aapp, .error, "Aapp 显示端口启动失败：\(error.localizedDescription)") }
        dev.onLog = { [weak self] text, isError in self?.console.append(.aapp, isError ? .error : .info, text) }
        do { try dev.start() } catch { console.append(.aapp, .error, "开发服务启动失败：\(error.localizedDescription)") }
    }

    /// 安装并运行: deploys the .aapk to the paired phone; asks for pairing first when no phone is paired.
    func runAapk() {
        let panel = NSOpenPanel()
        panel.title = "选择要安装运行的 Aapp 应用（.aapk）"
        panel.allowedContentTypes = [UTType(filenameExtension: "aapk") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dev.deploy(aapk: url)
        console.append(.aapp, .info, "安装并运行：\(url.lastPathComponent)")
        if !dev.paired { showPairing = true }
    }

    func watchProject() {
        let panel = NSOpenPanel()
        panel.title = "选择 Aapp 项目文件夹（构建出的 .aapk 一变就自动重装）"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dev.watch(projectDirectory: url)
        console.append(.aapp, .info, "监视项目：\(url.path)（npm run build 后自动重装）")
        if !dev.paired { showPairing = true }
    }

    /// Experimental: real phones connect over the Mac's Bluetooth (tools/ble-bridge). The glasses then use a
    /// separate saved state seeded with the bridge's address, and classic Bluetooth (music/calls) is unavailable.
    @Published var phoneBridge = UserDefaults.standard.bool(forKey: "phoneBridge") {
        didSet { UserDefaults.standard.set(phoneBridge, forKey: "phoneBridge"); cachedStateDirectory = nil; if running { restart() } }
    }
    private var bridgeProcess: Process?

    private static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Starts ble-bridge.py and the CoreBluetooth helper; returns the extra Renode script that points the
    /// emulated radio at the bridge.
    private func startBridge(root: URL, output: URL) -> URL? {
        let script = root.appendingPathComponent("tools/ble-bridge/ble-bridge.py")
        let helper = root.appendingPathComponent("tools/ble-bridge/RayNeo Phone Bridge.app")
        let helperDev = root.appendingPathComponent("tools/ble-bridge/.build/RayNeo Phone Bridge.app")
        let helperApp = FileManager.default.fileExists(atPath: helper.path) ? helper : helperDev
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: helperApp.path) else {
            console.append(.phone, .error, "缺少蓝牙桥组件（tools/ble-bridge），先运行 sh tools/ble-bridge/build.sh"); return nil
        }
        let peer = Self.freePort(), helperPort = Self.freePort()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path, "--port", String(peer), "--helper-port", String(helperPort), "--log", output.appendingPathComponent("bridge.log").path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = (try? FileHandle(forWritingTo: { let u = output.appendingPathComponent("bridge.err"); FileManager.default.createFile(atPath: u.path, contents: nil); return u }())) ?? FileHandle.nullDevice
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.bridgeProcess === task, self.running else { return }
                self.bridgeProcess = nil
                self.console.append(.phone, .error, "蓝牙桥意外退出（\(finished.terminationStatus)），见 \(output.path)/bridge.err")
            }
        }
        do { try task.run() } catch { console.append(.phone, .error, "蓝牙桥启动失败：\(error.localizedDescription)"); return nil }
        bridgeProcess = task
        let resc = output.appendingPathComponent("bridge.resc")
        try? "btcRadio PeerPort \(peer)\n".write(to: resc, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", "-g", "-a", helperApp.path, "--args", "--port", String(helperPort), "--log", output.appendingPathComponent("helper.log").path, "--exit-with-bridge"]
            try? open.run()
            self?.console.append(.phone, .info, "真机蓝牙桥已开启：手机上打开雷鸟或 Spare io App 扫描眼镜（BES NUTTX-…），先关掉真眼镜；首次要在弹窗里允许蓝牙。日志：\(output.path)/bridge.log")
        }
        return resc
    }

    /// Xcode-style pause: freezes the emulated glasses (all cores, virtual time) without losing state.
    @Published private(set) var paused = false
    func togglePause() {
        guard running, !stopping else { return }
        paused.toggle()
        command(paused ? "pause" : "start")
        console.append(.app, .info, paused ? "已暂停模拟（固件停在当前指令）" : "继续运行")
        status = paused ? "已暂停 · ⌘⌥P 继续" : status
    }

    /// True while an Aapp app is drawing; the crown and keys then go to it instead of the firmware.
    var aappActive: Bool { aapp.frame != nil }

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
            candidates.append(root.appendingPathComponent(".local/renode-build/Renode.app/Contents/MacOS/renode"))   // scripts/build-renode.sh
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
        cachedStateDirectory = dataDirectory.appendingPathComponent("state/\(digest)\(phoneBridge ? "-bridge" : "")", isDirectory: true)
        return cachedStateDirectory
    }

    /// Asks the running emulator to write its flash and NAND, then waits (bounded, off the main thread) for
    /// the files. Saved images are written to a temporary name and only replace the previous state once
    /// both are complete, so a crash mid-save never leaves a half-written glasses state behind.
    private func saveState(then done: @escaping () -> Void) {
        guard running, booted, let state = stateDirectory else { done(); return }
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let flash = state.appendingPathComponent("flash0.bin"), nand = state.appendingPathComponent("nand-state.bin")
        let flashNew = state.appendingPathComponent("flash0.bin.saving"), nandNew = state.appendingPathComponent("nand-state.bin.saving")
        try? FileManager.default.removeItem(at: flashNew); try? FileManager.default.removeItem(at: nandNew)
        command("pause")
        command("nor SaveImage @\(flashNew.path.replacingOccurrences(of: " ", with: "\\ "))")
        command("nand SaveState @\(nandNew.path.replacingOccurrences(of: " ", with: "\\ "))")
        command("console_log \"state saved\"")
        let expectedFlash = (try? FileManager.default.attributesOfItem(atPath: flash.path)[.size] as? Int) ?? nil
        DispatchQueue.global().async {
            let files = FileManager.default
            let deadline = Date().addingTimeInterval(8)
            var stable = 0, lastSizes: [Int] = []
            while Date() < deadline {
                let sizes = [flashNew, nandNew].map { (try? files.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
                // Complete = both exist, flash at its full size (when known), sizes unchanged for 3 polls.
                if sizes.allSatisfy({ $0 > 0 }) && (expectedFlash == nil || sizes[0] == expectedFlash) {
                    stable = sizes == lastSizes ? stable + 1 : 0
                    if stable >= 3 {
                        _ = try? files.replaceItemAt(flash, withItemAt: flashNew)
                        _ = try? files.replaceItemAt(nand, withItemAt: nandNew)
                        break
                    }
                }
                lastSizes = sizes
                Thread.sleep(forTimeInterval: 0.1)
            }
            try? files.removeItem(at: flashNew); try? files.removeItem(at: nandNew)
            DispatchQueue.main.async(execute: done)
        }
    }

    func factoryReset() {
        stop { [weak self] in
            if let state = self?.stateDirectory { try? FileManager.default.removeItem(at: state) }
            self?.boot()
        }
    }

    func restart() { stop { [weak self] in self?.boot() } }

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
            if phoneBridge, let resc = startBridge(root: root, output: output) { task.arguments?.append(resc.path) }
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
            if safeStart { environment["COMPILE_CACHE"] = "0" }
            if phoneBridge { environment["BOND_ADDR"] = "c0:c0:ff:ee:00:01"; environment["BOND_OS"] = "android" }
            task.environment = environment
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = handle; task.standardError = handle
            task.terminationHandler = { [weak self] finished in
                try? handle.close()
                Task { @MainActor in
                    guard let self, self.process === task else { return }
                    self.teardown()
                    self.running = false; self.process = nil; self.booted = false; self.paused = false
                    let wanted = self.stopping
                    self.stopping = false
                    let callbacks = self.afterExit; self.afterExit.removeAll()
                    if wanted { callbacks.forEach { $0() }; return }
                    // Unexpected exit (Renode crash, killed): restart automatically, at most 3 times in 10 minutes.
                    let now = Date()
                    self.crashTimes = self.crashTimes.filter { now.timeIntervalSince($0) < 600 } + [now]
                    if self.crashTimes.count <= 3 {
                        self.status = "模拟器意外退出，正在自动重启（第 \(self.crashTimes.count) 次）…"
                        self.console.append(.app, .error, "Renode 意外退出（状态 \(finished.terminationStatus)），自动重启第 \(self.crashTimes.count) 次")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.boot() }
                    } else {
                        self.failure = "模拟器反复退出，已停止自动重启（固件 → 重新启动）。日志：\(output.path)"
                    }
                    _ = finished
                }
            }
            failure = nil; frame = nil; lastFrame = nil; screenOff = false; framesSeen = 0
            status = "启动中：\(firmware.lastPathComponent)"
            bootStarted = Date(); bootSeconds = nil
            process = task
            try task.run()
            running = true
            pruneRuns(keeping: output)
            bridge.wake.onKeyword = { [weak self] offset, event in
                Task { @MainActor in self?.command("hifi4 KeywordAt \(offset) \(event)") }
            }
            bridge.start(microphone: true)
            machineStarted = false
            let attempt = UUID(); bootAttempt = attempt
            // Boot watchdog: Renode stops a startup script silently on an error (and then idles forever).
            // If the machine has not started in 60 s, restart once without the compile cache.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.bootAttempt == attempt, self.running, !self.machineStarted else { return }
                if self.safeStart {
                    self.failure = "模拟器启动卡住，请查看日志控制台（⇧⌘Y）。日志：\(output.path)"
                    self.console.append(.app, .error, "启动 60 秒仍未开始运行固件（已是安全模式）")
                    return
                }
                self.console.append(.app, .error, "启动 60 秒仍未开始运行固件，改用安全模式（不用编译缓存）重新启动")
                self.safeStart = true
                self.restart()
            }
            console.onLine = { [weak self] line in
                guard let self else { return }
                if !self.machineStarted, line.contains("Machine started") { self.machineStarted = true }
                guard self.bootSeconds == nil, line.contains("fast boot done") else { return }
                self.bootSeconds = Int(Date().timeIntervalSince(self.bootStarted).rounded())
                self.booted = true
            }
            console.follow(output.appendingPathComponent("boot.log"))
            audio = bridge
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readFrame(output.appendingPathComponent("frame.pgm")) }
            }
            connectMonitor()
        } catch {
            process = nil; running = false
            failure = error.localizedDescription
        }
    }

    /// Saves the glasses state, then ends Renode and calls `done` once the process has really exited
    /// (the next boot reuses the monitor port and the run's files).
    func stop(then done: (() -> Void)? = nil) {
        guard let process, process.isRunning else {
            teardown(); done?(); return
        }
        if let done { afterExit.append(done) }
        guard !stopping else { return }   // a stop is already in progress
        stopping = true
        status = "正在保存眼镜状态…"
        saveState { [weak self] in
            guard let self, let process = self.process else { return }
            self.audio?.stop(); self.audio = nil
            // In app mode emulate.sh exec()s Renode, so this is the Renode process itself.
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
        }
    }

    /// Stops Renode synchronously (bounded) when the app quits.
    func stopForQuit() {
        guard let process, process.isRunning else { return }
        let semaphore = DispatchSemaphore(value: 0)
        stop { semaphore.signal() }
        let deadline = Date().addingTimeInterval(12)
        while semaphore.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private var stopping = false
    private var afterExit: [() -> Void] = []

    private func teardown() {
        bridgeProcess?.terminate(); bridgeProcess = nil
        audio?.stop(); audio = nil
        timer?.invalidate(); timer = nil
        monitor?.stateUpdateHandler = nil; monitor?.cancel(); monitor = nil
        monitorReady = false; pending.removeAll()
    }

    // MARK: input (crown key on GPIO0 P0_1, crown rotation via the OTS optical encoder)

    enum Input { case click, doubleClick, longPress, rotate(Int), press, release, head(String) }

    func send(_ input: Input) {
        console.append(.app, .debug, "输入：\(input)")
        if aappActive {
            switch input {
            case .rotate(let steps): for _ in 0..<abs(steps) { aapp.sendKey(steps > 0 ? .up : .down) }
            case .press, .click: aapp.sendKey(.enter)
            case .doubleClick: aapp.sendKey(.escape)
            case .longPress: aapp.sendKey(.longHold)
            case .release, .head: break
            }
            if case .head = input {} else { return }
        }
        switch input {
        case .click: command("gpio0 Pulse 1 false 120")
        case .doubleClick: command("gpio0 Pulse 1 false 120"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.command("gpio0 Pulse 1 false 120") }
        case .longPress: command("gpio0 Pulse 1 false 1300")
        case .rotate(let steps): command("i2c0.ots Rotate \(steps * 400)")
        case .press: command("gpio0 SetInput 1 false")      // crown key held down (P0_1 active low)
        case .release: command("gpio0 SetInput 1 true")
        case .head(let motion): command("headMotion \(motion)")   // BTH IMU, played in virtual time
        }
    }

    /// Monitor commands go out in order over one TCP connection. Renode opens its monitor port a moment after
    /// it starts, and the connection can drop; lines wait in `pending` and the link reconnects instead of
    /// silently losing input.
    private var pending: [String] = []
    private var monitorReady = false
    private var reconnectScheduled = false

    private func command(_ text: String) {
        guard running else { return }
        pending.append(text)
        if pending.count > 200 { pending.removeFirst(pending.count - 200) }
        flushMonitor()
    }

    private func flushMonitor() {
        guard running else { return }
        guard let monitor, monitorReady else { connectMonitor(); return }
        let lines = pending; pending.removeAll()
        guard !lines.isEmpty else { return }
        monitor.send(content: lines.map { $0 + "\n" }.joined().data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.pending.insert(contentsOf: lines, at: 0); self?.dropMonitor() }
        })
    }

    private func connectMonitor() {
        guard running, monitor == nil else { return }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: monitorPort)!, using: .tcp)
        monitor = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.monitor === connection else { return }
                switch state {
                case .ready: self.monitorReady = true; self.receiveMonitor(connection); self.flushMonitor()
                case .failed, .cancelled, .waiting: self.dropMonitor()
                default: break
                }
            }
        }
        connection.start(queue: .global())
    }

    /// Drains the monitor's replies (they are not needed, but an unread socket eventually stalls Renode).
    private func receiveMonitor(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] _, _, done, error in
            guard let connection else { return }
            if done || error != nil { Task { @MainActor in if self?.monitor === connection { self?.dropMonitor() } }; return }
            Task { @MainActor in self?.receiveMonitor(connection) }
        }
    }

    private func dropMonitor() {
        monitor?.stateUpdateHandler = nil
        monitor?.cancel(); monitor = nil; monitorReady = false
        guard running, !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reconnectScheduled = false
            if self?.pending.isEmpty == false { self?.connectMonitor() }
        }
    }

    // MARK: display

    @Published private(set) var screenOff = false
    @Published private(set) var fps = 0
    private(set) var booted = false
    private var bootStarted = Date()
    private var bootSeconds: Int?
    private var framesSeen = 0
    private var frameTimes: [Date] = []
    private var crashTimes: [Date] = []
    private var machineStarted = false
    private var bootAttempt = UUID()
    /// Set after a stalled start: later boots in this app session skip Renode's compile cache.
    private var safeStart = false
    private var lastFrameModified: Date?
    private var lastCG: CGImage?

    private func readFrame(_ url: URL) {
        let now = Date()
        frameTimes = frameTimes.filter { now.timeIntervalSince($0) < 1 }
        fps = frameTimes.count
        // Cheap change check first: the LCDC rewrites frame.pgm (atomically) only when a scanout changes it.
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != lastFrameModified else { updateStatus(); return }
        guard let data = try? Data(contentsOf: url), data != lastFrame,
              let decoded = FirmwareFrame.decode(data) else { return }
        lastFrameModified = modified
        lastFrame = data
        frameTimes.append(now); framesSeen += 1
        screenOff = decoded.blank && framesSeen > 1
        if !booted, now.timeIntervalSince(bootStarted) > 25 { booted = true }
        lastCG = decoded.image
        frame = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        updateStatus()
    }

    private func updateStatus() {
        guard running, !stopping, !paused else { return }
        if !booted, Date().timeIntervalSince(bootStarted) > 25 { booted = true }
        let boot = bootSeconds.map { " · 开机 \($0) 秒" } ?? " · 启动中 \(Int(Date().timeIntervalSince(bootStarted))) 秒"
        status = "运行中\(boot) · \(fps) 帧/秒"
    }

    /// Saves the current single-eye frame as PNG.
    func saveScreenshot() {
        guard let image = lastCG else { status = "还没有画面可以截图"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "RayNeo-截图-\(stamp.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: url, options: .atomic); status = "已保存截图：\(url.lastPathComponent)" }
        catch { failure = "截图保存失败：\(error.localizedDescription)" }
    }

    /// Keeps the 5 newest run folders (logs, generated flash/NAND images: ~180 MB each).
    private func pruneRuns(keeping current: URL) {
        let runs = dataDirectory.appendingPathComponent("runs", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let files = FileManager.default
            guard let names = try? files.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.creationDateKey]) else { return }
            let old = names.filter { $0.lastPathComponent.hasPrefix("ui-") && $0.standardizedFileURL != current.standardizedFileURL }
                .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
                .dropFirst(4)
            old.forEach { try? files.removeItem(at: $0) }
        }
    }

    // MARK: head control (mouse drag drives the BTH IMU through headMotion Look)

    @Published var headControl = false
    @Published private(set) var headPitch = 0.0
    @Published private(set) var headYaw = 0.0
    private var lastLookSent = Date.distantPast

    func toggleHeadControl() { headControl.toggle() }

    func dragHead(dx: Double, dy: Double) {
        headYaw = max(-90, min(90, headYaw + dx * 0.25))
        headPitch = max(-60, min(60, headPitch - dy * 0.25))
        // ~25 updates a second is plenty for the IMU's 200 ms posture samples.
        if Date().timeIntervalSince(lastLookSent) > 0.04 { sendLook() }
    }

    func endHeadDrag() { sendLook() }

    func resetHead() { headPitch = 0; headYaw = 0; sendLook() }

    private func sendLook() {
        lastLookSent = Date()
        command(String(format: "headMotion Look %.1f %.1f", headPitch, headYaw))
    }
}

/// The emulator writes a binary PGM (P5) whose bytes are the panel's grey levels
/// (two eyes side by side, 4-bit samples expanded to 0..255). The app shows one eye, the left (CS1) panel:
/// the firmware draws some layers (toasts) a few pixels apart in the two eyes for depth, so merging the eyes
/// would double them. Only if the left eye is blank while the right is not, the right one is shown.
/// Rendered green like the waveguide.
enum FirmwareFrame {
    struct Decoded { let image: CGImage; let blank: Bool }

    static func decode(_ data: Data) -> Decoded? {
        guard let both = decodeBothEyes(data) else { return nil }
        let (bytes, width, height) = both
        guard width % 2 == 0 else { return image(bytes, width, height).map { Decoded(image: $0, blank: false) } }
        let eye = width / 2
        func extract(_ offset: Int) -> ([UInt8], Int) {
            var out = [UInt8](repeating: 0, count: eye * height)
            var lit = 0
            bytes.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    let row = y * width + offset
                    for x in 0..<eye { let v = src[row + x]; out[y * eye + x] = v; if v > 16 { lit += 1 } }
                }
            }
            return (out, lit)
        }
        var (pixels, lit) = extract(0)
        if lit == 0 { let right = extract(eye); if right.1 > 0 { (pixels, lit) = right } }
        return image(pixels, eye, height).map { Decoded(image: $0, blank: lit == 0) }
    }

    /// Both eyes side by side, as the panel scanned them out (tests and research tools).
    static func decodeStereo(_ data: Data) -> CGImage? {
        guard let both = decodeBothEyes(data) else { return nil }
        return image(both.0, both.1, both.2)
    }

    private static func decodeBothEyes(_ data: Data) -> ([UInt8], Int, Int)? {
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
        return (Array(bytes[(third + 1)...]), values[0], values[1])
    }

    private static func image(_ grey: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var i = 0
        for g in grey { rgba[i] = UInt8(UInt16(g) / 5); rgba[i + 1] = g; rgba[i + 2] = UInt8(UInt16(g) / 4); i += 4 }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
