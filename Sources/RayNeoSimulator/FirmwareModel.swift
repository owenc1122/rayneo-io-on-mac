import AppKit
import Darwin
import SwiftUI

/// Owns the live firmware process and displays only completed hardware scanouts.
@MainActor final class FirmwareModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var frame: NSImage?
    @Published private(set) var failure: String?
    private var process: Process?
    private var timer: Timer?
    private var lastFrame: Data?
    private var session: URL?
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func boot() {
        guard process == nil else { return }
        do {
            let files = FileManager.default
            let runtime = root.appendingPathComponent(".local/renode/Renode.app/Contents/MacOS/renode")
            let firmware = root.appendingPathComponent(".local/firmware.bin")
            guard files.isExecutableFile(atPath: runtime.path), files.fileExists(atPath: firmware.path) else {
                failure = "缺少本地运行环境或固件"; return
            }
            let staging = files.temporaryDirectory.appendingPathComponent("rayneo-\(UUID().uuidString)")
            let output = root.appendingPathComponent(".local/runs/ui-\(UUID().uuidString)")
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            try files.createDirectory(at: output, withIntermediateDirectories: true)
            session = staging
            let names = try String(contentsOf: root.appendingPathComponent("platform/peripherals.list"), encoding: .utf8).split(whereSeparator: \.isNewline)
            var commands: [String] = []
            for name in names {
                let filename = "\(name).cs"
                try files.createSymbolicLink(at: staging.appendingPathComponent(filename), withDestinationURL: root.appendingPathComponent("platform/peripherals/\(filename)"))
                commands.append("include @\(staging.path)/\(filename)")
            }
            for (name, source) in [("firmware.bin", firmware), ("board.repl", root.appendingPathComponent("platform/best1700.repl")), ("output", output)] {
                try files.createSymbolicLink(at: staging.appendingPathComponent(name), withDestinationURL: source)
            }
            commands.append("""
            mach create "RayNeo-AP"
            machine LoadPlatformDescription @\(staging.path)/board.repl
            sysbus LoadBinary @\(staging.path)/firmware.bin 0x10190000
            lcdc FrameImagePath "\(staging.path)/output/frame.pgm"
            logLevel 3 nvic
            cpu PerformanceInMips 200
            btc PerformanceInMips 100
            cpu SP 0x202fffe0
            cpu PC 0x10190010
            emulation RunFor "3600"
            quit
            """)
            let script = staging.appendingPathComponent("boot.resc")
            try commands.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
            let log = output.appendingPathComponent("boot.log")
            files.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            let task = Process()
            task.executableURL = runtime
            task.currentDirectoryURL = root
            task.arguments = ["--disable-gui", "--console", "--plain", "-e", "include @\(script.path)"]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = handle; task.standardError = handle
            task.terminationHandler = { [weak self] finished in
                try? handle.close()
                try? FileManager.default.removeItem(at: staging)
                Task { @MainActor in
                    guard let self else { return }
                    self.timer?.invalidate(); self.timer = nil
                    self.running = false; self.process = nil; self.session = nil
                    if finished.terminationStatus != 0 && finished.terminationReason != .uncaughtSignal {
                        self.failure = "固件运行已中断，日志已保存在本地"
                    }
                }
            }
            failure = nil; frame = nil; lastFrame = nil
            process = task
            try task.run()
            running = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readFrame(output.appendingPathComponent("frame.pgm")) }
            }
        } catch {
            if let session { try? FileManager.default.removeItem(at: session) }
            session = nil; process = nil; running = false
            failure = error.localizedDescription
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func readFrame(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data != lastFrame,
              let image = FirmwareFrame.decode(data) else { return }
        lastFrame = data
        frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// The emulator writes a fixed binary PGM header followed by unmodified luma bytes.
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
              bytes.count - third - 1 == values[0] * values[1],
              let provider = CGDataProvider(data: Data(bytes[(third + 1)...]) as CFData) else { return nil }
        return CGImage(width: values[0], height: values[1], bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: values[0], space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
