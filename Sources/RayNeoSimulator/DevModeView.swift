import AppKit
import SwiftUI

/// First screen: 固件模式 (original firmware on Renode) or 开发模式 (an rApp project, no firmware).
struct ModeChooser: View {
    let choose: (LaunchMode) -> Void
    var body: some View {
        VStack(spacing: 18) {
            Text("RayNeo io on Mac").font(.title2.weight(.semibold))
            HStack(spacing: 16) {
                card(title: "开发模式", detail: "选一个 rApp 工程文件夹。手机 Host 一键连接后，眼镜画面显示在这里，保存即重装。不需要固件。",
                     symbol: "hammer") {
                    let panel = NSOpenPanel()
                    panel.title = "选择 rApp 工程文件夹"
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { choose(.dev(url)) }
                }
                card(title: "固件模式", detail: "在 Mac 上运行原版眼镜固件（需要自备固件文件夹）。", symbol: "eyeglasses") {
                    choose(.firmware)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 300)
        .preferredColorScheme(.dark)
    }

    private func card(title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.green)
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16).frame(width: 240, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// 开发模式 window: only the 540×220 glasses picture, a connection chip, knob input and the collapsible console.
struct DevModeView: View {
    @ObservedObject var firmware: FirmwareModel
    @ObservedObject private var console: LogConsole
    @ObservedObject private var aapp: PortalSimulator
    @ObservedObject private var dev: AappDevServer
    init(firmware: FirmwareModel) {
        self.firmware = firmware
        console = firmware.console; aapp = firmware.portal; dev = firmware.dev
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                glasses
                HStack(spacing: 10) {
                    chip
                    Spacer()
                    Text("↑↓ / 滚轮 旋转 · 回车 / 空格 确认 · Esc 返回 · ⇧⌘Y 日志").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .frame(minHeight: 260)
            if console.visible {
                LogConsoleView(console: console).frame(minHeight: 120, idealHeight: 200)
            }
        }
        .frame(minWidth: 580, minHeight: 300)
        .preferredColorScheme(.dark)
        .background(DevKeyCatcher(aapp: aapp))
        .sheet(isPresented: Binding(get: { dev.pendingRequest != nil }, set: { if !$0 { dev.resolvePending(approve: false) } })) {
            PairingApprovalSheet(dev: dev)
        }
    }

    private var glasses: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let frame = aapp.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable().interpolation(.high).scaledToFit()
                        .accessibilityLabel("眼镜画面")
                        .gesture(SpatialTapGesture().onEnded { tap in
                            let size = CGSize(width: frame.width, height: frame.height)
                            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                            let origin = CGPoint(x: (geometry.size.width - size.width * scale) / 2, y: (geometry.size.height - size.height * scale) / 2)
                            aapp.sendTap(x: (tap.location.x - origin.x) / scale, y: (tap.location.y - origin.y) / scale)
                        })
                }
                if !aapp.connected {
                    VStack(spacing: 6) {
                        Text(placeholderTitle).font(.system(size: 20, weight: .medium))
                        Text(placeholderDetail).font(.callout).opacity(0.7)
                    }
                    .foregroundStyle(Color(red: 0.2, green: 1, blue: 0.4))
                    .multilineTextAlignment(.center).padding()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(CGFloat(aapp.width) / CGFloat(aapp.height), contentMode: .fit)
        .frame(minWidth: 540, minHeight: 220)
        .background(Color.black)
    }

    private var placeholderTitle: String {
        if dev.building { return "正在构建 \(dev.projectName ?? "工程")…" }
        if dev.buildFailed { return "构建失败" }
        if !aapp.running { return "眼镜模拟器未启动" }
        return aapp.connected || dev.paired ? "正在打开应用…" : "等待手机连接"
    }

    private var placeholderDetail: String {
        if dev.buildFailed { return "查看日志（⇧⌘Y），保存后会自动重试" }
        return dev.paired ? "" : "手机 Host → 开发工具 → 附近的电脑 → 连接"
    }

    private var chip: some View {
        // Connected = the phone Host drives the glasses picture (lvgl_host status); the dev link names the phone.
        let connected = aapp.connected
        let text = connected
            ? "已连接 · \(dev.deviceName ?? "手机") · \(dev.paired ? (dev.wired ? "有线" : "局域网") : "眼镜画面")"
            : (dev.building ? "构建中…" : (dev.paired ? "已连接开发服务 · \(dev.deviceName ?? "手机")" : "未连接"))
        return HStack(spacing: 6) {
            Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
            if let project = dev.projectName { Text("· \(project)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .foregroundStyle(connected ? Color.green : Color.primary)
    }
}

/// Number comparison, like Bluetooth pairing: the phone shows the same 6 digits.
struct PairingApprovalSheet: View {
    @ObservedObject var dev: AappDevServer
    var body: some View {
        VStack(spacing: 14) {
            Text("\(dev.pendingRequest?.deviceName ?? "手机") 请求连接").font(.headline)
            Text(spaced(dev.pendingRequest?.code ?? "")).font(.system(size: 36, weight: .semibold, design: .monospaced)).foregroundStyle(.green)
            Text("确认手机上显示的是同一组数字再允许。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("拒绝") { dev.resolvePending(approve: false) }.keyboardShortcut(.cancelAction)
                Button("允许") { dev.resolvePending(approve: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 360)
    }
    private func spaced(_ code: String) -> String { code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code }
}

/// Knob input for 开发模式: ↑↓ / scroll rotate, Return / Space confirm, Esc back, ← → as on the official simulator.
struct DevKeyCatcher: NSViewRepresentable {
    let aapp: PortalSimulator
    func makeNSView(context: Context) -> NSView {
        let view = CatcherView(); view.aapp = aapp
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CatcherView: NSView {
        weak var aapp: PortalSimulator?
        private var scrollAccumulator: CGFloat = 0
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            guard let aapp, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
            let key: PortalWire.Key?
            switch event.keyCode {
            case 126: key = .up
            case 125: key = .down
            case 123: key = .left
            case 124: key = .right
            case 36, 76, 49: key = event.isARepeat ? nil : .confirm   // Return, keypad Enter, Space
            case 53: key = event.isARepeat ? nil : .back
            case 51: key = event.isARepeat ? nil : .back               // Backspace (as in lvgl_host)
            case 115: key = event.isARepeat ? nil : .home              // Home
            default: key = nil
            }
            if let key { MainActor.assumeIsolated { aapp.sendKey(key) } } else if !event.isARepeat { super.keyDown(with: event) }
        }
        override func scrollWheel(with event: NSEvent) {
            scrollAccumulator += event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
            while abs(scrollAccumulator) >= threshold {
                let step: CGFloat = scrollAccumulator > 0 ? 1 : -1
                scrollAccumulator -= step * threshold
                if let aapp { MainActor.assumeIsolated { aapp.sendKey(step > 0 ? .up : .down) } }
            }
        }
    }
}
