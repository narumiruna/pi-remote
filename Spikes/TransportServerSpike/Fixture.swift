import Foundation
import Network
import PiRemoteCore
import PiRemoteTransport

struct Fixture: Codable {
    var url: URL
    let certificate: Data
    let rejectedCertificate: Data
    let device: UUID
    let grant: Data
}

@main
struct TransportServerSpike {
    static func main() async {
        do { try await run() }
        catch {
            if let error = error as? NWError {
                switch error {
                case .posix(let code): fputs("Listener POSIX error: \(code.rawValue).\n", stderr)
                case .tls(let code): fputs("Listener TLS error: \(code).\n", stderr)
                case .dns(let code): fputs("Listener DNS error: \(code).\n", stderr)
                default: fputs("Other listener error.\n", stderr)
                }
            } else {
                fputs("Transport spike failed: \(type(of: error)). No secrets are printed.\n", stderr)
            }
            exit(1)
        }
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw TransportSpikeFailure.invalidMessage }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        if args[0] == "prepare", args.count == 4,
           IPv4Address(args[2]) != nil, let port = UInt16(args[3]), port > 0 {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("generate-transport-identity.sh")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, directory.path, args[2]]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw TransportSpikeFailure.invalidIdentity }
            let fixture = Fixture(
                url: URL(string: "wss://\(args[2]):\(port)/")!,
                certificate: try Data(contentsOf: directory.appendingPathComponent("certificate.der")),
                rejectedCertificate: try Data(contentsOf: directory.appendingPathComponent("rejected.der")),
                device: UUID(), grant: try PairingProof.randomSecret()
            )
            let file = directory.appendingPathComponent("client.json")
            try JSONEncoder().encode(fixture).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            print("Private test fixture prepared. It expires after one day; do not commit its contents.")
            return
        }
        guard args[0] == "serve", args.count == 2 else { throw TransportSpikeFailure.invalidMessage }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("client.json")))
        guard let hostName = fixture.url.host, let host = IPv4Address(hostName),
              let portNumber = fixture.url.port, let number = UInt16(exactly: portNumber), number > 0,
              let port = NWEndpoint.Port(rawValue: number) else {
            throw TransportSpikeFailure.invalidMessage
        }
        let identity = try SpikeIdentity.load(
            pkcs12: Data(contentsOf: directory.appendingPathComponent("identity.p12")),
            password: String(contentsOf: directory.appendingPathComponent("password.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let server = try WebSocketSpikeServer(
            identity: identity, host: host, port: port,
            authority: PairingAuthority(
                approvedDevice: fixture.device, grant: fixture.grant,
                now: ProcessInfo.processInfo.systemUptime, lifetime: 300
            )
        )
        let listeningPort = try await server.start()
        print("Restricted TLS WebSocket spike listening on port \(listeningPort) for at most five minutes.")
        fflush(stdout)
        // Starting this local process approves only the fixture's device and pinned identity.
        // No Pi process, filesystem API, or general RPC endpoint is available.
        try await Task.sleep(for: .seconds(300))
        await server.stop()
    }
}
