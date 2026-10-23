// Mac side of the phone bridge (see ble-bridge.py for the JSON-lines protocol).
// Mirrors the emulated glasses' GATT database as a CoreBluetooth peripheral, advertises under the glasses'
// name and service UUIDs, and relays a real phone's ATT operations to ble-bridge.py.
//   build: sh tools/ble-bridge/build.sh      run: tools/ble-bridge/.build/BLEBridgeHelper [--port 23650]
import CoreBluetooth
import Foundation
import Network

var logHandle = FileHandle.standardError
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    logHandle.write("\(f.string(from: Date())) helper: \(s)\n".data(using: .utf8)!)
}

func cbuuid(_ hex: String) -> CBUUID {
    if hex.count == 32 {
        let c = Array(hex)
        let dashed = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }.joined(separator: "-")
        return CBUUID(string: dashed)
    }
    return CBUUID(string: hex)
}

extension Data {
    init?(hex: String) {
        var d = Data(capacity: hex.count / 2); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

final class Bridge: NSObject, CBPeripheralManagerDelegate {
    let port: UInt16
    var manager: CBPeripheralManager!
    var connection: NWConnection?
    var buffer = Data()
    var db: [String: Any]?
    var published = false
    var byHandle: [Int: CBMutableCharacteristic] = [:]
    var handleOf: [ObjectIdentifier: Int] = [:]
    var pendingReads: [Int: CBATTRequest] = [:]
    var pendingWrites: [Int: CBATTRequest] = [:]
    var nextID = 1
    var outbox: [(CBMutableCharacteristic, Data)] = []
    var centrals = Set<UUID>()
    var linkUp = false

    init(port: UInt16) {
        self.port = port
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
        connect()
    }

    // MARK: link to ble-bridge.py

    func connect() {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: log("connected to bridge on \(self?.port ?? 0)"); self?.receive()
            case .failed, .waiting:
                c.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self?.connection === c { self?.connect() } }
            default: break
            }
        }
        c.start(queue: .main)
    }

    func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if done || error != nil {
                log("bridge connection closed"); self.connection?.cancel()
                if exitWithBridge { self.manager.stopAdvertising(); log("exiting with the bridge"); exit(0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connect() }
                return
            }
            self.receive()
        }
    }

    func drain() {
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]; buffer = Data(buffer[buffer.index(after: nl)...])
            guard let m = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let t = m["t"] as? String else { continue }
            handle(t, m)
        }
    }

    func send(_ m: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: m) else { return }
        connection?.send(content: d + Data([10]), completion: .contentProcessed { _ in })
    }

    func handle(_ t: String, _ m: [String: Any]) {
        switch t {
        case "db":
            if db == nil || !NSDictionary(dictionary: db!).isEqual(to: m) { db = m; publish() }
        case "link":
            linkUp = m["up"] as? Bool ?? false
            log("emulated glasses link \(linkUp ? "up" : "down")")
        case "notify":
            guard let h = m["handle"] as? Int, let c = byHandle[h], let d = Data(hex: m["data"] as? String ?? "") else { return }
            outbox.append((c, d)); flush()
        case "read_rsp":
            guard let id = m["id"] as? Int, let r = pendingReads.removeValue(forKey: id) else { return }
            if let e = m["err"] as? Int { manager.respond(to: r, withResult: CBATTError.Code(rawValue: e) ?? .unlikelyError); return }
            let d = Data(hex: m["data"] as? String ?? "") ?? Data()
            guard r.offset <= d.count else { manager.respond(to: r, withResult: .invalidOffset); return }
            r.value = d.subdata(in: r.offset..<d.count); manager.respond(to: r, withResult: .success)
        case "write_rsp":
            guard let id = m["id"] as? Int, let r = pendingWrites.removeValue(forKey: id) else { return }
            manager.respond(to: r, withResult: (m["err"] as? Int).flatMap { CBATTError.Code(rawValue: $0) } ?? .success)
        default: break
        }
    }

    // MARK: GATT mirror

    func publish() {
        guard manager.state == .poweredOn, let db else { return }
        manager.stopAdvertising(); manager.removeAllServices()
        byHandle = [:]; handleOf = [:]
        var uuids: [CBUUID] = []
        for s in db["services"] as? [[String: Any]] ?? [] {
            guard let su = s["uuid"] as? String else { continue }
            let service = CBMutableService(type: cbuuid(su), primary: true)
            var chars: [CBMutableCharacteristic] = []
            for ch in s["chars"] as? [[String: Any]] ?? [] {
                guard let u = ch["uuid"] as? String, let h = ch["handle"] as? Int, let p = ch["props"] as? Int else { continue }
                var props: CBCharacteristicProperties = []
                var perms: CBAttributePermissions = []
                if p & 0x02 != 0 { props.insert(.read); perms.insert(.readable) }
                if p & 0x04 != 0 { props.insert(.writeWithoutResponse); perms.insert(.writeable) }
                if p & 0x08 != 0 { props.insert(.write); perms.insert(.writeable) }
                if p & 0x10 != 0 { props.insert(.notify) }
                if p & 0x20 != 0 { props.insert(.indicate) }
                // 2A05 Service Changed etc. live in the GATT service, which is not mirrored.
                let c = CBMutableCharacteristic(type: cbuuid(u), properties: props, value: nil, permissions: perms)
                chars.append(c); byHandle[h] = c; handleOf[ObjectIdentifier(c)] = h
            }
            service.characteristics = chars
            manager.add(service)
            uuids.append(service.uuid)
        }
        let adv = (db["adv_uuids"] as? [String] ?? []).map(cbuuid)
        let name = db["name"] as? String ?? "RayNeo"
        manager.startAdvertising([CBAdvertisementDataLocalNameKey: name,
                                  CBAdvertisementDataServiceUUIDsKey: adv.isEmpty ? uuids : adv])
        published = true
        log("advertising \"\(name)\" with \(byHandle.count) characteristics in \(uuids.count) services")
    }

    func flush() {
        while let (c, d) = outbox.first {
            let centralsFor = c.subscribedCentrals ?? []
            if centralsFor.isEmpty { outbox.removeFirst(); continue }     // nobody listening: drop
            if let mx = centralsFor.map(\.maximumUpdateValueLength).min(), d.count > mx {
                log("notification \(d.count) B exceeds the phone's \(mx) B limit; set BRIDGE_MTU lower")
            }
            guard manager.updateValue(d, for: c, onSubscribedCentrals: nil) else { return }   // queue full: resume later
            outbox.removeFirst()
        }
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn: log("Bluetooth on"); publish()
        case .unauthorized: log("Bluetooth permission denied: System Settings > Privacy & Security > Bluetooth, allow BLEBridgeHelper (or the terminal app running it)")
        case .poweredOff: log("Bluetooth is off")
        default: log("Bluetooth state \(p.state.rawValue)")
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { log("add service \(service.uuid) failed: \(error.localizedDescription)") }
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        log(error.map { "advertising failed: \($0.localizedDescription)" } ?? "advertising started")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        note(central, connected: true)
        guard let h = handleOf[ObjectIdentifier(c)] else { return }
        let indicate = c.properties.contains(.indicate) && !c.properties.contains(.notify)
        log("phone subscribed to \(c.uuid) (max \(central.maximumUpdateValueLength) B)")
        send(["t": "subscribe", "handle": h, "value": indicate ? 2 : 1])
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        guard let h = handleOf[ObjectIdentifier(c)] else { return }
        send(["t": "subscribe", "handle": h, "value": 0])
        if (c as? CBMutableCharacteristic)?.subscribedCentrals?.isEmpty ?? true,
           byHandle.values.allSatisfy({ $0.subscribedCentrals?.contains(where: { $0.identifier == central.identifier }) != true }) {
            note(central, connected: false)          // CoreBluetooth has no disconnect callback; last unsubscribe ~ leave
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) {
        note(r.central, connected: true)
        guard let h = handleOf[ObjectIdentifier(r.characteristic)], linkUp else { p.respond(to: r, withResult: .unlikelyError); return }
        let id = nextID; nextID += 1
        pendingReads[id] = r
        send(["t": "read", "id": id, "handle": h])
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        note(first.central, connected: true)
        guard linkUp else { p.respond(to: first, withResult: .unlikelyError); return }
        // CoreBluetooth hands a batch (write requests and queued long writes) answered with ONE respond.
        var needsResponse = false
        for r in requests {
            guard let h = handleOf[ObjectIdentifier(r.characteristic)], let v = r.value else { continue }
            let withResponse = r.characteristic.properties.contains(.write) && !r.characteristic.properties.contains(.writeWithoutResponse)
                || (r.characteristic.properties.contains(.write) && requests.count > 1)
            if withResponse && r === first {
                let id = nextID; nextID += 1
                pendingWrites[id] = first; needsResponse = true
                send(["t": "write", "id": id, "handle": h, "data": v.hex, "rsp": true])
            } else {
                send(["t": "write", "id": 0, "handle": h, "data": v.hex, "rsp": false])
            }
        }
        if !needsResponse { p.respond(to: first, withResult: .success) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { flush() }

    func note(_ central: CBCentral, connected: Bool) {
        if connected, !centrals.contains(central.identifier) {
            centrals.insert(central.identifier); log("phone \(central.identifier) connected"); send(["t": "phone", "connected": true])
        } else if !connected, centrals.remove(central.identifier) != nil {
            log("phone \(central.identifier) left"); send(["t": "phone", "connected": false])
        }
    }
}

var port: UInt16 = 23650
/// --exit-with-bridge: quit (and stop advertising) when ble-bridge.py closes the connection — how the Mac
/// app stops the helper together with the emulator.
let exitWithBridge = CommandLine.arguments.contains("--exit-with-bridge")
if let i = CommandLine.arguments.firstIndex(of: "--port"), i + 1 < CommandLine.arguments.count, let p = UInt16(CommandLine.arguments[i + 1]) { port = p }
if let i = CommandLine.arguments.firstIndex(of: "--log"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    FileManager.default.createFile(atPath: path, contents: nil)
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); logHandle = h }
}
let bridge = Bridge(port: port)
RunLoop.main.run()
