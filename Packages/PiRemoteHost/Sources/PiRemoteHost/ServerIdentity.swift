import Darwin
import Foundation
import Network
import PiRemoteCore
import PiRemoteSecurity
import Security

public struct ListenAddress: Sendable, Identifiable, Equatable {
    public var id: String { address }
    public var name: String
    public var address: String

    public static func all() -> [ListenAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var result: [ListenAddress] = []
        var node = interfaces
        while let pointer = node {
            defer { node = pointer.pointee.ifa_next }
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard allowed(ip) else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            if !result.contains(where: { $0.address == ip }) { result.append(ListenAddress(name: name, address: ip)) }
        }
        return result.sorted { $0.address < $1.address }
    }

    public static func allowed(_ string: String) -> Bool {
        guard let ip = IPv4Address(string) else { return false }
        let b = Array(ip.rawValue)
        return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) ||
            (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
    }
}

public struct ServerIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificate: Data
    public let addresses: [String]
    private struct Stored: Codable { var pkcs12: Data; var password: String; var certificate: Data; var addresses: [String] }

    public static func load(secrets: any SecretStore, support: URL) async throws -> ServerIdentity {
        if let saved = try secrets.get("server.identity") {
            return try decode(JSONDecoder().decode(Stored.self, from: saved))
        }
        let directory = support.appendingPathComponent("identity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let addresses = Array(Set(ListenAddress.all().map(\.address) + ["127.0.0.1"])).sorted()
        let password = try PairingProof.randomSecret().base64EncodedString()
        let passwordFile = directory.appendingPathComponent("password")
        try password.write(to: passwordFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
        let san = addresses.map { "IP:" + $0 }.joined(separator: ",")
        _ = try await LocalCommand.run("/usr/bin/openssl", [
            "req", "-new", "-x509", "-newkey", "rsa:2048", "-sha256",
            "-nodes", "-days", "365", "-subj", "/CN=Pi Remote",
            "-addext", "subjectAltName=" + san, "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,digitalSignature,keyCertSign", "-addext", "extendedKeyUsage=serverAuth",
            "-keyout", "key.pem", "-out", "certificate.pem"
        ], directory: directory)
        try Task.checkCancellation()
        _ = try await LocalCommand.run("/usr/bin/openssl", [
            "x509", "-in", "certificate.pem", "-outform", "DER", "-out", "certificate.der"
        ], directory: directory)
        try Task.checkCancellation()
        _ = try await LocalCommand.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", "key.pem", "-in", "certificate.pem",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-passout", "file:" + passwordFile.path, "-out", "identity.p12"
        ], directory: directory)
        let stored = Stored(
            pkcs12: try Data(contentsOf: directory.appendingPathComponent("identity.p12")), password: password,
            certificate: try Data(contentsOf: directory.appendingPathComponent("certificate.der")), addresses: addresses
        )
        let result = try decode(stored)
        try Task.checkCancellation()
        try secrets.put(JSONEncoder().encode(stored), account: "server.identity")
        return result
    }

    private static func decode(_ stored: Stored) throws -> ServerIdentity {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: stored.password, kSecImportToMemoryOnly as String: true]
        guard SecPKCS12Import(stored.pkcs12 as CFData, options as CFDictionary, &items) == errSecSuccess,
              let item = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String],
              CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else { throw RemoteFault.storageFailure }
        return ServerIdentity(identity: item as! SecIdentity, certificate: stored.certificate, addresses: stored.addresses)
    }
}
