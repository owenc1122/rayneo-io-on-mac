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
        .defaultSize(width: 1024, height: 300)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct SimulatorView: View {
    @ObservedObject var firmware: FirmwareModel
    var body: some View {
        ZStack {
            Color.black
            if let frame = firmware.frame {
                Image(nsImage: frame)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .accessibilityLabel("原固件显示缓冲区画面")
            } else {
                Text(firmware.failure ?? "系统启动中")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 512, minHeight: 128)
        .preferredColorScheme(.dark)
        .onDisappear { firmware.stop() }
    }
}
