import CoreGraphics
import Foundation

/// One Host connection's protocol state: handshake, render session, resources, drawFrame/micro rendering and
/// input. Pure (no sockets): `handle` takes a packet and returns the packets to send back, so it is unit-testable.
/// Confined to the server's queue.
final class AappSession {
    struct Output {
        var replies: [AappPacket] = []
        var frame: CGImage??          // .some(nil) = display cleared
        var closeConnection = false
    }

    enum Event {
        case hello
        case opened(name: String, appId: String, mode: String)
        case closed
        case log(String)
    }

    let width: Int, height: Int
    let name: String
    var onEvent: (Event) -> Void = { _ in }

    private(set) var renderSession: UInt32 = 0
    private(set) var renderMode = "drawFrame"
    private(set) var appName: String?
    private(set) var appId: String?
    private(set) var inputSession: UInt64?
    private var inputSequence: UInt32 = 0
    private let resources = AappResources()
    private let streams = AappStreamResources()
    private let micro = MicroTree()
    private var frames = 0
    private var framesSinceStats = 0
    private var renderTime: Double = 0
    private var statsStart = Date()
    private var warned: Set<String> = []

    init(width: Int = 540, height: Int = 220, name: String = "RayNeo io on Mac") {
        self.width = width; self.height = height; self.name = name
        micro.warn = { [weak self] in self?.warnOnce($0) }
        streams.log = { [weak self] in self?.log($0) }
        streams.onBind = { [weak self] id, data, image in
            if let data { self?.resources.store(id, data) } else if let image { self?.resources.store(id, image: image) }
        }
        micro.imageSize = { [weak self] id in
            guard let image = self?.resources.image(id) else { return nil }
            return CGSize(width: image.width, height: image.height)
        }
    }

    /// The hello reply. `renderModes` must include "micro" with microCommand/uiEvent version 1, or the Host
    /// refuses the simulator; features not implemented here are advertised as version 0.
    var helloReply: [String: Any] {
        ["name": name, "width": width, "height": height,
         "inputEventVersion": 1, "inputEnvelopeVersion": 1, "drawFrameVersion": 2,
         "renderModes": ["drawFrame", "micro"], "microCommandVersion": 1, "uiEventVersion": 1,
         "nodeAnimationVersion": 0, "lottieVersion": 0, "groupOpacityVersion": 1,
         // ASR/1 image replication (network images in micro mode). Formats bitmask: PNG, JPEG, RGBA8888, RGB565.
         "streamResourceVersion": 1, "streamResourceMaxFrameBytes": AappStreamResources.maxFrameBytes,
         "streamResourceBudgetBytes": AappStreamResources.budgetBytes,
         "imageResourceDescriptorVersion": 1, "imageResourceFormats": 15, "imageResourceMaxBytes": 4 << 20,
         "imageResourceMaxDecodedBytes": 8 << 20, "imageResourceMaxWidth": 2048, "imageResourceMaxHeight": 2048]
    }

    private func log(_ s: String) { onEvent(.log(s)) }
    private func warnOnce(_ s: String) { if warned.insert(s).inserted, warned.count < 200 { log("⚠︎ " + s) } }

    func handle(_ packet: AappPacket) -> Output {
        var out = Output()
        func ack(_ object: [String: Any] = [:]) {
            out.replies.append(AappPacket(.ack, session: packet.session, request: packet.request, payload: AappPacket.json(object)))
        }
        func fail(_ message: String) {
            log("✗ \(AappMessage(rawValue: packet.type).map { "\($0)" } ?? "类型 \(packet.type)")：\(message)")
            out.replies.append(AappPacket(.error, session: packet.session, request: packet.request, payload: AappPacket.json(["message": message])))
        }
        guard let message = packet.message else { fail("Unsupported message type \(packet.type)"); return out }
        switch message {
        case .hello:
            if let json = try? JSONSerialization.jsonObject(with: packet.payload) as? [String: Any] {
                log("Host 握手：input \(json["inputEventVersion"] ?? "?")/\(json["inputEnvelopeVersion"] ?? "?")")
            }
            onEvent(.hello)
            ack(helloReply)
        case .open:
            let json = (try? JSONSerialization.jsonObject(with: packet.payload) as? [String: Any]) ?? [:]
            renderSession = packet.session
            appName = json["name"] as? String; appId = json["appId"] as? String
            renderMode = (json["renderMode"] as? String) ?? "drawFrame"
            micro.reset(); streams.reset(); frames = 0; framesSinceStats = 0; renderTime = 0; statsStart = Date(); warned.removeAll()
            inputSession = nil; inputSequence = 0
            log("打开应用「\(appName ?? "?")」(\(appId ?? "?"))，渲染模式 \(renderMode == "micro" ? "流畅 micro" : "普通 drawFrame")，会话 \(packet.session)")
            onEvent(.opened(name: appName ?? "", appId: appId ?? "", mode: renderMode))
            ack()
            out.frame = .some(blankFrame())
        case .close:
            log("关闭应用「\(appName ?? "?")」")
            appName = nil; appId = nil; micro.reset(); inputSession = nil
            onEvent(.closed)
            ack()
            out.frame = .some(nil)
        case .resource, .lottieResource:
            do {
                var r = AappReader(packet.payload)
                let id = try r.string(max: 4096)
                let bytes = Data(packet.payload[r.offset...])
                resources.store(id, bytes)
                log("资源 \(id)（\(bytes.count) 字节）\(message == .lottieResource ? "，Lottie 暂不渲染" : "")")
                ack()
                if renderMode == "micro" { out.frame = .some(renderMicro()) }
            } catch { fail("Invalid resource payload: \(error)") }
        case .releaseResource:
            if let json = try? JSONSerialization.jsonObject(with: packet.payload) as? [String: Any], let id = json["id"] as? String {
                resources.remove(id)
            }
            ack()
        case .clearResources:
            resources.removeAll(); ack()
        case .frame:
            let start = Date()
            do {
                let frame = try ADRFDecoder.decode(packet.payload)
                guard let image = AappCanvas.render(frame, width: width, height: height, resources: resources, warn: warnOnce) else {
                    fail("Render failed"); return out
                }
                frames += 1
                noteFrame(start)
                if frames == 1 { log("第一帧：\(frame.commands.count) 条绘制命令，\(packet.payload.count) 字节") }
                ack(["frame": frames, "status": "submitted"])
                out.frame = .some(image)
            } catch { fail("\(error)") }
        case .clear:
            ack(); out.frame = .some(blankFrame())
        case .ping:
            ack()
        case .ack:
            break   // acks of our pushes (remoteInputState is not advertised, so none expected)
        case .microCommands:
            let start = Date()
            do {
                let commands = try MicroCommand.parse(packet.payload)
                micro.apply(commands)
                ack()
                flushComponentEvents(&out)
                let image = renderMicro()
                frames += 1
                noteFrame(start)
                if frames == 1 { log("micro 第一帧：\(commands.count) 条命令，\(micro.nodes.count) 个节点") }
                out.frame = .some(image)
            } catch { fail("Invalid micro commands: \(error)") }
        case .inputControl:
            do {
                let request = try AappInputEnvelope.decode(packet.payload)
                let reply: AappInputEnvelope
                switch AappInputEnvelope.Op(rawValue: request.opcode) {
                case .capabilities:
                    reply = .reply(to: request, code: .ok, data: AappInputEnvelope.capabilitiesNoImu)
                case .open:
                    inputSession = request.sessionId; inputSequence = 0
                    log("输入通道已打开（会话 \(request.sessionId)）")
                    reply = .reply(to: request, code: .ok)
                case .close:
                    if inputSession == request.sessionId { inputSession = nil }
                    reply = .reply(to: request, code: .ok)
                case .acquire:
                    warnOnce("应用请求 IMU，模拟器暂不提供（UNSUPPORTED）")
                    reply = .reply(to: request, code: .unsupported)
                case .release, .renew:
                    reply = .reply(to: request, code: .ok)
                default:
                    reply = .reply(to: request, code: .invalidArgument)
                }
                out.replies.append(AappPacket(.inputControl, session: packet.session, request: packet.request, payload: reply.encoded()))
            } catch { fail("\(error)") }
        case .streamResource:
            let reply = streams.handle(packet.payload)
            out.replies.append(AappPacket(.ack, session: packet.session, request: packet.request, payload: reply))
            if renderMode == "micro" && reply.count > 5 && reply[reply.startIndex + 5] == 0x95 { out.frame = .some(renderMicro()) }
        case .remoteInput:
            fail("remoteInput unsupported")
        case .error, .input, .uiEvents, .remoteInputState, .reserved15:
            fail("Unexpected message \(message)")
        }
        return out
    }

    private func noteFrame(_ start: Date) {
        framesSinceStats += 1
        renderTime += Date().timeIntervalSince(start)
        let elapsed = Date().timeIntervalSince(statsStart)
        if elapsed >= 10 {
            log(String(format: "帧统计：%.1f 帧/秒，平均绘制 %.1f ms（共 %d 帧）", Double(framesSinceStats) / elapsed, renderTime / Double(framesSinceStats) * 1000, frames))
            framesSinceStats = 0; renderTime = 0; statsStart = Date()
        }
    }

    private func blankFrame() -> CGImage? { AappCanvas.makeContext(width: width, height: height)?.makeImage() }

    private func renderMicro() -> CGImage? {
        guard let ctx = AappCanvas.makeContext(width: width, height: height) else { return nil }
        guard micro.isActive, let root = micro.root, let rootNode = micro.nodes[root] else { return ctx.makeImage() }
        if let bg = MicroTree.color(rootNode.props["background"]) { ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        micro.layout(width: CGFloat(width), height: CGFloat(height))
        micro.normaliseFocus()
        micro.paint(in: ctx, resources: resources)
        return ctx.makeImage()
    }

    /// Sends queued component events (WheelPicker `wheel` changes) as one `uiEvents` batch.
    private func flushComponentEvents(_ out: inout Output) {
        guard !micro.pendingComponentEvents.isEmpty, renderSession != 0 else { micro.pendingComponentEvents.removeAll(); return }
        let events = micro.pendingComponentEvents.map { AappUIEvents.Event.component($0.0, $0.1, $0.2) }
        micro.pendingComponentEvents.removeAll()
        for chunk in stride(from: 0, to: events.count, by: 32) {
            out.replies.append(AappPacket(.uiEvents, session: renderSession, request: 0, payload: AappUIEvents.batch(Array(events[chunk..<min(chunk + 32, events.count)]))))
        }
    }

    // MARK: input from the simulator window

    /// Packets for a key press. In micro mode arrows move focus and Enter clicks the focused node (a `uiEvents`
    /// click, like the official simulator); other keys, and every key in drawFrame mode, go to the app as
    /// InputEventBatch key events. The returned frame is the repainted focus state, if it changed.
    func key(_ key: AappKey) -> Output {
        var out = Output()
        guard renderSession != 0 else { log("按键 \(key.code) 忽略：没有打开的应用"); return out }
        if renderMode == "micro" && micro.isActive {
            if micro.wheelKey(key) { flushComponentEvents(&out); out.frame = .some(renderMicro()); return out }
            switch key {
            case .up, .left, .down, .right:
                if micro.moveFocus(key == .up || key == .left ? -1 : 1) { out.frame = .some(renderMicro()); return out }
            case .enter:
                micro.normaliseFocus()
                if let id = micro.focused, let node = micro.nodes[id], node.events.contains("click") {
                    log("点击节点 \(id)（\(node.type)）")
                    out.replies.append(AappPacket(.uiEvents, session: renderSession, request: 0, payload: AappUIEvents.click(node: id, key: "click")))
                    return out
                }
            default: break
            }
        }
        if let push = inputPush(AappInputBatch.keys([key.code])) { out.replies.append(push) }
        return out
    }

    /// A tap at display coordinates (mouse click on the display).
    func tap(x: Double, y: Double) -> Output {
        var out = Output()
        guard renderSession != 0 else { return out }
        if renderMode == "micro" && micro.isActive {
            // Click the deepest focusable/clickable node under the point.
            if let hit = micro.focusables().last(where: { $0.frame.contains(CGPoint(x: x, y: y)) }) {
                if hit.events.contains("click") {
                    out.replies.append(AappPacket(.uiEvents, session: renderSession, request: 0, payload: AappUIEvents.click(node: hit.id, key: "click")))
                }
                return out
            }
        }
        if let push = inputPush(AappInputBatch.touch(phase: 0, pointer: 0, x: Float(x), y: Float(y))) { out.replies.append(push) }
        return out
    }

    private func inputPush(_ batch: Data) -> AappPacket? {
        guard let inputSession else { warnOnce("输入通道尚未打开，按键未发送"); return nil }
        inputSequence &+= 1
        if inputSequence == 0 { inputSequence = 1 }
        let envelope = AappInputEnvelope(opcode: AappInputEnvelope.Op.batch.rawValue, requestId: 0, sessionId: inputSession,
                                         sequence: inputSequence, body: batch)
        return AappPacket(.input, session: renderSession, request: 0, payload: envelope.encoded())
    }
}
