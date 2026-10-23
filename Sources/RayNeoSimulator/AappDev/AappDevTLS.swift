import CryptoKit
import Foundation
import Network
import Security

/// The dev server's TLS identity: a self-signed P-256 certificate made once with the system `openssl` and kept in
/// Application Support/RayNeo io on Mac/devserver/. The phone pins its SHA-256 (from the pairing text), so it
/// needs no CA. The identity is imported in memory only; nothing is added to the user's keychain.
struct AappDevTLS {
    let identity: SecIdentity
    let certificateDER: Data
    var fingerprint: Data { Data(SHA256.hash(data: certificateDER)) }

    enum Failure: Error, LocalizedError {
        case openssl(String), importFailed(OSStatus), noIdentity
        var errorDescription: String? {
            switch self {
            case .openssl(let text): return "生成开发证书失败：\(text)"
            case .importFailed(let status): return "导入开发证书失败（\(status)）"
            case .noIdentity: return "开发证书不完整"
            }
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RayNeo io on Mac/devserver", isDirectory: true)
    }

    /// Loads the stored identity, creating it on first use (or when it is unreadable or about to expire).
    static func load(directory: URL = directory) throws -> AappDevTLS {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p12 = directory.appendingPathComponent("identity.p12"), pass = directory.appendingPathComponent("identity.pass")
        if let tls = try? open(p12: p12, passFile: pass), !tls.expiresSoon { return tls }
        try create(p12: p12, passFile: pass, in: directory)
        return try open(p12: p12, passFile: pass)
    }

    private var expiresSoon: Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = (entry[kSecPropertyKeyValue] as? NSNumber)?.doubleValue else { return true }
        // Absolute time since 2001-01-01.
        return Date(timeIntervalSinceReferenceDate: seconds).timeIntervalSinceNow < 30 * 86_400
    }

    private static func open(p12: URL, passFile: URL) throws -> AappDevTLS {
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
        return AappDevTLS(identity: identity, certificateDER: SecCertificateCopyData(certificate) as Data)
    }

    private static func create(p12: URL, passFile: URL, in directory: URL) throws {
        let key = directory.appendingPathComponent("key.pem"), cert = directory.appendingPathComponent("cert.pem")
        let config = directory.appendingPathComponent("openssl.cnf")
        let password = AappDevProtocol.randomToken(bytes: 24)
        try """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = RayNeo io on Mac developer server
        [ext]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = serverAuth
        subjectAltName = IP:127.0.0.1
        """.write(to: config, atomically: true, encoding: .utf8)
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        // Valid from now for 397 days; the identity is reused, so a phone clock a little behind only matters in
        // the first minutes after it is created.
        try run(["req", "-new", "-x509", "-sha256", "-key", key.path, "-out", cert.path, "-days", "397", "-config", config.path])
        try password.write(to: passFile, atomically: true, encoding: .utf8)
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:\(password)",
                 "-name", "RayNeo io on Mac dev"])
        for file in [key, config] { try? FileManager.default.removeItem(at: file) }
        for file in [p12, passFile, cert] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
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
