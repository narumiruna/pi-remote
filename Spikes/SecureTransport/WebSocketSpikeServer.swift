#if os(macOS)
import Foundation
import Network
import PiRemoteCore
import Security

/// Restricted in-memory handshake server; it cannot read directories or start Pi.
public final class WebSocketSpikeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PiRemote.transport.spike")
    private let listener: NWListener
    private var authority: PairingAuthority
    private var peers: [UUID: Peer] = [:]
    private var startup: CheckedContinuation<UInt16, any Error>?
    private var started = false

    // All mutable peer and listener state is confined to queue.
    private final class Peer: @unchecked Sendable {
        let connection: NWConnection
        let nonce: Data
        let created = ProcessInfo.processInfo.systemUptime
        var device: UUID?
        var usedChallenge = false
        var lastActivity = ProcessInfo.processInfo.systemUptime
        var timer: DispatchSourceTimer?

        init(connection: NWConnection, nonce: Data) {
            self.connection = connection
            self.nonce = nonce
        }
    }

    public init(
        identity: SecIdentity, host: IPv4Address, port: NWEndpoint.Port = .any,
        authority: PairingAuthority
    ) throws {
        let bytes = Array(host.rawValue)
        guard bytes[0] == 127 || bytes[0] == 10 ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 100 && (64...127).contains(bytes[1])) else {
            throw TransportSpikeFailure.unavailable
        }
        self.authority = authority
        let tls = NWProtocolTLS.Options()
        guard let identity = sec_identity_create(identity) else { throw TransportSpikeFailure.invalidIdentity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 16_384
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(host), port: port)
        listener = try NWListener(using: parameters)
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !started else {
                    continuation.resume(throwing: TransportSpikeFailure.unavailable)
                    return
                }
                started = true
                startup = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            startup?.resume(returning: port.rawValue)
                            startup = nil
                        }
                    case .failed(let error):
                        startup?.resume(throwing: error)
                        startup = nil
                        stopOnQueue()
                    case .cancelled:
                        startup?.resume(throwing: TransportSpikeFailure.unavailable)
                        startup = nil
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, startup != nil else { return }
                    startup?.resume(throwing: TransportSpikeFailure.timedOut)
                    startup = nil
                    stopOnQueue()
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in stopOnQueue(); continuation.resume() }
        }
    }

    public func revoke(_ device: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                authority.revoke(device)
                for id in peers.keys.filter({ peers[$0]?.device == device }) { remove(id) }
                continuation.resume()
            }
        }
    }

    private func stopOnQueue() {
        startup?.resume(throwing: TransportSpikeFailure.unavailable)
        startup = nil
        listener.cancel()
        for id in Array(peers.keys) { remove(id) }
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < 16, let nonce = try? PairingProof.randomSecret() else {
            connection.cancel()
            return
        }
        let id = UUID()
        let peer = Peer(connection: connection, nonce: nonce)
        peers[id] = peer
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, let peer = peers[id] else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if (peer.device == nil && now - peer.created >= 10) || now - peer.lastActivity >= 30 {
                remove(id)
            }
        }
        peer.timer = timer
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: send(.challenge(nonce: nonce), to: id)
            case .failed, .cancelled: remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receiveMessage { [weak self] data, context, complete, error in
            guard let self, peers[id] != nil else { return }
            guard error == nil, complete,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                remove(id)
                return
            }
            if metadata.opcode == .ping || metadata.opcode == .pong { receive(id); return }
            guard metadata.opcode == .binary || metadata.opcode == .text,
                  let data, let message = try? TransportSpikeMessage.decode(data) else {
                remove(id)
                return
            }
            handle(message.payload, peer: peer, id: id)
        }
    }

    private func handle(_ payload: TransportSpikePayload, peer: Peer, id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - peer.lastActivity < 30, peer.device != nil || now - peer.created < 10 else {
            remove(id)
            return
        }
        peer.lastActivity = now
        switch payload {
        case .pair(let device, let grant) where !peer.usedChallenge && peer.device == nil:
            peer.usedChallenge = true
            do {
                let secret = try authority.pair(
                    device: device, grant: grant, now: ProcessInfo.processInfo.systemUptime
                )
                // Pairing returns a credential but does not authenticate this connection.
                send(.paired(credential: secret), to: id, closeAfter: true)
            } catch { send(.denied, to: id, closeAfter: true) }
        case .authenticate(let device, let proof) where !peer.usedChallenge && peer.device == nil:
            peer.usedChallenge = true
            guard authority.authenticate(device: device, nonce: peer.nonce, proof: proof) else {
                send(.denied, to: id, closeAfter: true)
                return
            }
            peer.device = device
            send(.authenticated, to: id)
        case .ping(let requestID):
            guard let device = peer.device, authority.contains(device) else {
                send(.denied, to: id, closeAfter: true)
                return
            }
            send(.pong(id: requestID), to: id)
        default: send(.denied, to: id, closeAfter: true)
        }
    }

    private func send(_ payload: TransportSpikePayload, to id: UUID, closeAfter: Bool = false) {
        guard let peer = peers[id], let data = try? TransportSpikeMessage(payload).encode() else {
            remove(id)
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "spike", metadata: [metadata])
        peer.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if closeAfter || error != nil { remove(id) }
            else { receive(id) }
        })
    }

    private func remove(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timer?.cancel()
        peer.connection.stateUpdateHandler = nil
        peer.connection.cancel()
    }
}
#endif
