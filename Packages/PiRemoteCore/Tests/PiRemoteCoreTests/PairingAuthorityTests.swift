import Foundation
import Testing
@testable import PiRemoteCore

@Test func pairsOnlyLocallyApprovedDeviceAndConsumesGrant() throws {
    let device = UUID()
    let grant = try PairingProof.randomSecret()
    var authority = PairingAuthority(approvedDevice: device, grant: grant, now: 0)
    #expect(throws: PairingFailure.denied) { try authority.pair(device: UUID(), grant: grant, now: 1) }
    let credential = try authority.pair(device: device, grant: grant, now: 1)
    #expect(credential.count == 32)
    #expect(throws: PairingFailure.denied) { try authority.pair(device: device, grant: grant, now: 2) }
}

@Test func expiresAndRateLimitsPairing() throws {
    let device = UUID()
    let grant = try PairingProof.randomSecret()
    var expired = PairingAuthority(approvedDevice: device, grant: grant, now: 0, lifetime: 10)
    #expect(throws: PairingFailure.denied) { try expired.pair(device: device, grant: grant, now: 10) }
    var limited = PairingAuthority(approvedDevice: device, grant: grant, now: 0)
    for _ in 0..<5 {
        #expect(throws: PairingFailure.denied) {
            try limited.pair(device: device, grant: Data(repeating: 0, count: 32), now: 1)
        }
    }
    #expect(throws: PairingFailure.denied) { try limited.pair(device: device, grant: grant, now: 1) }
}

@Test func rejectsReplayUnpairedDevicesAndRevokedCredentials() throws {
    let device = UUID()
    let grant = try PairingProof.randomSecret()
    var authority = PairingAuthority(approvedDevice: device, grant: grant, now: 0)
    let secret = try authority.pair(device: device, grant: grant, now: 1)
    let nonce = try PairingProof.randomSecret()
    let proof = PairingProof.create(secret: secret, device: device, nonce: nonce)
    #expect(authority.authenticate(device: device, nonce: nonce, proof: proof))
    #expect(!authority.authenticate(device: UUID(), nonce: nonce, proof: proof))
    #expect(!authority.authenticate(device: device, nonce: try PairingProof.randomSecret(), proof: proof))
    #expect(!authority.authenticate(device: device, nonce: nonce, proof: Data()))
    authority.revoke(device)
    #expect(!authority.contains(device))
    #expect(!authority.authenticate(device: device, nonce: nonce, proof: proof))
}

@Test func roundTripsTypedHandshakeAndRejectsVersions() throws {
    let message = TransportSpikeMessage(.pair(device: UUID(), grant: try PairingProof.randomSecret()))
    #expect(try TransportSpikeMessage.decode(message.encode()) == message)
    #expect(throws: TransportSpikeFailure.unsupportedVersion) {
        try TransportSpikeMessage.decode(TransportSpikeMessage(.authenticated, version: 2).encode())
    }
    #expect(throws: TransportSpikeFailure.messageTooLarge) {
        try TransportSpikeMessage.decode(Data(repeating: 0, count: 16_385))
    }
}
