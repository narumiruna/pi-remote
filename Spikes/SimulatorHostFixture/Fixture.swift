import AppKit
import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity

private final class FixtureSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private struct Fixture: Codable {
    var code: PairingCode
    var directory: String
}
private enum FixtureFailure: Error { case usage, deadline, settingsChanged, shutdownTimeout }
private final class HostLifetime {
    private weak var host: HostCoordinator?
    private let lockFile: URL
    init(_ host: HostCoordinator, lockFile: URL) { self.host = host; self.lockFile = lockFile }
    var released: Bool {
        guard host == nil else { return false }
        // Weak references can clear before stored-property destruction ends.
        // Verify that the actual exclusive catalog lock is also available.
        let descriptor = open(lockFile.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }
}

/// Test-only host. Pairing requires the UUID written by the local simulator test.
/// Explicit invocation permits provider usage and temporary file changes by Pi.
@main struct SimulatorHostFixture {
    private static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func main() async {
        do { try await run() }
        catch {
            if let fault = error as? RemoteFault { print("FAIL: simulator host fixture: \(fault).") }
            else if let failure = error as? FixtureFailure { print("FAIL: simulator host fixture: \(failure).") }
            else { print("FAIL: simulator host fixture stopped without repeating work.") }
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 4, CommandLine.arguments[3] == "--exercise-model" else { throw FixtureFailure.usage }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        let address = CommandLine.arguments[2]
        guard FileManager.default.isExecutableFile(atPath: pi.path), ListenAddress.allowed(address) else { throw FixtureFailure.usage }
        let root = URL(fileURLWithPath: "/tmp/pi-remote-simulator-fixture", isDirectory: true)
        // Never reuse a previous fixture, its grants or its session catalog.
        guard mkdir(root.path, 0o700) == 0 else { throw FixtureFailure.usage }
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        let settings = agent.appendingPathComponent("settings.json")
        let before = try settingsData(settings)
        let directory = root.appendingPathComponent("project/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = bitmap.bitmapData else { throw FixtureFailure.usage }
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = x < 16 ? 255 : 0; bytes[offset + 1] = y < 16 ? 255 : 0
                bytes[offset + 2] = 80; bytes[offset + 3] = 255
            }
        }
        guard let image = bitmap.representation(using: .png, properties: [:]) else { throw FixtureFailure.usage }
        try image.write(to: directory.appendingPathComponent("image.png"), options: .atomic)
        let wrapper = root.appendingPathComponent("isolated-pi")
        let script = """
        #!/bin/sh
        exec \(quoted(pi.path)) --offline --no-extensions --no-mcp --no-context-files --no-skills --no-prompt-templates --no-approve --tools read,write "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let secrets = FixtureSecrets()
        let identity = try await ServerIdentity.load(secrets: secrets, support: root)
        var port: UInt16 = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        while true {
            let result = try await serve(root: root, directory: directory, wrapper: wrapper, address: address,
                                         port: port, secrets: secrets, identity: identity, deadline: deadline)
            // Shutdown cancels observers and socket tasks. Their final references
            // can outlive serve's return; wait for actual catalog-lease release.
            for _ in 0..<250 {
                if result.lifetime.released { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard result.lifetime.released else { throw FixtureFailure.shutdownTimeout }
            port = result.port
            if !result.restart { break }
        }
        guard try settingsData(settings) == before else { throw FixtureFailure.settingsChanged }
        print("PASS: simulator fixture shut down cleanly; agent settings are unchanged.")
    }

    private static func settingsData(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func serve(root: URL, directory: URL, wrapper: URL, address: String, port: UInt16,
                              secrets: FixtureSecrets, identity: ServerIdentity, deadline: ContinuousClock.Instant) async throws -> (port: UInt16, restart: Bool, lifetime: HostLifetime) {
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: wrapper)
        let registry = try DeviceRegistry(secrets: secrets, metadata: root.appendingPathComponent("devices.json"))
        let server = AppServer(coordinator: host, registry: registry)
        let lifetime = HostLifetime(host, lockFile: root.appendingPathComponent("support/host.lock"))
        do {
            let bound = try await server.start(identity: identity, address: address, port: port)
            let updates = await server.pairingUpdates()
            let approval = Task {
                for await pending in updates {
                    guard !Task.isCancelled else { return }
                    if let pending {
                        let expected = try? PrivateFiles.read(UUID.self, from: root.appendingPathComponent("expected-device.json"))
                        if pending.device.id == expected { try await server.approve(pending.id) }
                        else { await server.deny(pending.id) }
                    }
                }
            }
            defer { approval.cancel() }
            if port == 0 {
                let grant = try await server.openPairing()
                let code = PairingCode(host: host.hostID, name: "Simulator fixture", url: URL(string: "wss://\(address):\(bound)/")!,
                                       certificate: identity.certificate, grant: grant, expires: Date().addingTimeInterval(120))
                try PrivateFiles.write(Fixture(code: code, directory: directory.path), to: root.appendingPathComponent("pairing.json"))
            }
            try PrivateFiles.write(host.epoch, to: root.appendingPathComponent("ready.json"))
            print("READY: simulator host fixture.")
            while ContinuousClock.now < deadline {
                let restart = root.appendingPathComponent("restart")
                let stop = root.appendingPathComponent("stop")
                if FileManager.default.fileExists(atPath: restart.path) || FileManager.default.fileExists(atPath: stop.path) {
                    let again = FileManager.default.fileExists(atPath: restart.path)
                    if again { try FileManager.default.removeItem(at: restart) }
                    try FileManager.default.removeItem(at: root.appendingPathComponent("ready.json"))
                    await server.stop(); await host.shutdown()
                    return (bound, again, lifetime)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw FixtureFailure.deadline
        } catch { await server.stop(); await host.shutdown(); throw error }
    }
}
