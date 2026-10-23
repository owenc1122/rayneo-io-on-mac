import CryptoKit
import Foundation
import Network

/// Server side of `aapp-dev.v3`. Lives on its own serial queue; reports to the main-actor facade through
/// `events`. Bounded: ≤ 8 device connections, ≤ 200 buffered SSE events each, ≤ 3 packages kept for download.
final class AappDevCore {
    enum Event {
        case log(String, Bool)
        case state(paired: Bool, device: String?, status: String)
        case deployed(String)
    }

    struct Package {
        let url: URL
        let data: Data              // memory-mapped
        let manifest: [String: Any]
        let deployment: AappDevProtocol.Deployment
    }

    private final class Device {
        let id: String
        let token: String           // bearer for this connection's requests
        let credential: String      // long-lived, sent in welcome; reconnects register with it
        let appId: String
        let deviceId: String
        let deviceName: String
        var seq = 0
        var buffered: [(Int, Data)] = []
        var stream: AappDevHTTPConnection?
        var lastSeen = Date()
        var sessionReady = false
        var reportedBuilds: Set<String> = []
        init(id: String, token: String, credential: String, appId: String, deviceId: String, deviceName: String) {
            self.id = id; self.token = token; self.credential = credential
            self.appId = appId; self.deviceId = deviceId; self.deviceName = deviceName
        }
    }

    /// What survives an app restart, so a paired phone reconnects by itself (DevTools keeps endpoint + credential).
    private struct Saved: Codable {
        var serverId: String
        var credentials: [String: String]     // credential -> appId
        var generation: Int
        var manifest: Data?
    }

    let queue = DispatchQueue(label: "aapp.devserver")
    let port: UInt16
    var emit: ((Event) -> Void)?

    private var tls: AappDevTLS?
    private var listener: NWListener?
    private var httpConnections: [UUID: AappDevHTTPConnection] = [:]
    private var devices: [String: Device] = [:]
    private var saved: Saved
    private var pairing: AappDevProtocol.Pairing?
    private var manifest: [String: Any]?
    private var packages: [String: Package] = [:]          // deploymentId -> package
    private var packageOrder: [String] = []
    private var current: Package?
    private var watchTimer: DispatchSourceTimer?
    private var watched: (dir: URL, signature: String, stableSince: Date?, deployedSignature: String)?
    private var housekeeping: DispatchSourceTimer?
    private let stateFile: URL

    init(port: UInt16, directory: URL = AappDevTLS.directory) {
        self.port = port
        stateFile = directory.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(Saved.self, from: data),
           state.serverId.count == 32 {
            saved = state
        } else {
            saved = Saved(serverId: AappDevProtocol.randomHex(bytes: 16), credentials: [:], generation: 0, manifest: nil)
        }
        if let data = saved.manifest { manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    }

    // MARK: lifecycle

    func start() throws {
        let identity = try AappDevTLS.load()
        tls = identity
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: identity.parameters(), on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.log("开发服务已启动：https://0.0.0.0:\(self.port)/dev（证书指纹 \(AappDevProtocol.hex(identity.fingerprint).prefix(16))…）")
                self.publish()
            case .failed(let error): self.log("开发服务启动失败：\(error)（端口 \(self.port) 被占用？）", error: true)
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        housekeeping = timer
    }

    func stop() {
        queue.async { [self] in
            for device in devices.values { enqueue(device, ["type": "session.end"]); device.stream?.endStream() }
            devices.removeAll()
            listener?.cancel(); listener = nil
            httpConnections.values.forEach { $0.cancel() }; httpConnections.removeAll()
            housekeeping?.cancel(); housekeeping = nil
            watchTimer?.cancel(); watchTimer = nil
            publish()
        }
    }

    // MARK: pairing

    /// The pairing for `host` (refreshed when missing, expired or for another host). Needs an app manifest.
    func pairing(host: String) -> AappDevProtocol.Pairing? {
        queue.sync {
            guard let tls, let manifest else { return nil }
            if let pairing, pairing.host == host, pairing.expiresAt.timeIntervalSinceNow > 60,
               NSDictionary(dictionary: pairing.manifest).isEqual(to: manifest) { return pairing }
            let fresh = AappDevProtocol.Pairing(host: host, port: port, certificateSHA256: tls.fingerprint,
                                                token: AappDevProtocol.randomToken(), serverId: saved.serverId,
                                                computer: Host.current().localizedName ?? "Mac", manifest: manifest,
                                                expiresAt: Date().addingTimeInterval(600))
            pairing = fresh
            return fresh
        }
    }

    // MARK: deploy

    func deploy(_ url: URL) {
        queue.async { [self] in
            do { try deployNow(url) } catch { log("部署失败：\(error.localizedDescription)", error: true) }
        }
    }

    private func deployNow(_ url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0, size <= AappDevProtocol.maxPackageBytes else { throw AapkReader.Failure.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let manifest = try AapkReader.manifest(of: url)
        guard let appId = manifest["package"] as? String, !appId.isEmpty, appId.count <= 128,
              let version = manifest["version"] as? String, !version.isEmpty, version.count <= 64 else {
            throw AapkReader.Failure.missing("aapp.json 的 package / version")
        }
        if let previous = self.manifest?["package"] as? String, previous != appId {
            log("换了应用（\(previous) → \(appId)）：手机需要重新配对", error: true)
            for device in devices.values { enqueue(device, ["type": "session.end"]) }
            devices.removeAll()
            saved.credentials = [:]
            pairing = nil
        }
        if self.manifest == nil || !NSDictionary(dictionary: self.manifest!).isEqual(to: manifest) { pairing = nil }
        self.manifest = manifest
        saved.manifest = AappDevProtocol.json(manifest)
        saved.generation += 1
        let sha = AappDevProtocol.hex(Data(SHA256.hash(data: data)))
        let deployment = AappDevProtocol.Deployment(
            deploymentId: "d" + AappDevProtocol.randomHex(bytes: 8), buildId: "b\(saved.generation)-\(sha.prefix(8))",
            appId: appId, version: version, sha256: sha, bytes: data.count,
            transferId: UInt32.random(in: 1...UInt32.max), generation: saved.generation)
        save()
        let package = Package(url: url, data: data, manifest: manifest, deployment: deployment)
        packages[deployment.deploymentId] = package
        packageOrder.append(deployment.deploymentId)
        while packageOrder.count > 3 { packages[packageOrder.removeFirst()] = nil }
        current = package
        log("准备部署 \(appId) \(version)（\(url.lastPathComponent)，\(data.count) 字节，构建 \(deployment.buildId)）")
        emit?(.deployed("\(appId) \(version) · \(deployment.buildId)"))
        let ready = devices.values.filter { $0.sessionReady && $0.appId == appId }
        if ready.isEmpty { log(devices.isEmpty ? "等手机配对后自动安装（设备 → 配对手机）" : "等手机连上后自动安装") }
        for device in ready { sendDeploy(to: device) }
        publish()
    }

    private func sendDeploy(to device: Device) {
        guard let current, current.deployment.appId == device.appId else { return }
        enqueue(device, current.deployment.event)
        log("已通知 \(device.deviceName) 安装构建 \(current.deployment.buildId)")
    }

    func command(_ type: String) {
        queue.async { [self] in
            let live = devices.values.filter { $0.stream != nil }
            guard !live.isEmpty else { log("没有已连接的手机", error: true); return }
            for device in live {
                let requestId = "r" + AappDevProtocol.randomHex(bytes: 8)
                enqueue(device, ["type": type, "requestId": requestId,
                                 "expiresAt": Int64(Date().addingTimeInterval(30).timeIntervalSince1970 * 1000)])
                log("\(type == "app.stop" ? "停止" : "重新启动")应用 → \(device.deviceName)（\(requestId)）")
            }
        }
    }

    // MARK: project watching (save-to-reload)

    /// Watches `<dir>/build/*.aapk` (or `<dir>/*.aapk`): a new or changed package, stable for 0.8 s, is deployed.
    func watch(_ directory: URL) {
        queue.async { [self] in
            watchTimer?.cancel()
            watched = (directory, "", nil, signature(of: directory).1)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.pollWatched() }
            timer.resume()
            watchTimer = timer
            log("监视 \(directory.path) 的构建输出（build/*.aapk），有新包就自动部署")
            let (url, sig) = signature(of: directory)
            if let url, !sig.isEmpty {
                do { try deployNow(url) } catch { log("部署失败：\(error.localizedDescription)", error: true) }
            } else {
                log("还没有构建输出：在项目目录运行 npm run build 后会自动部署")
            }
        }
    }

    private func signature(of directory: URL) -> (URL?, String) {
        let files = FileManager.default
        var candidates: [URL] = []
        for dir in [directory.appendingPathComponent("build"), directory] {
            candidates += (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))?
                .filter { $0.pathExtension == "aapk" } ?? []
        }
        let newest = candidates.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        guard let newest, let values = try? newest.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return (nil, "") }
        return (newest, "\(newest.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
    }

    private func pollWatched() {
        guard var state = watched else { return }
        let (url, sig) = signature(of: state.dir)
        defer { watched = state }
        guard let url, !sig.isEmpty, sig != state.deployedSignature else { state.signature = sig; state.stableSince = nil; return }
        if sig != state.signature { state.signature = sig; state.stableSince = Date(); return }
        guard let since = state.stableSince, Date().timeIntervalSince(since) >= 0.8 else { return }
        state.deployedSignature = sig
        state.stableSince = nil
        log("检测到新构建：\(url.lastPathComponent)")
        do { try deployNow(url) } catch { log("部署失败：\(error.localizedDescription)", error: true) }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard httpConnections.count < 32 else { connection.cancel(); return }
        let http = AappDevHTTPConnection(connection, queue: queue)
        httpConnections[http.id] = http
        http.onRequest = { [weak self] request, http in self?.route(request, http) }
        http.onClose = { [weak self] http in
            guard let self else { return }
            self.httpConnections[http.id] = nil
            for device in self.devices.values where device.stream === http { device.stream = nil; self.publish() }
        }
        http.start()
    }

    private func route(_ request: AappDevRequest, _ http: AappDevHTTPConnection) {
        let parts = request.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        // /dev/pairing/describe
        if parts == ["dev", "pairing", "describe"], request.method == "POST" {
            guard let pairing, request.bearer == pairing.token, pairing.expiresAt > Date() else {
                http.respond(401, json: AappDevProtocol.errorBody("Pairing code is invalid or expired")); return
            }
            http.respond(200, json: AappDevProtocol.json(["ticket": pairing.full]))
            log("手机正在读取配对信息…")
            return
        }
        // /dev/device-connections
        if parts == ["dev", "device-connections"], request.method == "POST" { register(request, http); return }
        guard parts.count >= 4, parts[0] == "dev", parts[1] == "device-connections", let device = devices[parts[2]] else {
            http.respond(404, json: AappDevProtocol.errorBody("Unknown developer connection")); return
        }
        guard request.bearer == device.token else { http.respond(401, json: AappDevProtocol.errorBody("Unauthorized")); return }
        device.lastSeen = Date()
        switch (request.method, Array(parts[3...])) {
        case ("GET", ["events"]):
            let after = Int(request.query["after"] ?? "0") ?? 0
            device.stream?.endStream()
            device.stream = http
            http.beginStream()
            for (seq, frame) in device.buffered where seq > after { http.streamWrite(frame) }
            log("手机 \(device.deviceName) 已连上事件通道")
            publish()
        case ("POST", ["heartbeat"]):
            http.respond(200, json: AappDevProtocol.json(["ok": true]))
        case ("POST", ["telemetry"]):
            guard let body = request.jsonBody() else { http.respond(400, json: AappDevProtocol.errorBody("Bad JSON")); return }
            http.respond(200, json: AappDevProtocol.json(["ok": true]))
            telemetry(body, from: device)
        case ("POST", let rest) where rest.count == 3 && rest[0] == "commands" && rest[2] == "result":
            let body = request.jsonBody() ?? [:]
            http.respond(200, json: AappDevProtocol.json(["ok": true]))
            for (line, isError) in AappDevProtocol.describeTelemetry(body.merging(["type": "command.result"]) { a, _ in a }) { log(line, error: isError) }
        case ("DELETE", ["connection"]):
            http.respond(200, json: AappDevProtocol.json(["ok": true]))
            devices[device.id] = nil
            device.stream?.endStream()
            log("手机 \(device.deviceName) 断开了开发连接")
            publish()
        case ("GET", let rest) where rest.count == 3 && rest[0] == "deployments" && rest[2] == "content":
            guard let package = packages[rest[1]] else { http.respond(410, json: AappDevProtocol.errorBody("Deployment is gone")); return }
            let size = package.data.count
            guard let range = AappDevProtocol.parseRange(request.headers["range"], size: size) else {
                http.respond(416, body: Data(), contentType: "application/octet-stream", extraHeaders: ["Content-Range": "bytes */\(size)"]); return
            }
            http.respond(206, body: package.data.subdata(in: range.lowerBound..<(range.upperBound + 1)), contentType: "application/octet-stream",
                         extraHeaders: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(size)", "Accept-Ranges": "bytes"])
            if range.upperBound == size - 1 { log("手机已下载完整个应用包（\(size) 字节）") }
        default:
            http.respond(404, json: AappDevProtocol.errorBody("Not found"))
        }
    }

    private func register(_ request: AappDevRequest, _ http: AappDevHTTPConnection) {
        guard let body = request.jsonBody(), let bearer = request.bearer else {
            http.respond(400, json: AappDevProtocol.errorBody("Bad request")); return
        }
        let viaPairing = pairing.map { bearer == $0.token && $0.expiresAt > Date() } ?? false
        let credentialApp = saved.credentials[bearer]
        guard viaPairing || credentialApp != nil else {
            http.respond(401, json: AappDevProtocol.errorBody("Pairing expired; pair again on the computer")); return
        }
        guard body["protocol"] as? String == AappDevProtocol.version, body["serverId"] as? String == saved.serverId else {
            http.respond(409, json: AappDevProtocol.errorBody("Wrong developer server")); return
        }
        let appId = String((body["appId"] as? String ?? "").prefix(128))
        guard appId == (manifest?["package"] as? String), credentialApp == nil || credentialApp == appId else {
            http.respond(409, json: AappDevProtocol.errorBody("This computer is serving another app; pair again")); return
        }
        let deviceId = String((body["deviceId"] as? String ?? "phone").prefix(128))
        let deviceName = String((body["deviceName"] as? String ?? "手机").prefix(128))
        // One live connection per phone: a reconnect replaces the old one.
        for old in devices.values where old.deviceId == deviceId { old.stream?.endStream(); devices[old.id] = nil }
        while devices.count >= 8, let oldest = devices.values.min(by: { $0.lastSeen < $1.lastSeen }) { oldest.stream?.cancel(); devices[oldest.id] = nil }
        let credential = credentialApp != nil ? bearer : AappDevProtocol.randomToken()
        if credentialApp == nil {
            saved.credentials[credential] = appId
            if saved.credentials.count > 16 { saved.credentials.remove(at: saved.credentials.startIndex) }
            save()
        }
        let device = Device(id: AappDevProtocol.randomHex(bytes: 16), token: AappDevProtocol.randomToken(),
                            credential: credential, appId: appId, deviceId: deviceId, deviceName: deviceName)
        devices[device.id] = device
        http.respond(200, json: AappDevProtocol.json(["token": device.token, "connectionId": device.id, "afterSeq": 0]))
        enqueue(device, ["type": "welcome", "protocol": AappDevProtocol.version, "serverId": saved.serverId,
                         "token": credential, "capabilities": ["display-status.v1"]])
        log(viaPairing ? "手机 \(deviceName) 已配对（\(appId)）" : "手机 \(deviceName) 重新连上")
        publish()
    }

    private func telemetry(_ body: [String: Any], from device: Device) {
        let type = body["type"] as? String ?? ""
        for (line, isError) in AappDevProtocol.describeTelemetry(body) { log(line, error: isError) }
        switch type {
        case "session.status":
            device.sessionReady = true
            let results = body["results"] as? [[String: Any]] ?? []
            for result in results { if let build = result["buildId"] as? String, result["ok"] as? Bool == true { device.reportedBuilds.insert(build) } }
            if let current, !device.reportedBuilds.contains(current.deployment.buildId), body["automatic"] as? Bool != false {
                sendDeploy(to: device)
            }
        case "deploy.result":
            if let build = body["buildId"] as? String, body["ok"] as? Bool == true { device.reportedBuilds.insert(build) }
            let ok = body["ok"] as? Bool ?? false
            emit?(.deployed("\(body["appId"] as? String ?? "") · \(body["buildId"] as? String ?? "") · \(ok ? AappDevProtocol.phaseName(body["phase"] as? String ?? "running") : "失败")"))
        default: break
        }
        publish()
    }

    /// Adds an event to the device's numbered stream (and its replay buffer).
    private func enqueue(_ device: Device, _ payload: [String: Any]) {
        device.seq += 1
        let frame = AappDevProtocol.sseFrame(seq: device.seq, payload: payload)
        device.buffered.append((device.seq, frame))
        if device.buffered.count > 200 { device.buffered.removeFirst(device.buffered.count - 200) }
        device.stream?.streamWrite(frame)
    }

    private func tick() {
        let now = Date()
        for device in devices.values {
            if now.timeIntervalSince(device.lastSeen) > 50 {
                // No heartbeat (every 15 s) for 50 s: the phone is gone (background, sleep, unplugged).
                device.stream?.cancel()
                devices[device.id] = nil
                log("手机 \(device.deviceName) 超时断开（手机上的 Host 要保持在前台）", error: true)
            } else {
                device.stream?.streamWrite(Data(": keepalive\n\n".utf8))
            }
        }
        publish()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: stateFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    private func publish() {
        let live = devices.values.filter { $0.stream != nil }
        let status: String
        if listener == nil { status = "开发服务未启动" }
        else if let device = live.first { status = "已连接 \(device.deviceName)" + (current.map { " · \($0.deployment.appId)" } ?? "") }
        else if !devices.isEmpty { status = "手机连接中…" }
        else if manifest == nil { status = "选择一个 .aapk 后即可配对手机" }
        else { status = "等待手机配对（端口 \(port)）" }
        emit?(.state(paired: !live.isEmpty, device: live.first?.deviceName, status: status))
    }

    private func log(_ text: String, error: Bool = false) { emit?(.log(text, error)) }
}
