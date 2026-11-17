import Foundation
import Network

/// iPhone USB bridge (ONE_CLICK_PROTOCOL §5), the same as `rapp dev`'s: for each iPhone attached over USB, a control
/// connection through usbmuxd to the Host's 127.0.0.1:47890 (`RAPPUSB1 {…}` → `OK`), then one tunnel per
/// `OPEN <id> <port>` that pipes the phone's 127.0.0.1:<port> to this Mac's 127.0.0.1:<port> (17890 dev server,
/// 10002 glasses simulator). No usbmuxd, no iPhone or no Host listening → quiet retry every 3 s.
final class IosUsbBridge {
    static let bridgePort: UInt16 = 47_890
    private let queue = DispatchQueue(label: "rapp.ios-usb")
    private let hello: () -> [String: Any]
    private let ports: [UInt16]
    private let log: (String) -> Void
    private var controls: [Int: NWConnection] = [:]
    private var attaching: Set<Int> = []
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(ports: [UInt16], hello: @escaping () -> [String: Any], log: @escaping (String) -> Void) {
        self.ports = ports; self.hello = hello; self.log = log
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 3)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true; timer?.cancel(); timer = nil
            controls.values.forEach { $0.cancel() }; controls.removeAll()
        }
    }

    // MARK: usbmuxd

    private static let socketPath = "/var/run/usbmuxd"

    private static func packet(_ message: [String: Any]) -> Data? {
        var body = message
        body["ClientVersionString"] = "rapp-dev"; body["ProgName"] = "rapp-dev"
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) else { return nil }
        var out = Data()
        for value in [UInt32(16 + plist.count), 1, 8, 1] { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append(plist)
        return out
    }

    /// Sends one request and reads one reply; the connection stays open (after `Connect` it is the tunnel).
    private func request(_ message: [String: Any], done: @escaping (NWConnection?, [String: Any]?) -> Void) {
        guard FileManager.default.fileExists(atPath: Self.socketPath), let data = Self.packet(message) else { return done(nil, nil) }
        let connection = NWConnection(to: .unix(path: Self.socketPath), using: .tcp)
        var finished = false
        let finish: (NWConnection?, [String: Any]?) -> Void = { c, r in
            guard !finished else { return }
            finished = true
            if c == nil { connection.cancel() }
            done(c, r)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { header, _, _, _ in
                    guard let header, header.count == 16 else { return finish(nil, nil) }
                    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                    guard length >= 16, length < 4 << 20 else { return finish(nil, nil) }
                    if length == 16 { return finish(connection, [:]) }
                    connection.receive(minimumIncompleteLength: length - 16, maximumLength: length - 16) { body, _, _, _ in
                        let reply = body.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
                        finish(reply == nil ? nil : connection, reply)
                    }
                }
            case .failed, .cancelled: finish(nil, nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(nil, nil) }
    }

    private func connect(device: Int, port: UInt16, done: @escaping (NWConnection?) -> Void) {
        let swapped = Int((port & 0xff) << 8 | (port >> 8))
        request(["MessageType": "Connect", "DeviceID": device, "PortNumber": swapped]) { connection, reply in
            guard let connection, reply?["MessageType"] as? String == "Result", (reply?["Number"] as? Int) == 0 else {
                connection?.cancel(); return done(nil)
            }
            done(connection)
        }
    }

    // MARK: bridge

    private func scan() {
        guard !stopped else { return }
        request(["MessageType": "ListDevices"]) { [self] connection, reply in
            connection?.cancel()
            let list = reply?["DeviceList"] as? [[String: Any]] ?? []
            for item in list {
                guard let id = item["DeviceID"] as? Int else { continue }
                let properties = item["Properties"] as? [String: Any] ?? [:]
                guard (properties["ConnectionType"] as? String ?? "USB") == "USB",
                      controls[id] == nil, !attaching.contains(id) else { continue }
                attach(device: id, serial: properties["SerialNumber"] as? String ?? "\(id)")
            }
        }
    }

    private func attach(device: Int, serial: String) {
        attaching.insert(device)
        connect(device: device, port: Self.bridgePort) { [self] control in
            attaching.remove(device)
            guard let control, !stopped else { return }      // Host not running / not listening yet: next tick.
            controls[device] = control
            var hello = self.hello(); hello["ports"] = ports.map { Int($0) }
            guard let json = try? JSONSerialization.data(withJSONObject: hello) else { return }
            control.send(content: Data("RAPPUSB1 ".utf8) + json + Data("\n".utf8), completion: .contentProcessed { _ in })
            var ready = false
            readLines(control) { [self] line in
                if !ready {
                    if line == "OK" { ready = true; log("iPhone \(serial) 已通过 USB 连接（转发 \(ports.map(String.init).joined(separator: ", "))）") }
                    else { control.cancel() }
                    return
                }
                let parts = line.split(separator: " ")
                if parts.count == 3, parts[0] == "OPEN", let port = UInt16(parts[2]), ports.contains(port) {
                    open(device: device, id: String(parts[1]), port: port)
                }
            } closed: { [self] in
                if controls[device] === control { controls[device] = nil }
                if ready, !stopped { log("iPhone \(serial) 的 USB 连接已断开") }
            }
        }
    }

    private func readLines(_ connection: NWConnection, buffer: Data = Data(), line: @escaping (String) -> Void, closed: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            var pending = buffer + (data ?? Data())
            while let end = pending.firstIndex(of: 0x0a) {
                line(String(decoding: pending[pending.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces))
                pending = Data(pending[(end + 1)...])
            }
            if complete || error != nil || pending.count > 65_536 { connection.cancel(); closed(); return }
            readLines(connection, buffer: pending, line: line, closed: closed)
        }
    }

    private func open(device: Int, id: String, port: UInt16) {
        connect(device: device, port: Self.bridgePort) { [self] remote in
            guard let remote else { log("USB 通道 \(id) 打开失败"); return }
            remote.send(content: Data("DATA \(id)\n".utf8), completion: .contentProcessed { _ in })
            let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let close = { local.cancel(); remote.cancel() }
            local.stateUpdateHandler = { state in if case .failed = state { close() } }
            local.start(queue: queue)
            pipe(from: remote, to: local, close: close)
            pipe(from: local, to: remote, close: close)
        }
    }

    private func pipe(from source: NWConnection, to target: NWConnection, close: @escaping () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                target.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { close() } else if !complete && error == nil { self.pipe(from: source, to: target, close: close) }
                })
            } else if !complete && error == nil {
                pipe(from: source, to: target, close: close); return
            }
            if complete || error != nil { close() }
        }
    }
}
