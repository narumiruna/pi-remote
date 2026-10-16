import CryptoKit
import Foundation
import Security

public enum PairingFailure: Error, Sendable, Equatable {
    case denied
    case randomFailure
}

/// Ephemeral spike authority. Production persistence and account access are not implemented here.
public struct PairingAuthority: Sendable {
    private let approvedDevice: UUID
    private let grant: Data
    private let expiresAt: TimeInterval
    private var grantUsed = false
    private var attempts = 0
    private var credentials: [UUID: Data] = [:]

    public init(approvedDevice: UUID, grant: Data, now: TimeInterval, lifetime: TimeInterval = 120) {
        precondition(grant.count == 32 && lifetime > 0 && lifetime <= 300)
        self.approvedDevice = approvedDevice
        self.grant = grant
        expiresAt = now + lifetime
    }

    public mutating func pair(device: UUID, grant supplied: Data, now: TimeInterval) throws -> Data {
        attempts += 1
        guard attempts <= 5, !grantUsed, now < expiresAt, device == approvedDevice,
              PairingProof.matchesSecret(supplied, grant) else { throw PairingFailure.denied }
        let credential = try PairingProof.randomSecret()
        credentials[device] = credential
        grantUsed = true
        return credential
    }

    public func authenticate(device: UUID, nonce: Data, proof: Data) -> Bool {
        guard let secret = credentials[device], nonce.count == 32, proof.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: PairingProof.input(device: device, nonce: nonce),
            using: SymmetricKey(data: secret)
        )
    }

    public func contains(_ device: UUID) -> Bool { credentials[device] != nil }

    public mutating func revoke(_ device: UUID) { credentials.removeValue(forKey: device) }
}

public enum PairingProof {
    public static func randomSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PairingFailure.randomFailure
        }
        return Data(bytes)
    }

    public static func create(secret: Data, device: UUID, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: input(device: device, nonce: nonce), using: SymmetricKey(data: secret)
        ))
    }

    static func input(device: UUID, nonce: Data) -> Data {
        Data(("PiRemote transport spike v1\0" + device.uuidString + "\0").utf8) + nonce
    }

    static func matchesSecret(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 32, rhs.count == 32 else { return false }
        // Compare authentication codes rather than secret bytes with an early-exit equality check.
        return HMAC<SHA256>.isValidAuthenticationCode(
            HMAC<SHA256>.authenticationCode(for: lhs, using: SymmetricKey(data: rhs)),
            authenticating: rhs, using: SymmetricKey(data: rhs)
        )
    }
}
