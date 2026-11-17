import CryptoKit
import Foundation
import Network
import Security
import Darwin

/// The dev server's computer identity (ONE_CLICK_PROTOCOL §1): a self-signed P-256 certificate, key and serverId kept
/// in `~/.rapp-dev/identity/identity.json` (`$DEV_HOME/identity/` when set) — the same files `rapp dev` uses, so this
/// Mac presents one identity whichever dev server runs. Made once with the system `openssl` (10 years). The phone pins
/// its SHA-256, so it needs no CA. The identity is imported in memory only; nothing is added to the user's keychain.
struct AappDevTLS {
    let identity: SecIdentity
    let certificateDER: Data
    let serverId: String
    var fingerprint: Data { Data(SHA256.hash(data: certificateDER)) }

    enum Failure: Error, LocalizedError {
        case openssl(String), importFailed(OSStatus), noIdentity, badIdentityFile
        var errorDescription: String? {
            switch self {
            case .openssl(let text): return "生成开发证书失败：\(text)"
            case .importFailed(let status): return "导入开发证书失败（\(status)）"
            case .noIdentity: return "开发证书不完整"
            case .badIdentityFile: return "电脑身份文件 identity.json 无法读取"
            }
        }
    }

    /// `~/.rapp-dev/identity` (or `$DEV_HOME/identity`), shared with the Node dev server.
    static var identityDirectory: URL {
        let home = ProcessInfo.processInfo.environment["DEV_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rapp-dev", isDirectory: true)
        return home.appendingPathComponent("identity", isDirectory: true)
    }

    /// App-private cache (the PKCS#12 made from identity.json, state.json).
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RayNeo io on Mac/devserver", isDirectory: true)
    }

    struct IdentityFile: Codable {
        var version: Int
        var serverId: String
        var certPem: String
        var keyPem: String
        var createdAt: Int64
    }

    /// Loads the shared computer identity, creating `identity.json` on first use.
    static func load(identityDirectory: URL = identityDirectory, cache: URL = directory) throws -> AappDevTLS {
        let files = FileManager.default
        try files.createDirectory(at: identityDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = identityDirectory.appendingPathComponent("identity.json")
        if !files.fileExists(atPath: file.path) { try create(file, scratch: cache) }
        guard let data = try? Data(contentsOf: file), let id = try? JSONDecoder().decode(IdentityFile.self, from: data),
              id.serverId.count == 32, id.certPem.contains("CERTIFICATE"), id.keyPem.contains("PRIVATE KEY") else { throw Failure.badIdentityFile }
        // PKCS#12 cache keyed by the certificate, so a new identity.json (made by `rapp dev`) is picked up.
        let tag = AappDevProtocol.hex(Data(SHA256.hash(data: Data(id.certPem.utf8)))).prefix(16)
        let p12 = cache.appendingPathComponent("identity-\(tag).p12"), pass = cache.appendingPathComponent("identity-\(tag).pass")
        if let tls = try? open(p12: p12, passFile: pass, serverId: id.serverId) { return tls }
        try export(id, p12: p12, passFile: pass, scratch: cache)
        return try open(p12: p12, passFile: pass, serverId: id.serverId)
    }

    private static func open(p12: URL, passFile: URL, serverId: String) throws -> AappDevTLS {
        let data = try Data(contentsOf: p12)
        let password = try String(contentsOf: passFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw Failure.importFailed(status) }
        guard let first = (items as? [[String: Any]])?.first, let value = first[kSecImportItemIdentity as String] else { throw Failure.noIdentity }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw Failure.noIdentity }
        return AappDevTLS(identity: identity, certificateDER: SecCertificateCopyData(certificate) as Data, serverId: serverId)
    }

    /// Current IPv4 addresses (for the certificate SAN; the phone pins the fingerprint, the SAN is informational).
    static func localIPv4() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                if text != "127.0.0.1", !out.contains(text) { out.append(text) }
            }
        }
        return out
    }

    private static func create(_ file: URL, scratch: URL) throws {
        let work = scratch.appendingPathComponent("new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let ec = work.appendingPathComponent("ec.pem"), key = work.appendingPathComponent("key.pem")
        let cert = work.appendingPathComponent("cert.pem"), config = work.appendingPathComponent("openssl.cnf")
        let san = (["IP:127.0.0.1"] + localIPv4().map { "IP:\($0)" }).joined(separator: ",")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = Rapp Developer Computer
        [ext]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = serverAuth
        subjectAltName = \(san)
        """.write(to: config, atomically: true, encoding: .utf8)
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ec.path])
        try run(["pkcs8", "-topk8", "-nocrypt", "-in", ec.path, "-out", key.path])
        try run(["req", "-new", "-x509", "-sha256", "-key", key.path, "-out", cert.path, "-days", "3650", "-config", config.path])
        let identity = IdentityFile(version: 1, serverId: AappDevProtocol.randomHex(bytes: 16),
                                    certPem: try String(contentsOf: cert, encoding: .utf8), keyPem: try String(contentsOf: key, encoding: .utf8),
                                    createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(identity).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func export(_ id: IdentityFile, p12: URL, passFile: URL, scratch: URL) throws {
        let work = scratch.appendingPathComponent("p12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let key = work.appendingPathComponent("key.pem"), cert = work.appendingPathComponent("cert.pem")
        try id.keyPem.write(to: key, atomically: true, encoding: .utf8)
        try id.certPem.write(to: cert, atomically: true, encoding: .utf8)
        let password = AappDevProtocol.randomToken(bytes: 24)
        try password.write(to: passFile, atomically: true, encoding: .utf8)
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:\(password)",
                 "-name", "Rapp Developer Computer"])
        for file in [p12, passFile] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }

    private static func run(_ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe; task.standardInput = FileHandle.nullDevice
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw Failure.openssl(String(decoding: output, as: UTF8.self).suffix(300).description) }
    }

    /// TLS parameters for the listener (TLS 1.2+, our identity).
    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}
