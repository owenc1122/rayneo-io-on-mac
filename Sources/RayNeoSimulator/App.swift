import SwiftUI

@main
struct RayNeoApp: App {
    @StateObject private var firmware = FirmwareModel()
    var body: some Scene {
        WindowGroup("RayNeo io on Mac") {
            SimulatorView(firmware: firmware)
                .onAppear { firmware.boot() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in firmware.stop() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 330)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("固件") {
                Button("选择固件文件夹…") { firmware.chooseFirmware() }.keyboardShortcut("o")
                Button("从雷鸟 AI App 导入眼镜字体…") { firmware.chooseFonts() }
                Button("准备资源工具（一次性下载）") { firmware.installResourceTools() }
                Button("重新启动") { firmware.restart() }.keyboardShortcut("r")
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
                Button("抬头（息屏时抬头亮屏）") { firmware.send(.head("Pose 25 0")) }
                Button("低头") { firmware.send(.head("Pose -30 0")) }
                Button("平视") { firmware.send(.head("Pose 0 0")) }
                Divider()
                Button("点头") { firmware.send(.head("Nod")) }
                Button("摇头") { firmware.send(.head("Shake")) }
            }
            CommandMenu("声音") {
                Toggle("语音唤醒「小雷小雷」（手机 App 里的同名设置）", isOn: $firmware.voiceWakeup)
            }
        }
    }
}

struct SimulatorView: View {
    @ObservedObject var firmware: FirmwareModel
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let frame = firmware.frame {
                    Image(nsImage: frame)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .accessibilityLabel("原固件显示画面（左右眼）")
                } else {
                    Text(firmware.failure ?? "系统启动中（原固件约需数分钟进入桌面）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            HStack {
                Text(firmware.failure ?? firmware.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("空格 按表冠（按住即长按）· D 双击 · ↑↓/滚轮 旋转").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .frame(minWidth: 540, minHeight: 170)
        .preferredColorScheme(.dark)
        .background(KeyCatcher(firmware: firmware))
        .onDisappear { firmware.stop() }
    }
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
            switch event.keyCode {
            case 49: MainActor.assumeIsolated { firmware.send(.press) }            // space
            case 2: MainActor.assumeIsolated { firmware.send(.doubleClick) }       // D
            case 37: MainActor.assumeIsolated { firmware.send(.longPress) }        // L
            case 126: MainActor.assumeIsolated { firmware.send(.rotate(1)) }       // up
            case 125: MainActor.assumeIsolated { firmware.send(.rotate(-1)) }      // down
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
