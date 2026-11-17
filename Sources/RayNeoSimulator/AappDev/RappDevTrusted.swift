import CryptoKit
import Foundation

/// Phones this computer has paired with (ONE_CLICK_PROTOCOL §1 `trusted.json`), shared with `rapp dev`.
/// Only a hash of each long-lived credential is kept; at most 20 devices, least recently seen dropped first.
struct RappDevTrusted: Codable, Equatable {
    struct Device: Codable, Equatable {
        var deviceId: String
        var deviceName: String
        var credentialSha256: String
        var createdAt: Int64
        var lastSeen: Int64
    }
    var version = 1
    var devices: [Device] = []

    static let limit = 20

    static func hash(_ credential: String) -> String { AappDevProtocol.hex(Data(SHA256.hash(data: Data(credential.utf8)))) }

    static func load(from directory: URL = AappDevTLS.identityDirectory) -> RappDevTrusted {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("trusted.json")),
              let value = try? JSONDecoder().decode(RappDevTrusted.self, from: data) else { return RappDevTrusted() }
        return value
    }

    func save(to directory: URL = AappDevTLS.identityDirectory) {
        let file = directory.appendingPathComponent("trusted.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The trusted device that `credential` belongs to (deviceId must match too).
    func device(deviceId: String, credential: String) -> Device? {
        let digest = Self.hash(credential)
        return devices.first { $0.deviceId == deviceId && $0.credentialSha256 == digest }
    }

    /// Adds or replaces `deviceId` with a new credential; keeps the newest `limit`.
    mutating func trust(deviceId: String, deviceName: String, credential: String, now: Date = Date()) {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        devices.removeAll { $0.deviceId == deviceId }
        devices.append(Device(deviceId: deviceId, deviceName: deviceName, credentialSha256: Self.hash(credential), createdAt: ms, lastSeen: ms))
        if devices.count > Self.limit {
            devices.sort { $0.lastSeen > $1.lastSeen }
            devices = Array(devices.prefix(Self.limit))
        }
    }

    mutating func touch(deviceId: String, deviceName: String, now: Date = Date()) {
        guard let index = devices.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        devices[index].lastSeen = Int64(now.timeIntervalSince1970 * 1000)
        devices[index].deviceName = deviceName
    }
}
