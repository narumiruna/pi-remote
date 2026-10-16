import CryptoKit
import Foundation

public struct PairingCode: Codable, Sendable {
    public var version: Int = 1
    public var host: UUID
    public var name: String
    public var url: URL
    public var certificate: Data
    public var grant: Data
    public var expires: Date

    public init(host: UUID, name: String, url: URL, certificate: Data, grant: Data, expires: Date) {
        self.host = host; self.name = name; self.url = url; self.certificate = certificate
        self.grant = grant; self.expires = expires
    }

    public func encoded() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }

    public static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 32_768, let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteFault.invalidRequest
        }
        let code = try JSONDecoder().decode(Self.self, from: data)
        guard code.version == 1, code.url.scheme == "wss", code.url.host != nil,
              code.url.user == nil, code.url.password == nil, code.url.query == nil,
              code.grant.count == 32, !code.certificate.isEmpty, code.certificate.count < 16_384 else {
            throw RemoteFault.invalidRequest
        }
        guard code.expires > Date(), code.expires.timeIntervalSinceNow <= 300 else { throw RemoteFault.expired }
        return code
    }
}

public struct SavedMac: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var certificate: Data
    public var device: UUID
    public init(id: UUID, name: String, url: URL, certificate: Data, device: UUID) {
        self.id = id; self.name = name; self.url = url; self.certificate = certificate; self.device = device
    }
}

public enum DeviceProof {
    public static func create(secret: Data, device: UUID, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: input(device, nonce), using: SymmetricKey(data: secret)))
    }
    public static func verify(secret: Data, device: UUID, nonce: Data, proof: Data) -> Bool {
        guard secret.count == 32, nonce.count == 32, proof.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: input(device, nonce), using: SymmetricKey(data: secret))
    }
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == 32, b.count == 32 else { return false }
        let key = SymmetricKey(data: b)
        return HMAC<SHA256>.isValidAuthenticationCode(
            HMAC<SHA256>.authenticationCode(for: a, using: key), authenticating: b, using: key
        )
    }
    private static func input(_ device: UUID, _ nonce: Data) -> Data {
        Data(("PiRemote app protocol v1\0" + device.uuidString + "\0").utf8) + nonce
    }
}
