import Foundation
import Network
import PiRemoteCore
import Testing
@testable import PiRemoteTransport

private struct Environment {
    let directory: URL
    let certificate: Data
    let rejectedCertificate: Data
    let grant: Data
    let device: UUID
    let server: WebSocketSpikeServer
    let port: UInt16

    static func start(port requestedPort: NWEndpoint.Port = .any) async throws -> Environment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("Spikes/generate-transport-identity.sh").path, directory.path, "127.0.0.1"]
        let sink = FileHandle.nullDevice
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw TransportSpikeFailure.invalidIdentity }
            let identity = try SpikeIdentity.load(
                pkcs12: Data(contentsOf: directory.appendingPathComponent("identity.p12")),
                password: String(contentsOf: directory.appendingPathComponent("password.txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let device = UUID()
            let grant = try PairingProof.randomSecret()
            let server = try WebSocketSpikeServer(
                identity: identity, host: IPv4Address.loopback, port: requestedPort,
                authority: PairingAuthority(approvedDevice: device, grant: grant, now: ProcessInfo.processInfo.systemUptime)
            )
            let port = try await server.start()
            return Environment(
                directory: directory,
                certificate: try Data(contentsOf: directory.appendingPathComponent("certificate.der")),
                rejectedCertificate: try Data(contentsOf: directory.appendingPathComponent("rejected.der")),
                grant: grant, device: device, server: server, port: port
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func client(certificate: Data? = nil) throws -> PinnedWebSocket {
        try PinnedWebSocket(
            url: URL(string: "wss://127.0.0.1:\(port)/")!,
            certificate: certificate ?? self.certificate
        )
    }

    func pair() async throws -> Data {
        let client = try client()
        defer { client.close() }
        guard case .challenge = try await client.receive() else { throw TransportSpikeFailure.invalidMessage }
        try await client.send(.pair(device: device, grant: grant))
        guard case .paired(let secret) = try await client.receive() else { throw PairingFailure.denied }
        return secret
    }

    func authenticate(_ client: PinnedWebSocket, secret: Data) async throws {
        guard case .challenge(let nonce) = try await client.receive() else { throw TransportSpikeFailure.invalidMessage }
        try await client.send(.authenticate(device: device, proof: PairingProof.create(secret: secret, device: device, nonce: nonce)))
        #expect(try await client.receive() == .authenticated)
    }

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func pairsReconnectsRejectsUnauthorizedAndRevokesActiveConnection() async throws {
    let environment = try await Environment.start()
    do {
        let unpaired = try environment.client()
        defer { unpaired.close() }
        _ = try await unpaired.receive()
        try await unpaired.send(.ping(id: UUID()))
        #expect(try await unpaired.receive() == .denied)

        let secret = try await environment.pair()
        for _ in 0..<2 {
            let client = try environment.client()
            do {
                try await environment.authenticate(client, secret: secret)
                let request = UUID()
                try await client.send(.ping(id: request))
                #expect(try await client.receive() == .pong(id: request))
                client.close()
            } catch { client.close(); throw error }
        }

        let active = try environment.client()
        defer { active.close() }
        try await environment.authenticate(active, secret: secret)
        await environment.server.revoke(environment.device)
        await #expect(throws: (any Error).self) { try await active.receive() }

        let revoked = try environment.client()
        defer { revoked.close() }
        guard case .challenge(let nonce) = try await revoked.receive() else { throw TransportSpikeFailure.invalidMessage }
        try await revoked.send(.authenticate(
            device: environment.device,
            proof: PairingProof.create(secret: secret, device: environment.device, nonce: nonce)
        ))
        #expect(try await revoked.receive() == .denied)
    } catch { await environment.stop(); throw error }
    await environment.stop()
}

@Test func cancellationClosesAPendingReceive() async throws {
    let environment = try await Environment.start()
    let client = try environment.client()
    do {
        _ = try await client.receive()
        let pending = Task { try await client.receive() }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
    } catch { client.close(); await environment.stop(); throw error }
    client.close()
    await environment.stop()
}

@Test func bindsAnExplicitPort() async throws {
    let first = try await Environment.start()
    let port = first.port
    await first.stop()
    let rebound = try await Environment.start(port: NWEndpoint.Port(rawValue: port)!)
    #expect(rebound.port == port)
    await rebound.stop()
}

@Test func rejectsHostnameMismatchEvenWithTheExactCertificatePin() async throws {
    let environment = try await Environment.start()
    let client = try PinnedWebSocket(
        url: URL(string: "wss://localhost:\(environment.port)/")!, certificate: environment.certificate
    )
    await #expect(throws: (any Error).self) { try await client.receive() }
    #expect(client.didRejectIdentity)
    client.close()
    await environment.stop()
}

@Test func rejectsChangedCertificateWithoutSendingCredentials() async throws {
    let environment = try await Environment.start()
    let client = try environment.client(certificate: environment.rejectedCertificate)
    do {
        await #expect(throws: (any Error).self) { try await client.receive() }
        #expect(client.didRejectIdentity)
        client.close()
    }
    await environment.stop()
}
