import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
import PiRemoteConnection
import PiRemoteCore
import Security
@testable import PiRemoteHost
import Testing

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Data?
    private var failed = false
    func accept(_ data: Data?, _ error: (any Error)?) { lock.withLock { result = data; failed = error != nil } }
    var data: Data? { lock.withLock { result } }
    var error: Bool { lock.withLock { failed } }
}

private func frame(_ text: String, opcode: WebSocketOpcode = .binary, fin: Bool = true) -> WebSocketFrame {
    let mask: WebSocketMaskingKey = [1, 2, 3, 4]
    var data = ByteBuffer(string: text)
    data.webSocketMask(mask)
    return WebSocketFrame(fin: fin, opcode: opcode, maskKey: mask, data: data)
}

@Test func fragmentedFramesAndPingPreserveOneMessage() throws {
    let channel = EmbeddedChannel()
    let peer = SecurePeer(channel: channel), received = Received()
    try channel.pipeline.syncOperations.addHandler(PeerFrames(peer: peer))
    defer { _ = try? channel.finish() }
    peer.receive { received.accept($0, $1) }; channel.embeddedEventLoop.run()
    try channel.writeInbound(frame("first", opcode: .text, fin: false))
    try channel.writeInbound(frame("probe", opcode: .ping))
    #expect(received.data == nil)
    let output = try channel.readOutbound(as: WebSocketFrame.self)
    let pong = try #require(output)
    #expect(pong.opcode == .pong && pong.maskKey == nil)
    #expect(pong.data == ByteBuffer(string: "probe"))
    try channel.writeInbound(frame("second", opcode: .continuation))
    #expect(received.data == Data("firstsecond".utf8))
    #expect(!received.error)
}

@Test(arguments: ["unmasked", "reserved", "orphan", "overlap", "oversized", "fragmented-ping", "large-ping"])
func malformedFramesCloseTheConnection(kind: String) throws {
    let channel = EmbeddedChannel()
    let peer = SecurePeer(channel: channel), received = Received()
    try channel.pipeline.syncOperations.addHandler(PeerFrames(peer: peer))
    peer.receive { received.accept($0, $1) }; channel.embeddedEventLoop.run()
    var input = frame("test")
    switch kind {
    case "unmasked": input.maskKey = nil
    case "reserved": input.rsv1 = true
    case "orphan": input.opcode = .continuation
    case "overlap": try channel.writeInbound(frame("first", fin: false))
    case "oversized": input = frame(String(repeating: "x", count: 4 * 1_024 * 1_024 + 1))
    case "fragmented-ping": input = frame("ping", opcode: .ping, fin: false)
    case "large-ping": input = frame(String(repeating: "x", count: 126), opcode: .ping)
    default: Issue.record("Unknown frame fixture")
    }
    try channel.writeInbound(input)
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    #expect(received.error)
    #expect(received.data == nil)
    _ = try channel.finish(acceptAlreadyClosed: true)
}

@Test func receiveOverflowClosesInsteadOfKeepingAnUnlimitedQueue() throws {
    let channel = EmbeddedChannel()
    let peer = SecurePeer(channel: channel)
    try channel.pipeline.syncOperations.addHandler(PeerFrames(peer: peer))
    for _ in 0..<9 { try channel.writeInbound(frame("queued")) }
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    let received = Received()
    peer.receive { received.accept($0, $1) }; channel.embeddedEventLoop.run()
    #expect(received.error && received.data == nil)
    _ = try channel.finish(acceptAlreadyClosed: true)
}

@Test(.timeLimit(.minutes(1)), arguments: ["expired", "future"])
func invalidCertificateDatesFailBeforeWebSocketUpgrade(period: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let password = "fixture-only-" + UUID().uuidString
    try password.write(to: root.appendingPathComponent("password"), atomically: true, encoding: .utf8)
    let configuration = """
    [ca]
    default_ca=fixture
    [fixture]
    database=index
    serial=serial
    default_md=sha256
    default_days=365
    policy=policy
    new_certs_dir=.
    x509_extensions=extensions
    [policy]
    commonName=supplied
    [extensions]
    subjectAltName=IP:127.0.0.1
    basicConstraints=critical,CA:TRUE
    keyUsage=critical,digitalSignature,keyCertSign
    extendedKeyUsage=serverAuth
    """
    try configuration.write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    try Data().write(to: root.appendingPathComponent("index"))
    try "01\n".write(to: root.appendingPathComponent("serial"), atomically: true, encoding: .utf8)
    _ = try await LocalCommand.run("/usr/bin/openssl", [
        "req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes", "-subj", "/CN=Date fixture",
        "-keyout", "key.pem", "-out", "request.csr"
    ], directory: root)
    let start = period == "expired" ? "20200101000000Z" : "20990101000000Z"
    let end = period == "expired" ? "20200102000000Z" : "20990102000000Z"
    _ = try await LocalCommand.run("/usr/bin/openssl", [
        "ca", "-config", "config", "-selfsign", "-batch", "-startdate", start, "-enddate", end,
        "-in", "request.csr", "-keyfile", "key.pem", "-out", "certificate.pem"
    ], directory: root)
    _ = try await LocalCommand.run("/usr/bin/openssl", ["x509", "-in", "certificate.pem", "-outform", "DER", "-out", "certificate.der"], directory: root)
    _ = try await LocalCommand.run("/usr/bin/openssl", [
        "pkcs12", "-export", "-inkey", "key.pem", "-in", "certificate.pem",
        "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        "-passout", "file:" + root.appendingPathComponent("password").path, "-out", "identity.p12"
    ], directory: root)
    var imported: CFArray?
    let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
    let status = SecPKCS12Import(try Data(contentsOf: root.appendingPathComponent("identity.p12")) as CFData, options as CFDictionary, &imported)
    #expect(status == errSecSuccess)
    let item = try #require((imported as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
    let certificate = try Data(contentsOf: root.appendingPathComponent("certificate.der"))
    let leaf = try #require(SecCertificateCreateWithData(nil, certificate as CFData))
    if period == "expired" { #expect((SecCertificateCopyNotValidAfterDate(leaf) as Date?)! < Date()) }
    else { #expect((SecCertificateCopyNotValidBeforeDate(leaf) as Date?)! > Date()) }
    let identity = ServerIdentity(identity: item as! SecIdentity, certificate: certificate, addresses: ["127.0.0.1"])
    let listener = try SecureListener(identity: identity), upgraded = Received()
    do {
        let port = try await listener.start(address: "127.0.0.1", port: 0) { _ in upgraded.accept(Data([1]), nil) }
        let client = try PinnedChannel(url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: certificate)
        defer { client.close() }
        await #expect(throws: (any Error).self) { try await client.receive(timeout: 3) }
        #expect(client.didRejectIdentity)
        #expect(upgraded.data == nil)
    } catch { await listener.stop(); throw error }
    await listener.stop()
}
