import SwiftUI

@main
struct RayNeoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var firmware = FirmwareModel()
    @StateObject private var devices = DeviceHub()
    /// nil until the developer picks 固件模式 or 开发模式 (`--dev <folder>` / RAYNEO_DEV_PROJECT opens 开发模式 directly).
    @State private var mode: LaunchMode? = LaunchMode.fromLaunchArguments()
    var body: some Scene {
        // One window, one emulator: closing it quits the app (and saves the glasses state), so the app can
        // never be left running in the Dock with no window and the emulator still burning CPU.
        Window("RayNeo io on Mac", id: "main") {
            Group {
                switch mode {
                case nil:
                    ModeChooser { chosen in mode = chosen; start(chosen) }
                case .firmware:
                    SimulatorView(firmware: firmware, devices: devices)
                case .dev:
                    DevModeView(firmware: firmware)
                }
            }
            .onAppear {
                delegate.firmware = firmware; delegate.devices = devices
                devices.console = firmware.console; devices.start()
                if let mode { start(mode) }
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 760, height: 440)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("保存眼镜截图…") { firmware.saveScreenshot() }.keyboardShortcut("s")
                Button("导出日志…") { firmware.console.export() }
            }
            CommandGroup(after: .toolbar) {
                Button("显示/隐藏日志控制台") { firmware.console.visible.toggle() }.keyboardShortcut("y", modifiers: [.command, .shift])
                Button("清空日志") { firmware.console.clear() }.keyboardShortcut("k")
            }
            CommandMenu("固件") {
                Button("选择固件文件夹…") { firmware.chooseFirmware() }.keyboardShortcut("o")
                Button("从雷鸟 AI App 导入眼镜字体…") { firmware.chooseFonts() }
                Button("准备资源工具（一次性下载）") { firmware.installResourceTools() }
                Button("重新启动") { firmware.restart() }.keyboardShortcut("r")
                Button(firmware.paused ? "继续运行" : "暂停运行") { firmware.togglePause() }.keyboardShortcut("p", modifiers: [.command, .option])
                Button("恢复出厂设置") { firmware.factoryReset() }
            }
            CommandMenu("输入") {
                Button("表冠单击（空格）") { firmware.send(.click) }
                Button("表冠双击（D）") { firmware.send(.doubleClick) }
                Button("表冠长按 1.3 秒（L）") { firmware.send(.longPress) }
                Button("表冠向前旋转（↑）") { firmware.send(.rotate(1)) }
                Button("表冠向后旋转（↓）") { firmware.send(.rotate(-1)) }
            }
            CommandMenu("头部动作") {
                Toggle("鼠标拖动控制头部（H）", isOn: $firmware.headControl)
                Button("头部回正（R）") { firmware.resetHead() }
                Divider()
                Button("抬头（息屏时抬头亮屏）") { firmware.send(.head("Pose 25 0")) }
                Button("低头") { firmware.send(.head("Pose -30 0")) }
                Button("平视") { firmware.send(.head("Pose 0 0")) }
                Divider()
                Button("点头") { firmware.send(.head("Nod")) }
                Button("摇头") { firmware.send(.head("Shake")) }
            }
            CommandMenu("设备") {
                Section("安卓（Aapp Host 跑在这里，画面显示在本模拟器）") {
                    if devices.android.isEmpty { Text("未连接安卓设备（USB 插上并允许调试即可）") }
                    ForEach(devices.android) { device in
                        Text("\(device.label)\(devices.hostInstalled[device.serial] == true ? " · 已装 Host" : "")")
                    }
                    Button("安装 Aapp Host…") { devices.installHost() }
                    Button("安装并运行 Aapp 应用…") { firmware.runAapk() }.keyboardShortcut("i")
                    Button("监视项目文件夹（保存后自动重装）…") { firmware.watchProject() }
                    Button("停止应用") { firmware.dev.stopApp() }.keyboardShortcut(".")
                    Button("重新运行应用") { firmware.dev.restartApp() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("配对手机开发工具…") { firmware.showPairing = true }
                    Button("仅传到手机 Download（手动导入）…") { devices.pushAapk() }
                    Button("打开手机上的 Host") { devices.launchHost() }
                    Button("手机截图…") { devices.screenshotPhone() }
                }
                Section("真机（iPhone / 安卓）") {
                    Toggle("真机经 Mac 蓝牙连接眼镜（实验）", isOn: $firmware.phoneBridge)
                }
                Section("模拟器") {
                    if devices.avds.isEmpty {
                        Button(devices.emulatorTool == nil ? "下载安卓模拟器（约 2 GB）…" : "创建安卓模拟器…") { devices.installAndroidEmulator() }
                    }
                    ForEach(devices.avds, id: \.self) { name in
                        Button("启动安卓模拟器 \(name)") { devices.launchAndroidEmulator(name) }
                    }
                    Button("启动 iPhone 模拟器") { devices.launchIOSSimulator() }
                }
            }
            CommandMenu("开发模式") {
                Button("手动连接：拷贝模拟器配对邀请") { firmware.copyPortalInvitation() }
            }
            CommandMenu("声音") {
                Toggle("语音唤醒「小雷小雷」（手机 App 里的同名设置）", isOn: $firmware.voiceWakeup)
            }
        }
    }
}

enum LaunchMode: Equatable {
    case firmware
    /// 开发模式: no firmware, only the rApp's glasses picture from the phone Host.
    case dev(URL)

    static func fromLaunchArguments() -> LaunchMode? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--dev"), index + 1 < arguments.count {
            return .dev(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
        if let path = ProcessInfo.processInfo.environment["RAYNEO_DEV_PROJECT"], !path.isEmpty {
            return .dev(URL(fileURLWithPath: path, isDirectory: true))
        }
        return nil
    }
}

extension RayNeoApp {
    @MainActor func start(_ mode: LaunchMode) {
        switch mode {
        case .firmware:
            firmware.boot()
            firmware.startAapp()
        case .dev(let project):
            // No Renode: lvgl_host (child, port 10002) and the dev server (17890, adb reverse by DeviceHub).
            firmware.startDevMode(project: project)
            firmware.console.append(.aapp, .info, "开发模式：\(project.path)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var firmware: FirmwareModel?
    weak var devices: DeviceHub?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { devices?.stop(); firmware?.portal.stop(); firmware?.stopForQuit() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A window restored onto a display that is no longer connected would open invisibly.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible || window.canBecomeMain {
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }
}

struct SimulatorView: View {
    @ObservedObject var firmware: FirmwareModel
    @ObservedObject private var console: LogConsole
    @ObservedObject private var aapp: AappDisplay
    @ObservedObject private var dev: AappDevServer
    let devices: DeviceHub
    init(firmware: FirmwareModel, devices: DeviceHub) {
        self.firmware = firmware; self.devices = devices
        self.console = firmware.console; self.aapp = firmware.aapp; self.dev = firmware.dev
    }
    var body: some View {
        VSplitView {
            display.frame(minHeight: 220)
            if console.visible {
                LogConsoleView(console: console).frame(minHeight: 120, idealHeight: 220)
            }
        }
        .frame(minWidth: 540, minHeight: 300)
        .preferredColorScheme(.dark)
        .background(KeyCatcher(firmware: firmware))
        .sheet(isPresented: $firmware.showPairing) { PairingSheet(firmware: firmware, devices: devices) }
    }

    private var display: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let app = aapp.frame {
                        // An Aapp app from the phone Host is drawing: it replaces the firmware picture.
                        Image(decorative: app, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .accessibilityLabel("Aapp 应用画面")
                            .gesture(SpatialTapGesture().onEnded { tap in
                                let size = CGSize(width: app.width, height: app.height)
                                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                                let origin = CGPoint(x: (geometry.size.width - size.width * scale) / 2, y: (geometry.size.height - size.height * scale) / 2)
                                aapp.sendTap(x: (tap.location.x - origin.x) / scale, y: (tap.location.y - origin.y) / scale)
                            })
                    } else if let frame = firmware.frame {
                        Image(nsImage: frame)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .accessibilityLabel("原固件显示画面")
                    } else {
                        Text(firmware.failure ?? "系统启动中…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    if aapp.frame != nil {
                        VStack { HStack { Spacer()
                            Text("Aapp · \(aapp.appName ?? "应用") · \(aapp.renderMode == "micro" ? "流畅" : "普通")")
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.green)
                        }; Spacer() }.padding(8)
                    } else if firmware.screenOff && firmware.failure == nil {
                        Text("眼镜已息屏 · 按空格唤醒")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if firmware.headControl {
                        VStack {
                            HStack {
                                Text(String(format: "头部控制 · 左右 %+.0f° · 抬头 %+.0f° · 拖动转头 · R 回正 · H 退出",
                                            firmware.headYaw, firmware.headPitch))
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(.green)
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(firmware.headControl ? headDrag : nil)
            }
            HStack {
                Text(firmware.failure ?? firmware.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("· 开发 \(dev.paired ? (dev.deviceName ?? "已配对") : dev.status)\(dev.lastDeploy.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(dev.paired ? .green : .secondary).lineLimit(1)
                Text("· Aapp \(aapp.connected ? "已连接" : aapp.sessionInfo)").font(.caption).foregroundStyle(aapp.connected ? .green : .secondary).lineLimit(1)
                Spacer()
                Text("空格 表冠 · D 双击 · ↑↓/滚轮 旋转 · H 头部 · ⌘S 截图 · ⇧⌘Y 日志").font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    private var headDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                firmware.dragHead(dx: delta.width, dy: delta.height)
            }
            .onEnded { _ in lastDrag = .zero; firmware.endHeadDrag() }
    }
    @State private var lastDrag = CGSize.zero
}

/// Captures keyboard and scroll-wheel input for the crown.
struct KeyCatcher: NSViewRepresentable {
    let firmware: FirmwareModel
    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.firmware = firmware
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CatcherView: NSView {
        weak var firmware: FirmwareModel?
    weak var devices: DeviceHub?
        private var scrollAccumulator: CGFloat = 0
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        // Space follows the real key: held as long as it is held (click, double click, long press).
        override func keyUp(with event: NSEvent) {
            if event.keyCode == 49, let firmware { MainActor.assumeIsolated { firmware.send(.release) } }
            else { super.keyUp(with: event) }
        }
        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat, let firmware else { return }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 49: MainActor.assumeIsolated { firmware.send(.press) }            // space
            case 2: MainActor.assumeIsolated { firmware.send(.doubleClick) }       // D
            case 37: MainActor.assumeIsolated { firmware.send(.longPress) }        // L
            case 4: MainActor.assumeIsolated { firmware.toggleHeadControl() }      // H
            case 15: MainActor.assumeIsolated { firmware.resetHead() }             // R
            case 126: MainActor.assumeIsolated { firmware.send(.rotate(1)) }       // up
            case 125: MainActor.assumeIsolated { firmware.send(.rotate(-1)) }      // down
            // ← → Return Esc go to an open Aapp app (the official simulator's keys).
            case 123: MainActor.assumeIsolated { if firmware.aappActive { firmware.aapp.sendKey(.left) } }
            case 124: MainActor.assumeIsolated { if firmware.aappActive { firmware.aapp.sendKey(.right) } }
            case 36: MainActor.assumeIsolated { if firmware.aappActive { firmware.aapp.sendKey(.enter) } }
            case 53: MainActor.assumeIsolated { if firmware.aappActive { firmware.aapp.sendKey(.escape) } }
            default: super.keyDown(with: event)
            }
        }
        override func scrollWheel(with event: NSEvent) {
            scrollAccumulator += event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
            while abs(scrollAccumulator) >= threshold {
                let step = scrollAccumulator > 0 ? 1 : -1
                scrollAccumulator -= CGFloat(step) * threshold
                if let firmware { MainActor.assumeIsolated { firmware.send(.rotate(step)) } }
            }
        }
    }
}

/// Pairing the phone's DevTools with the simulator's dev server (QR or text, like `aapp dev`).
struct PairingSheet: View {
    @ObservedObject var firmware: FirmwareModel
    @ObservedObject var dev: AappDevServer
    let devices: DeviceHub
    @Environment(\.dismiss) private var dismiss
    init(firmware: FirmwareModel, devices: DeviceHub) { self.firmware = firmware; self.dev = firmware.dev; self.devices = devices }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配对手机开发工具").font(.headline)
            if dev.pairingText.isEmpty {
                Text("先用「设备 → 安装并运行 Aapp 应用…」选一个 .aapk，配对信息里带着这个应用。").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = dev.pairingQRCode() {
                        Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 180, height: 180)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("手机 Host → 开发工具 → 扫码连接电脑，扫这个码；或点「无法扫码？粘贴配对信息」后按下面的「输入到手机」。")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("USB 连接时已自动转发 10002 和 \(String(AappDevServer.defaultPort)) 端口。配对信息 10 分钟内有效。").font(.caption).foregroundStyle(.secondary)
                        Text(dev.pairingText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                        HStack {
                            Button("拷贝") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(dev.pairingText, forType: .string) }
                            Button("输入到手机") { devices.typeOnPhone(dev.pairingText) }
                        }
                        Text(dev.paired ? "已配对：\(dev.deviceName ?? "手机")" : dev.status).foregroundStyle(dev.paired ? .green : .secondary)
                    }
                }
            }
            HStack { Spacer(); Button(dev.paired ? "完成" : "关闭") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 560)
    }
}
