import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import PiRemoteCore
import Security

/// Socket-based TLS avoids Network.framework's local VPN flow collision.
final class SecureListener: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let context: NIOSSLContext
    private var channel: Channel?
    private let lock = NSLock()
    private var peers: [ObjectIdentifier: Channel] = [:]
    private var stopTask: Task<Void, Never>?

    init(identity: ServerIdentity) throws {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity.identity, &key) == errSecSuccess, let key,
              let encoded = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw RemoteFault.storageFailure }
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificate), format: .der)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(encoded), format: .der)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(privateKey))
        configuration.minimumTLSVersion = .tlsv12
        context = try NIOSSLContext(configuration: configuration)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func start(address: String, port: UInt16, accepted: @escaping @Sendable (SecurePeer) -> Void) async throws -> UInt16 {
        let context = context
        let bound = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: true)
            .childChannelInitializer { [self] channel in
                let admitted = lock.withLock {
                    guard stopTask == nil, peers.count < 16 else { return false }
                    peers[ObjectIdentifier(channel)] = channel
                    return true
                }
                guard admitted else { return channel.eventLoop.makeFailedFuture(RemoteFault.capacity) }
                let lifecycle = HandshakeGuard { [self] in _ = lock.withLock { peers.removeValue(forKey: ObjectIdentifier(channel)) } }
                let peer = SecurePeer(channel: channel)
                let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 4 * 1_024 * 1_024, automaticErrorHandling: true,
                    shouldUpgrade: { channel, request in
                        channel.eventLoop.makeSucceededFuture(request.uri == "/" && request.method == .GET ? HTTPHeaders() : nil)
                    }, upgradePipelineHandler: { channel, _ in
                        lifecycle.upgraded()
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(PeerFrames(peer: peer))
                            accepted(peer)
                        }
                    })
                do {
                    try channel.pipeline.syncOperations.addHandler(lifecycle)
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            .bind(host: address, port: Int(port)).get()
        let stopped = lock.withLock {
            guard stopTask == nil else { return true }
            channel = bound
            return false
        }
        guard !stopped else { try? await bound.close().get(); throw RemoteFault.cancelled }
        guard let port = bound.localAddress?.port, let result = UInt16(exactly: port) else { throw RemoteFault.unavailable }
        return result
    }

    func stop() async {
        let task = lock.withLock {
            if let stopTask { return stopTask }
            let task = Task { [self] in
                let channels = lock.withLock { [channel].compactMap { $0 } + Array(peers.values) }
                for channel in channels { try? await channel.close().get() }
                try? await group.shutdownGracefully()
            }
            stopTask = task
            return task
        }
        await task.value
    }
}

private final class HandshakeGuard: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var timeout: Scheduled<Void>?
    private let closed: @Sendable () -> Void
    init(closed: @escaping @Sendable () -> Void) { self.closed = closed }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
    }
    func upgraded() { timeout?.cancel(); timeout = nil }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel(); closed(); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

/// Mutable receive state belongs to the channel's event loop, not an unbounded task queue.
final class SecurePeer: @unchecked Sendable {
    private let channel: Channel
    private var pending: (@Sendable (Data?, (any Error)?) -> Void)?
    private var inbox: [Data] = []
    private var bytes = 0
    private var ended = false
    init(channel: Channel) { self.channel = channel }
    func receive(_ callback: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        channel.eventLoop.execute { [self] in
            if ended { callback(nil, RemoteFault.unavailable) }
            else if !inbox.isEmpty { let data = inbox.removeFirst(); bytes -= data.count; callback(data, nil) }
            else { pending = callback }
        }
    }
    func deliver(_ data: Data) {
        guard !ended else { return }
        if let callback = pending { pending = nil; callback(data, nil) }
        else if inbox.count < 8 && bytes + data.count <= 8 * 1_024 * 1_024 { inbox.append(data); bytes += data.count }
        else { finish(); cancel() }
    }
    func finish() {
        ended = true; inbox = []; bytes = 0
        let callback = pending; pending = nil
        callback?(nil, RemoteFault.unavailable)
    }
    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        channel.eventLoop.execute { [self] in
            let frame = WebSocketFrame(fin: true, opcode: .binary, data: channel.allocator.buffer(bytes: data))
            channel.writeAndFlush(frame).whenComplete { result in
                switch result { case .success: completion(nil); case .failure(let error): completion(error) }
            }
        }
    }
    func cancel() { channel.close(promise: nil) }
}

final class PeerFrames: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let peer: SecurePeer
    private var fragments: Data?
    init(peer: SecurePeer) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3,
              frame.length <= 4 * 1_024 * 1_024,
              !frame.opcode.isControlOpcode || (frame.fin && frame.length <= 125) else {
            context.close(promise: nil); return
        }
        var buffer = frame.unmaskedData
        let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        switch frame.opcode {
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: context.channel.allocator.buffer(bytes: bytes))), promise: nil)
        case .pong: break
        case .connectionClose: context.close(promise: nil)
        case .text, .binary:
            guard fragments == nil else { context.close(promise: nil); return }
            if frame.fin { peer.deliver(bytes) } else { fragments = bytes }
        case .continuation:
            guard var partial = fragments, partial.count + bytes.count <= 4 * 1_024 * 1_024 else { context.close(promise: nil); return }
            partial.append(bytes)
            if frame.fin { fragments = nil; peer.deliver(partial) } else { fragments = partial }
        default: context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { peer.finish(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { peer.finish(); context.close(promise: nil) }
}
