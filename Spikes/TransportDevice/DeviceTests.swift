import Foundation
import PiRemoteCore
import XCTest

private struct Fixture: Decodable {
    let url: URL
    let certificate: Data
    let rejectedCertificate: Data
    let device: UUID
    let grant: Data
}

@MainActor
final class TransportDeviceTests: XCTestCase {
    func testPinnedPairingAndAuthenticatedReconnection() async throws {
        let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "client", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: resource))
        // Remove only this fixture's credential if an earlier diagnostic run was interrupted.
        try DeviceCredential.delete(device: fixture.device)
        defer {
            do { try DeviceCredential.delete(device: fixture.device) }
            catch { XCTFail("The diagnostic credential could not be removed from Keychain.") }
        }

        // Reject a changed identity before sending any grant or device credential.
        let changed = try PinnedWebSocket(url: fixture.url, certificate: fixture.rejectedCertificate)
        do {
            _ = try await changed.receive()
            XCTFail("The changed certificate was accepted.")
        } catch {
            XCTAssertTrue(changed.didRejectIdentity, "The connection failed before verifying the certificate.")
        }
        changed.close()

        let unpaired = try PinnedWebSocket(url: fixture.url, certificate: fixture.certificate)
        do {
            guard case .challenge = try await unpaired.receive() else { throw TransportSpikeFailure.invalidMessage }
            try await unpaired.send(.ping(id: UUID()))
            let response = try await unpaired.receive()
            XCTAssertEqual(response, .denied)
        } catch { unpaired.close(); throw error }
        unpaired.close()

        let pairing = try PinnedWebSocket(url: fixture.url, certificate: fixture.certificate)
        let credential: Data
        do {
            guard case .challenge = try await pairing.receive() else { throw TransportSpikeFailure.invalidMessage }
            try await pairing.send(.pair(device: fixture.device, grant: fixture.grant))
            guard case .paired(let secret) = try await pairing.receive() else { throw PairingFailure.denied }
            credential = secret
        } catch { pairing.close(); throw error }
        pairing.close()
        try DeviceCredential.save(credential, device: fixture.device)

        // A consumed grant cannot issue another device credential.
        let repeated = try PinnedWebSocket(url: fixture.url, certificate: fixture.certificate)
        do {
            _ = try await repeated.receive()
            try await repeated.send(.pair(device: fixture.device, grant: fixture.grant))
            let response = try await repeated.receive()
            XCTAssertEqual(response, .denied)
        } catch { repeated.close(); throw error }
        repeated.close()

        var previousProof: Data?
        for _ in 0..<2 {
            let client = try PinnedWebSocket(url: fixture.url, certificate: fixture.certificate)
            do {
                guard case .challenge(let nonce) = try await client.receive() else { throw TransportSpikeFailure.invalidMessage }
                let stored = try DeviceCredential.load(device: fixture.device)
                XCTAssertTrue(stored == credential)
                let proof = PairingProof.create(secret: stored, device: fixture.device, nonce: nonce)
                try await client.send(.authenticate(device: fixture.device, proof: proof))
                let response = try await client.receive()
                XCTAssertEqual(response, .authenticated)
                let id = UUID()
                try await client.send(.ping(id: id))
                let pong = try await client.receive()
                XCTAssertEqual(pong, .pong(id: id))
                previousProof = proof
            } catch { client.close(); throw error }
            client.close()
        }

        // A proof from a previous socket must fail against a fresh challenge.
        let replay = try PinnedWebSocket(url: fixture.url, certificate: fixture.certificate)
        do {
            _ = try await replay.receive()
            try await replay.send(.authenticate(device: fixture.device, proof: try XCTUnwrap(previousProof)))
            let response = try await replay.receive()
            XCTAssertEqual(response, .denied)
        } catch { replay.close(); throw error }
        replay.close()
    }
}
