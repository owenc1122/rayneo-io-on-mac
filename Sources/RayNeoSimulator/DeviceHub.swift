import AppKit
import Foundation
import UniformTypeIdentifiers

/// Phones and phone emulators around the glasses simulator: Android devices and emulators over adb (the RayNeo
/// Aapp Host runs there and draws on this simulator through the 10002 display link), and the iOS Simulator.
/// Everything is local; nothing is uploaded.
@MainActor final class DeviceHub: ObservableObject {
    struct AndroidDevice: Identifiable, Hashable {
        let serial: String
        let model: String
        let emulator: Bool
        var id: String { serial }
        var label: String { emulator ? "安卓模拟器 · \(model)" : "安卓手机 · \(model)" }
    }

    static let hostPackage = "com.rayneo.aapp.aapp_host"
    /// Ports the phone must reach on this Mac: the Aapp display link (and later the dev server).
    var reversePorts: [UInt16] = [10002, AappDevServer.defaultPort]

    @Published private(set) var android: [AndroidDevice] = []
    @Published private(set) var hostInstalled: [String: Bool] = [:]
    @Published private(set) var avds: [String] = []
    @Published private(set) var iosSimulators: [(udid: String, name: String, booted: Bool)] = []
    @Published private(set) var busy: String?

    weak var console: LogConsole?
    private var poll: Timer?
    private var reversed: Set<String> = []
    private var logcat: [String: Process] = [:]

    var adb: URL? { sdkTool("platform-tools/adb") }
    var emulatorTool: URL? { sdkTool("emulator/emulator") }

    private func sdkTool(_ relative: String) -> URL? {
        var roots: [String] = []
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] { roots.append(home) }
        roots.append(NSHomeDirectory() + "/Library/Android/sdk")
        for root in roots {
            let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func start() {
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        poll?.invalidate(); poll = nil
        logcat.values.forEach { $0.terminate() }; logcat.removeAll()
    }

    // MARK: discovery

    func refresh() {
        guard let adb else { android = []; return }
        Self.run(adb, ["devices", "-l"]) { [weak self] output, _ in
            guard let self else { return }
            var found: [AndroidDevice] = []
            for line in output.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[1] == "device" else { continue }
                let serial = String(parts[0])
                let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? serial
                found.append(AndroidDevice(serial: serial, model: model, emulator: serial.hasPrefix("emulator-")))
            }
            let gone = Set(self.android.map(\.serial)).subtracting(found.map(\.serial))
            let new = Set(found.map(\.serial)).subtracting(self.android.map(\.serial))
            self.android = found
            for serial in gone { self.reversed.remove(serial); self.logcat[serial]?.terminate(); self.logcat[serial] = nil
                self.console?.append(.phone, .info, "安卓设备已断开：\(serial)") }
            for device in found where new.contains(device.serial) {
                self.console?.append(.phone, .info, "安卓设备已连接：\(device.label)")
                self.prepare(device)
            }
        }
        if let tool = emulatorTool {
            Self.run(tool, ["-list-avds"]) { [weak self] output, _ in
                self?.avds = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("INFO") }
            }
        }
        Self.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "list", "devices", "available", "-j"]) { [weak self] output, _ in
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [String: [[String: Any]]] else { return }
            self?.iosSimulators = devices.filter { $0.key.contains("iOS") }.flatMap { $0.value }.compactMap {
                guard let udid = $0["udid"] as? String, let name = $0["name"] as? String, name.contains("iPhone") else { return nil }
                return (udid, name, ($0["state"] as? String) == "Booted")
            }
        }
    }

    /// New Android device: route the display link to this Mac, check the Host, follow its log.
    private func prepare(_ device: AndroidDevice) {
        guard let adb else { return }
        for port in reversePorts {
            Self.run(adb, ["-s", device.serial, "reverse", "tcp:\(port)", "tcp:\(port)"]) { [weak self] _, status in
                if status == 0 { self?.reversed.insert(device.serial) }
                else { self?.console?.append(.phone, .warning, "\(device.label)：端口 \(port) 转发失败") }
            }
        }
        Self.run(adb, ["-s", device.serial, "shell", "pm", "list", "packages", Self.hostPackage]) { [weak self] output, _ in
            let installed = output.contains(Self.hostPackage)
            self?.hostInstalled[device.serial] = installed
            self?.console?.append(.phone, installed ? .info : .warning,
                                  installed ? "\(device.label)：已装 Aapp Host，开发工具 → 显示设备 → 电脑模拟器 填 127.0.0.1:10002"
                                            : "\(device.label)：还没装 Aapp Host（设备 → 安装 Aapp Host…）")
            if installed { self?.followLog(device) }
        }
    }

    /// Host and app logs: tag `flutter` (lines `[AappHost] …`, `JS · …` from app.log, `RUN`/`RELOAD`/`RUNTIME`) and `AappHost`.
    private func followLog(_ device: AndroidDevice) {
        guard let adb, logcat[device.serial] == nil else { return }
        let task = Process()
        task.executableURL = adb
        task.arguments = ["-s", device.serial, "logcat", "-v", "brief", "-T", "1", "-s", "flutter:I", "AappHost:V"]
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for line in buffer.lines(appending: chunk) {
                guard let body = line.range(of: "): ").map({ String(line[$0.upperBound...]) }), !body.isEmpty else { continue }
                let level: LogConsole.Level = line.hasPrefix("E/") || body.contains("RUNTIME") ? .error : line.hasPrefix("W/") ? .warning : .info
                Task { @MainActor in self?.console?.append(.aapp, level, body) }
            }
        }
        task.terminationHandler = { [weak self] _ in Task { @MainActor in self?.logcat[device.serial] = nil } }
        try? task.run()
        logcat[device.serial] = task
    }

    // MARK: actions

    /// Installs the RayNeo Aapp Host APK on every connected Android device (or the one given).
    func installHost(on device: AndroidDevice? = nil) {
        guard let adb else { console?.append(.phone, .error, "没找到 adb（Android SDK platform-tools）"); return }
        let panel = NSOpenPanel()
        panel.title = "选择 Aapp Host 安装包"
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let apk = panel.url else { return }
        let targets = device.map { [$0] } ?? android
        guard !targets.isEmpty else { console?.append(.phone, .warning, "没有连接的安卓设备"); return }
        for target in targets {
            busy = "正在安装 Host 到 \(target.label)…"
            console?.append(.phone, .info, "安装 \(apk.lastPathComponent) → \(target.label)")
            Self.run(adb, ["-s", target.serial, "install", "-r", apk.path]) { [weak self] output, status in
                self?.busy = nil
                self?.console?.append(.phone, status == 0 ? .info : .error, "\(target.label)：\(output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "")")
                if status == 0 { self?.prepare(target) }
            }
        }
    }

    /// Puts an .aapk into the phone's Download folder (Host → 开发工具 → 运行与调试 → 导入 AAPK) and opens the Host.
    func pushAapk(_ url: URL? = nil) {
        guard let adb else { console?.append(.phone, .error, "没找到 adb"); return }
        var file = url
        if file == nil {
            let panel = NSOpenPanel()
            panel.title = "选择 Aapp 应用包（.aapk）"
            panel.allowedContentTypes = [UTType(filenameExtension: "aapk") ?? .data]
            guard panel.runModal() == .OK else { return }
            file = panel.url
        }
        guard let file else { return }
        guard let target = android.first else { console?.append(.phone, .warning, "没有连接的安卓设备或模拟器"); return }
        busy = "正在传 \(file.lastPathComponent)…"
        Self.run(adb, ["-s", target.serial, "push", file.path, "/sdcard/Download/\(file.lastPathComponent)"]) { [weak self] output, status in
            guard let self else { return }
            self.busy = nil
            if status == 0 {
                self.console?.append(.phone, .info, "已放到 \(target.label) 的 Download：\(file.lastPathComponent)。在 Host「开发工具 → 运行与调试 → 导入 AAPK」选它")
                self.launchHost(on: target)
            } else { self.console?.append(.phone, .error, "传输失败：\(output)") }
        }
    }

    /// Types the dev-server pairing text into the phone (DevTools → 扫码连接电脑 → 粘贴配对信息 must have focus).
    func typeOnPhone(_ text: String) {
        guard let adb, let target = android.first else { console?.append(.phone, .warning, "没有连接的安卓设备"); return }
        let escaped = text.replacingOccurrences(of: "'", with: "")
        Self.run(adb, ["-s", target.serial, "shell", "input text '\(escaped)'"]) { [weak self] output, status in
            self?.console?.append(.phone, status == 0 ? .info : .error, status == 0 ? "已把配对信息输入到 \(target.label)" : "输入失败：\(output)")
        }
    }

    func launchHost(on device: AndroidDevice? = nil) {
        guard let adb, let target = device ?? android.first else { return }
        Self.run(adb, ["-s", target.serial, "shell", "monkey", "-p", Self.hostPackage, "-c", "android.intent.category.LAUNCHER", "1"]) { _, _ in }
    }

    func screenshotPhone() {
        guard let adb, let target = android.first else { console?.append(.phone, .warning, "没有连接的安卓设备"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "手机截图-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Self.runData(adb, ["-s", target.serial, "exec-out", "screencap", "-p"]) { [weak self] data, status in
            if status == 0, !data.isEmpty { try? data.write(to: url); self?.console?.append(.phone, .info, "手机截图已保存：\(url.lastPathComponent)") }
        }
    }

    // MARK: emulators

    func launchAndroidEmulator(_ name: String) {
        guard let tool = emulatorTool else { return }
        let task = Process()
        task.executableURL = tool
        task.arguments = ["-avd", name, "-netdelay", "none", "-netspeed", "full"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do { try task.run(); console?.append(.phone, .info, "正在启动安卓模拟器 \(name)（连上后自动转发 10002，装好 Host 即可连接）") }
        catch { console?.append(.phone, .error, "安卓模拟器启动失败：\(error.localizedDescription)") }
    }

    /// One-time setup of the Android emulator with an arm64 Google APIs image (downloads ~2 GB from Google).
    func installAndroidEmulator() {
        guard let sdkmanager = sdkTool("cmdline-tools/latest/bin/sdkmanager") ?? sdkTool("cmdline-tools/bin/sdkmanager"),
              let avdmanager = sdkTool("cmdline-tools/latest/bin/avdmanager") ?? sdkTool("cmdline-tools/bin/avdmanager") else {
            console?.append(.phone, .error, "没找到 Android SDK 命令行工具（sdkmanager）"); return
        }
        let alert = NSAlert()
        alert.messageText = "下载安卓模拟器？"
        alert.informativeText = "会从 Google 下载 Android 模拟器和 Android 15 (arm64) 系统镜像，约 2 GB，放在 Android SDK 目录。之后可在「设备」菜单一键启动。"
        alert.addButton(withTitle: "下载"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let image = "system-images;android-35;google_apis;arm64-v8a"
        busy = "正在下载安卓模拟器（约 2 GB）…"
        console?.append(.phone, .info, "sdkmanager 安装 emulator 和 \(image)")
        Self.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "yes | '\(sdkmanager.path)' --install emulator '\(image)' && echo no | '\(avdmanager.path)' create avd -n RayNeo_Phone -k '\(image)' -d pixel_5 --force"]) { [weak self] output, status in
            self?.busy = nil
            self?.console?.append(.phone, status == 0 ? .info : .error, status == 0 ? "安卓模拟器已就绪：RayNeo_Phone" : "安装失败：\(output.suffix(400))")
            self?.refresh()
        }
    }

    func launchIOSSimulator() {
        Task {
            if let booted = iosSimulators.first(where: \.booted) {
                console?.append(.phone, .info, "iPhone 模拟器已在运行：\(booted.name)")
            } else if let first = iosSimulators.first {
                Self.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "boot", first.udid]) { _, _ in }
                console?.append(.phone, .info, "启动 iPhone 模拟器：\(first.name)")
            } else {
                // No iPhone device yet: create one on the newest installed iOS runtime.
                Self.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "rt=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)[\"runtimes\"] if x[\"platform\"]==\"iOS\" and x[\"isAvailable\"]]; print(r[-1][\"identifier\"] if r else \"\")'); dt=$(xcrun simctl list devicetypes | grep -o 'com.apple.CoreSimulator.SimDeviceType.iPhone[^)]*' | tail -1); [ -n \"$rt\" ] && udid=$(xcrun simctl create 'RayNeo iPhone' \"$dt\" \"$rt\") && xcrun simctl boot $udid && echo $udid"]) { [weak self] output, status in
                    self?.console?.append(.phone, status == 0 ? .info : .error, status == 0 ? "已创建并启动 iPhone 模拟器" : "创建 iPhone 模拟器失败（需要 Xcode 的 iOS 模拟器运行时）：\(output.suffix(300))")
                    self?.refresh()
                }
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"))
        }
    }

    // MARK: process helpers

    /// Splits a byte stream into lines; used from one readability handler at a time.
    final class LineBuffer: @unchecked Sendable {
        private var data = Data()
        func lines(appending chunk: Data) -> [String] {
            data.append(chunk)
            var out: [String] = []
            while let newline = data.firstIndex(of: 10) {
                out.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
                data.removeSubrange(data.startIndex...newline)
            }
            if data.count > 1_000_000 { data.removeAll() }
            return out
        }
    }

    nonisolated static func run(_ tool: URL, _ arguments: [String], completion: @escaping @MainActor (String, Int32) -> Void) {
        runData(tool, arguments) { data, status in completion(String(decoding: data, as: UTF8.self), status) }
    }

    nonisolated static func runData(_ tool: URL, _ arguments: [String], completion: @escaping @MainActor (Data, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = tool
            task.arguments = arguments
            let pipe = Pipe()
            task.standardOutput = pipe; task.standardError = pipe; task.standardInput = FileHandle.nullDevice
            var data = Data()
            do {
                try task.run()
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
            } catch { data = Data(error.localizedDescription.utf8) }
            let status = task.isRunning ? -1 : task.terminationStatus
            Task { @MainActor in completion(data, status) }
        }
    }
}
