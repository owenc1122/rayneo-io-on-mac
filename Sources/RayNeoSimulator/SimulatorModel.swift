import AppKit
import SwiftUI
import NavigationCore
import UniformTypeIdentifiers

@MainActor
final class SimulatorModel: ObservableObject {
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "zh" {
        didSet { UserDefaults.standard.set(language, forKey: "language"); render() }
    }
    func tr(_ zh: String, _ en: String) -> String { language == "zh" ? zh : en }
    @Published var frame: NSImage?
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0
    @Published var playing = false
    @Published var page = "Navigation"
    @Published var selection = 0
    @Published var status = "Demo · synthetic map"
    @Published var error: String?
    @Published var scale = "2.00 m/px"
    @Published var watched: URL?
    private let core: OpaquePointer
    private var scene = SGNScene()
    private var base = SGNScene()
    private var sequence: UInt32 = 0
    private var timer: Timer?
    private var lastData: Data?
    private var ticks = 0
    private var elapsed = 0.0
    private let start = ProcessInfo.processInfo.systemUptime
    var now: UInt32 { UInt32(truncatingIfNeeded: UInt64((ProcessInfo.processInfo.systemUptime-start)*1000)) }

    init() {
        guard let core = rn_create() else { fatalError("Cannot allocate renderer") }; self.core = core
        loadDemo()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    deinit { timer?.invalidate(); rn_destroy(core) }

    func loadDemo() {
        watched = nil; lastData = nil; error = nil; elapsed = 0; playing = false
        var s = SGNScene(); s.road = "Museum Ave"; s.instr = "Turn right"; s.eta = "14:35"; s.maneuverDistM = 120; s.remainDistM = 850; s.icon = 3
        s.route = [.init(x: 0,y: -180), .init(x: 0,y: 240), .init(x: 400,y: 240)]; s.man = s.route[1]
        s.roads = [SGNRoad(cls: 2, points: [.init(x: -700,y: 240), .init(x: 700,y: 240)]),
                   SGNRoad(cls: 1, points: [.init(x: 0,y: -320), .init(x: 0,y: 560)]),
                   SGNRoad(cls: 1, points: [.init(x: -460,y: -280), .init(x: -460,y: 480)]),
                   SGNRoad(cls: 1, points: [.init(x: 360,y: -240), .init(x: 360,y: 520)])]
        s.features = [SGNFeature(kind: 1, point: .init(x: -50,y: 220)), SGNFeature(kind: 2, point: .init(x: 370,y: 280)),
                      SGNFeature(kind: 3, point: .init(x: -520,y: 180), name: "Museum"), SGNFeature(kind: 3, point: .init(x: 280,y: 140), name: "Library"),
                      SGNFeature(kind: 3, point: .init(x: -420,y: 0), name: "自然历史博物馆")]
        base = s; scene = s; page = "Navigation"; rn_reset(core); send(); tick()
        status = "Demo · synthetic map"
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, UTType(filenameExtension: "sgn") ?? .data]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; watch(url)
    }
    func watch(_ url: URL) {
        watched = url; lastData = nil; playing = false; elapsed = 0; reload()
    }
    private func reload() {
        guard let url = watched else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw ScenarioError.invalid("Scene file exceeds 1 MB") }
            let data = try Data(contentsOf: url)
            guard data != lastData else { return }
            let candidate: SGNScene
            if url.pathExtension.lowercased() == "sgn" {
                var header = SGHeader()
                let valid = data.withUnsafeBytes { sg_header($0.bindMemory(to: UInt8.self).baseAddress, data.count, &header) }
                guard valid, let decoded = SGN1.decodeScene(packet: data) else { throw ScenarioError.invalid("Expected a valid SGN1 SCENE packet") }
                candidate = decoded
            } else { candidate = try JSONDecoder().decode(Scenario.self, from: data).scene() }
            scene = candidate; base = candidate; send(); lastData = data; error = nil; page = "Navigation"
            status = "Live file · \(url.lastPathComponent)"
        } catch { self.error = "\(error.localizedDescription) · Keeping last valid frame" }
    }
    private func send() {
        do {
            sequence &+= 1; scene.tMs = now
            let packet = try SGN1.scenePacket(scene, sid: 1, seq: sequence)
            let result = packet.withUnsafeBytes { rn_receive(core, $0.bindMemory(to: UInt8.self).baseAddress, packet.count, now) }
            if result != 0 { throw ScenarioError.invalid("Renderer rejected scene (\(result))") }
        } catch { self.error = error.localizedDescription }
    }
    private func tick() {
        ticks += 1
        if ticks % 10 == 0 { reload() }
        if playing && watched == nil && page == "Navigation" {
            elapsed += 1.0/30
            let metres = (elapsed*5).truncatingRemainder(dividingBy: 110)
            scene.pos.y = base.pos.y + Int16(metres*2); scene.maneuverDistM = UInt32(max(0,Double(base.maneuverDistM)-metres)); send()
        }
        rn_orientation(core, Float(yaw), now)
        render()
        scale = String(format: "%.2f m/px", rn_mpp(core))
    }
    func crown(_ delta: Int) {
        if page == "Home" { selection = (selection + delta + 2) % 2 }
        else if page == "Navigation" { rn_zoom(core, Int32(delta), now) }
        render()
    }
    func press() { if page == "Home" { page = selection == 0 ? "Navigation" : "Official AI" }; render() }
    func back() { page = "Home"; render() }
    func ai() { page = "Official AI"; render() }
    func recenter() { yaw = 0; pitch = 0; roll = 0; rn_reset(core); tick() }

    private func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, height: CGFloat = 22) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(calibratedRed: 0.12, green: 1, blue: 0.28, alpha: 1), .paragraphStyle: style])
    }
    private func render() {
        guard let pixels = rn_draw(core, now) else { return }
        let data = Data(bytes: pixels, count: 512*128)
        guard let provider = CGDataProvider(data: data as CFData), let cg = CGImage(width: 512,height: 128,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: 512,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGBitmapInfo(rawValue: 0),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else { return }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 2048, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: 128)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSColor.black.setFill(); NSRect(x: 0,y: 0,width: 512,height: 128).fill()
        if page == "Navigation" {
            NSImage(cgImage: cg, size: NSSize(width: 512,height: 128)).draw(in: NSRect(x: 0,y: 0,width: 512,height: 128), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSColor(calibratedRed: 0.12, green: 1, blue: 0.28, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 512, height: 128).fill(using: .multiply)
            var distance = [CChar](repeating: 0,count: 32); sg_fmt_distance(&distance,32,scene.maneuverDistM)
            text(String(cString: distance),x: 50,y: 2,width: 98,size: 29,weight: .semibold,height: 40)
            text(watched == nil ? tr("右转", "Turn right") : scene.instr,x: 4,y: 48,width: 142,size: 17,height: 40)
            text(scene.road,x: 4,y: 89,width: 142,size: 15)
            text("\(scene.remainDistM)m  \(scene.eta)",x: 4,y: 109,width: 142,size: 14)
            var labels = [SGFeatureLabel](repeating: SGFeatureLabel(),count: 8)
            let count = rn_labels(core,&labels)
            for i in 0..<Int(count) where labels[i].kind == 3 {
                var f = labels[i]
                let value = withUnsafePointer(to: &f.text) { $0.withMemoryRebound(to: CChar.self,capacity: 32) { String(cString: $0) } }
                text(value,x: CGFloat(f.x+3),y: CGFloat(f.y),width: CGFloat(f.w-6),size: 13)
            }
        } else if page == "Home" {
            text("\(selection == 0 ? "›" : " ")  \(tr("导航", "Navigation"))",x: 24,y: 25,width: 450,size: 23,weight: .medium,height: 32)
            text("\(selection == 1 ? "›" : " ")  \(tr("原版 AI", "Official AI"))",x: 24,y: 70,width: 450,size: 23,weight: .medium,height: 32)
        } else {
            text(tr("原版 RayNeo AI", "Official RayNeo AI"),x: 24,y: 25,width: 464,size: 23,weight: .medium,height: 32)
            text(tr("运行于眼镜 · 原版界面尚未模拟", "Runs on glasses · proprietary UI is not emulated"),x: 24,y: 72,width: 464,size: 15)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 512, height: 128)); image.addRepresentation(bitmap); frame = image
    }
    func exportPNG() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "rayneo-preview.png"
        if panel.runModal() == .OK, let url = panel.url { savePNG(url) }
    }
    func savePNG(_ url: URL) {
        guard let data = frame?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png,properties: [:]) else { error = "Cannot encode preview"; return }
        do { try png.write(to: url,options: .atomic) } catch { self.error = error.localizedDescription }
    }
}
