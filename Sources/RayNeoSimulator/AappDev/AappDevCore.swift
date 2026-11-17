import CryptoKit
import Foundation
import Network

/// Server side of `rapp-dev.v3` plus one-click connect (ONE_CLICK_PROTOCOL §1–3: shared computer identity,
/// Bonjour `_rapp-dev._tcp`, `/dev/discovery`, computer-approved pairing). Lives on its own serial queue; reports to the main-actor facade through
/// `events`. Bounded: ≤ 8 device connections, ≤ 200 buffered SSE events each, ≤ 3 packages kept for download.
final class AappDevCore {
    enum Event {
        case log(String, Bool)
        case state(paired: Bool, device: String?, status: String)
        case deployed(String)
        /// A phone asks to pair: show `code` and let the developer allow or refuse it.
        case pairingRequest(id: String, deviceName: String, code: String)
        case pairingResolved(id: String)
        /// The connected phone, and whether it reaches this Mac over USB (loopback: adb reverse / USB bridge).
        case connection(device: String?, wired: Bool)
    }

    /// One computer-approved pairing request (§3), valid 2 minutes.
    struct PairingRequest {
        let id: String
        let deviceId: String
        let deviceName: String
        let code: String
        let expiresAt: Date
        var state = "pending"          // pending | approved | rejected | expired
        var token: String?
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
        var wired = false
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
    private var trusted = RappDevTrusted.load()
    private var requests: [String: PairingRequest] = [:]
    /// `/control/*` (§3): loopback only, Bearer = the token in devserver/control-token (0600).
    private lazy var controlToken: String = {
        let file = AappDevTLS.directory.appendingPathComponent("control-token")
        if let text = try? String(contentsOf: file, encoding: .utf8), text.count >= 32 { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let token = AappDevProtocol.randomToken()
        try? token.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }()
    private var controllers: [AappDevHTTPConnection] = []
    /// The embedded glasses simulator (lvgl_host, port 10002): its current `rapp-slave://` invitation, kept fresh
    /// by the main actor. Lets DevTool connect it by itself (`/simulators`, `simulatorAutoStart`) — no pasting.
    private var simulatorInvitation = ""
    private var simulatorPort: UInt16 = 10_002
    /// Commands forwarded to a phone whose `command.result` answers an HTTP request (requestId -> waiter).
    private var waiters: [String: (http: AappDevHTTPConnection, extra: [String: Any], timer: DispatchSourceTimer)] = [:]
    /// Bonjour instance name and the computer name shown on the phone.
    let computerName = Host.current().localizedName ?? "Mac"

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
        if saved.serverId != identity.serverId { saved.serverId = identity.serverId; save() }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: identity.parameters(), on: nwPort)
        listener.service = bonjourService()
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add = change { self?.log("局域网可发现：\(self?.computerName ?? "")") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.log("开发服务已启动：https://0.0.0.0:\(self.port)/dev（电脑 \(self.computerName)，serverId \(identity.serverId.prefix(8))…，证书指纹 \(AappDevProtocol.hex(identity.fingerprint).prefix(16))…）")
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
                                                computer: computerName, manifest: manifest,
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
              let version = AappDevProtocol.versionText(manifest), !version.isEmpty, version.count <= 64 else {
            throw AapkReader.Failure.missing("manifest.json 的 package / version")
        }
        if let previous = self.manifest?["package"] as? String, previous != appId {
            // §1: one identity for every project; trusted phones resume and take the new appId from welcome.
            log("换了应用（\(previous) → \(appId)）：已连接的手机重新连接后切换到新应用")
            for device in devices.values { enqueue(device, ["type": "session.end"]); device.stream?.endStream() }
            devices.removeAll()
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
        listener?.service = bonjourService()
        log("准备部署 \(appId) \(version)（\(url.lastPathComponent)，\(data.count) 字节，构建 \(deployment.buildId)）")
        emit?(.deployed("\(appId) \(version) · \(deployment.buildId)"))
        let ready = devices.values.filter { $0.sessionReady && $0.appId == appId }
        if ready.isEmpty { log(devices.isEmpty ? "等手机连接后自动安装（手机 Host → 开发工具 → 附近的电脑）" : "等手机连上后自动安装") }
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
            log("监视 \(directory.path) 的构建输出（build/*.rpk），有新包就自动部署")
            let (url, sig) = signature(of: directory)
            if let url, !sig.isEmpty {
                do { try deployNow(url) } catch { log("部署失败：\(error.localizedDescription)", error: true) }
            } else {
                log("还没有构建输出：构建完成后会自动部署")
            }
        }
    }

    private func signature(of directory: URL) -> (URL?, String) {
        let files = FileManager.default
        var candidates: [URL] = []
        for dir in [directory.appendingPathComponent("build"), directory] {
            candidates += (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))?
                .filter { $0.pathExtension == "rpk" || $0.pathExtension == "aapk" } ?? []
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
        // Browsers may not talk to the dev server (same rule as `rapp dev`).
        if request.headers["origin"] != nil { http.respond(403, json: AappDevProtocol.json(["error": ["code": "FORBIDDEN"]])); return }
        let parts = request.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if parts == ["dev", "discovery"], request.method == "GET" {
            http.respond(200, json: AappDevProtocol.json(discovery(wired: http.isLoopback))); return
        }
        if parts == ["dev", "pairing", "requests"], request.method == "POST" { pairingRequest(request, http); return }
        if parts.first == "control" {
            guard http.isLoopback, request.bearer == controlToken else { http.respond(401, json: AappDevProtocol.json(["error": ["code": "UNAUTHORIZED"]])); return }
            if parts == ["control", "events"], request.method == "GET" {
                controllers.removeAll { $0 === http }
                controllers.append(http)
                http.beginStream()
                for entry in requests.values where entry.state == "pending" {
                    http.streamWrite(controlFrame(["type": "pairing.request", "requestId": entry.id, "deviceName": entry.deviceName, "code": entry.code]))
                }
                return
            }
            if parts.count == 4, parts[1] == "pairing", parts[2] == "requests", request.method == "POST" {
                guard requests[parts[3]]?.state == "pending" else { http.respond(404, json: AappDevProtocol.errorBody("Unknown pairing request")); return }
                let approve = request.jsonBody()?["approve"] as? Bool ?? false
                resolve(request: parts[3], approve: approve)
                http.respond(200, json: AappDevProtocol.json(["ok": true])); return
            }
            http.respond(404, json: AappDevProtocol.errorBody("Not found")); return
        }
        if parts.count == 4, parts[0] == "dev", parts[1] == "pairing", parts[2] == "requests", request.method == "GET" {
            expireRequests()
            guard let entry = requests[parts[3]] else { http.respond(404, json: AappDevProtocol.errorBody("Unknown pairing request")); return }
            var body: [String: Any] = ["state": entry.state]
            if entry.state == "approved", let token = entry.token { body["token"] = token }
            http.respond(200, json: AappDevProtocol.json(body)); return
        }
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
            if let waiter = waiters.removeValue(forKey: rest[1]) {
                waiter.timer.cancel()
                waiter.http.respond(200, json: AappDevProtocol.json(body.merging(waiter.extra) { a, _ in a }))
            }
            for (line, isError) in AappDevProtocol.describeTelemetry(body.merging(["type": "command.result"]) { a, _ in a }) { log(line, error: isError) }
        case ("POST", ["simulators"]):
            simulators(request, http, device)
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
        let deviceId = String((body["deviceId"] as? String ?? "phone").prefix(128))
        let deviceName = String((body["deviceName"] as? String ?? "手机").prefix(128))
        let viaPairing = pairing.map { bearer == $0.token && $0.expiresAt > Date() } ?? false
        // §1: a trusted phone resumes with its credential whatever app it last ran; welcome tells it the current one.
        let resumed = trusted.device(deviceId: deviceId, credential: bearer) != nil
        guard viaPairing || resumed else {
            http.respond(401, json: AappDevProtocol.json(["error": ["code": "PAIRING_REQUIRED", "message": "Pair again on the computer"]])); return
        }
        guard body["protocol"] as? String == AappDevProtocol.version, body["serverId"] as? String == saved.serverId else {
            http.respond(409, json: AappDevProtocol.errorBody("Wrong developer server")); return
        }
        guard let appId = manifest?["package"] as? String else {
            http.respond(409, json: AappDevProtocol.errorBody("No project is open on the computer yet")); return
        }
        // One live connection per phone: a reconnect replaces the old one.
        for old in devices.values where old.deviceId == deviceId { old.stream?.endStream(); devices[old.id] = nil }
        while devices.count >= 8, let oldest = devices.values.min(by: { $0.lastSeen < $1.lastSeen }) { oldest.stream?.cancel(); devices[oldest.id] = nil }
        let credential = resumed ? bearer : AappDevProtocol.randomToken()
        if resumed { trusted.touch(deviceId: deviceId, deviceName: deviceName) }
        else {
            trusted.trust(deviceId: deviceId, deviceName: deviceName, credential: credential)
            pairing = nil    // one-time token
        }
        trusted.save()
        // As in `rapp dev`, the credential from welcome is the bearer for this connection's requests.
        let device = Device(id: AappDevProtocol.randomHex(bytes: 16), token: credential,
                            credential: credential, appId: appId, deviceId: deviceId, deviceName: deviceName)
        device.wired = http.isLoopback
        devices[device.id] = device
        let welcome: [String: Any] = [
            "type": "welcome", "protocol": AappDevProtocol.version, "serverId": saved.serverId,
            "connectionId": device.id, "token": credential, "afterSeq": 0,
            "maxPackageBytes": AappDevProtocol.maxPackageBytes, "capabilities": ["simulator": true, "simulatorAutoStart": true],
            "appId": appId, "manifest": manifest ?? [:],
            "identity": ["serverId": saved.serverId, "fingerprint": tls.map { AappDevProtocol.base64url($0.fingerprint) } ?? "",
                         "computer": computerName, "persistent": true],
        ]
        http.respond(201, json: AappDevProtocol.json(welcome))
        log(viaPairing ? "手机 \(deviceName) 已配对（\(appId)）" : "手机 \(deviceName) 重新连上")
        publish()
    }

    // MARK: one-click connect (§2–3)

    /// `GET /dev/discovery` (no auth; shown on the phone before it pins the certificate).
    private func discovery(wired: Bool) -> [String: Any] {
        ["v": 1, "serverId": saved.serverId, "fingerprint": tls.map { AappDevProtocol.base64url($0.fingerprint) } ?? "",
         "computer": computerName, "appId": manifest?["package"] as? String ?? "", "appName": appName,
         "transport": wired ? "usb" : "lan"]
    }

    private var appName: String {
        if let name = manifest?["name"] as? String, !name.hasPrefix("@") { return name }
        return manifest?["package"] as? String ?? ""
    }

    /// Bonjour `_rapp-dev._tcp` with the §2.1 TXT record.
    private func bonjourService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["sid"] = saved.serverId
        txt["fp"] = tls.map { AappDevProtocol.base64url($0.fingerprint) } ?? ""
        txt["name"] = computerName
        txt["app"] = manifest?["package"] as? String ?? ""
        txt["appName"] = appName
        return NWListener.Service(name: computerName, type: "_rapp-dev._tcp", domain: nil, txtRecord: txt)
    }

    private func pairingRequest(_ request: AappDevRequest, _ http: AappDevHTTPConnection) {
        expireRequests()
        guard let body = request.jsonBody(), let deviceId = body["deviceId"] as? String, !deviceId.isEmpty, deviceId.count <= 128,
              let nonceText = body["nonce"] as? String, let nonce = AappDevProtocol.base64urlDecode(nonceText), nonce.count == 16,
              let tls else {
            http.respond(400, json: AappDevProtocol.errorBody("Bad pairing request")); return
        }
        guard requests.values.filter({ $0.state == "pending" }).count < 4 else {
            http.respond(429, json: AappDevProtocol.errorBody("Too many pairing requests")); return
        }
        let deviceName = String((body["deviceName"] as? String ?? "手机").prefix(128))
        let code = AappDevProtocol.pairingCode(fingerprint: tls.fingerprint, deviceId: deviceId, nonce: nonce)
        let id = AappDevProtocol.randomToken(bytes: 16)
        let expires = Date().addingTimeInterval(120)
        requests[id] = PairingRequest(id: id, deviceId: deviceId, deviceName: deviceName, code: code, expiresAt: expires)
        http.respond(202, json: AappDevProtocol.json(["requestId": id, "code": code, "expiresAt": Int64(expires.timeIntervalSince1970 * 1000)]))
        log("\(deviceName) 请求连接 · 比对码 \(code)")
        emit?(.pairingRequest(id: id, deviceName: deviceName, code: code))
        broadcastControl(["type": "pairing.request", "requestId": id, "deviceName": deviceName, "code": code])
    }

    /// The developer allowed (or refused) a pairing request on this Mac.
    func resolve(request id: String, approve: Bool) {
        queue.async { [self] in
            expireRequests()
            guard var entry = requests[id], entry.state == "pending" else { return }
            if approve {
                guard let manifest, let tls else { log("还没有可运行的应用，无法允许连接", error: true); return }
                // The approved phone gets a one-time pairing token and continues with describe → device-connections.
                let fresh = AappDevProtocol.Pairing(host: "127.0.0.1", port: port, certificateSHA256: tls.fingerprint,
                                                    token: AappDevProtocol.randomToken(), serverId: saved.serverId,
                                                    computer: computerName, manifest: manifest, expiresAt: Date().addingTimeInterval(300))
                pairing = fresh
                entry.state = "approved"; entry.token = fresh.token
                log("已允许 \(entry.deviceName) 连接")
            } else {
                entry.state = "rejected"
                log("已拒绝 \(entry.deviceName) 的连接请求")
            }
            requests[id] = entry
            emit?(.pairingResolved(id: id))
            broadcastControl(["type": "pairing.resolved", "requestId": id, "state": entry.state])
        }
    }

    private func controlFrame(_ event: [String: Any]) -> Data {
        Data("event: \(event["type"] as? String ?? "message")\ndata: ".utf8) + AappDevProtocol.json(event) + Data("\n\n".utf8)
    }

    private func broadcastControl(_ event: [String: Any]) {
        controllers.removeAll { !httpConnections.keys.contains($0.id) }
        for controller in controllers { controller.streamWrite(controlFrame(event)) }
    }

    private func expireRequests() {
        let now = Date()
        for (id, entry) in requests {
            if entry.state == "pending", entry.expiresAt < now {
                requests[id]?.state = "expired"; emit?(.pairingResolved(id: id))
            }
            if entry.expiresAt.addingTimeInterval(300) < now { requests[id] = nil }
        }
    }

    // MARK: embedded simulator (`POST /dev/device-connections/<id>/simulators`, as `rapp dev`)

    /// `RAPPUSB1` hello for the iPhone USB bridge (§5).
    func usbHello() -> [String: Any] {
        queue.sync { ["serverId": saved.serverId, "fingerprint": tls.map { AappDevProtocol.base64url($0.fingerprint) } ?? "", "computer": computerName] }
    }

    func setSimulator(invitation: String, port: UInt16) {
        queue.async { [self] in simulatorInvitation = invitation; simulatorPort = port }
    }

    private static let simulatorId = "io-on-mac"

    private func simulatorInstance(address: String) -> [String: Any]? {
        guard let sha = URLComponents(string: simulatorInvitation)?.queryItems?.first(where: { $0.name == "sha256" })?.value,
              !sha.isEmpty else { return nil }
        return ["instanceId": Self.simulatorId,
                "process": ["state": "running", "transport": "tcp", "program": "lvgl_host", "listening": true],
                "identity": ["certificateSha256": sha],
                "route": ["address": address, "port": Int(simulatorPort)]]
    }

    private func simulators(_ request: AappDevRequest, _ http: AappDevHTTPConnection, _ device: Device) {
        let action = request.jsonBody()?["action"] as? String ?? ""
        // The phone reaches the simulator the way it reaches this server (127.0.0.1 over USB, else the LAN address).
        let address = http.isLoopback ? "127.0.0.1"
            : String((request.headers["host"] ?? "").split(separator: ":").first ?? "127.0.0.1")
        guard let instance = simulatorInstance(address: address) else {
            http.respond(200, json: AappDevProtocol.json(["ok": false, "code": "SIMULATOR_UNAVAILABLE", "message": "眼镜模拟器还没准备好"])); return
        }
        switch action {
        case "start", "status", "stop":
            http.respond(200, json: AappDevProtocol.json(["ok": true].merging(instance) { a, _ in a }))
        case "list":
            http.respond(200, json: AappDevProtocol.json(["ok": true, "instances": [instance]]))
        case "connect":
            let requestId = "r" + AappDevProtocol.randomHex(bytes: 8)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15)
            timer.setEventHandler { [weak self] in
                guard let self, let waiter = self.waiters.removeValue(forKey: requestId) else { return }
                waiter.http.respond(200, json: AappDevProtocol.json(["ok": false, "code": "COMMAND_UNKNOWN", "message": "Command result is unconfirmed"]))
            }
            waiters[requestId] = (http, ["instanceId": Self.simulatorId], timer)
            timer.resume()
            enqueue(device, ["type": "glassLink.connect", "requestId": requestId,
                             "expiresAt": Int64(Date().addingTimeInterval(15).timeIntervalSince1970 * 1000),
                             "request": ["transport": "tcp", "invitation": simulatorInvitation,
                                         "route": instance["route"]!,
                                         "simulator": ["instanceId": Self.simulatorId,
                                                       "certificateSha256": (instance["identity"] as! [String: Any])["certificateSha256"]!]]])
            log("让 \(device.deviceName) 连接眼镜模拟器（\(address):\(simulatorPort)）")
        default:
            http.respond(400, json: AappDevProtocol.errorBody("Unknown simulator action"))
        }
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
        expireRequests()
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
        else if manifest == nil { status = "等待构建完成" }
        else { status = "等待手机连接" }
        emit?(.state(paired: !live.isEmpty, device: live.first?.deviceName, status: status))
        emit?(.connection(device: live.first?.deviceName, wired: live.first?.wired ?? false))
    }

    private func log(_ text: String, error: Bool = false) { emit?(.log(text, error)) }
}
