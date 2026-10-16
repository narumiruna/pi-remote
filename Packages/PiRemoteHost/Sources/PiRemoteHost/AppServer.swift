import Foundation
import Network
import PiRemoteCore
import Security

public final class AuthorizationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    public init() {}
    public var valid: Bool { lock.withLock { allowed } }
    public func revoke() { lock.withLock { allowed = false } }
}

public struct PendingPair: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var device: PairedDevice
}

public actor AppServer {
    private enum Phase { case challenge, pending, authenticated(UUID) }
    private struct Peer {
        var connection: NWConnection
        var nonce: Data
        var phase: Phase = .challenge
        var deadline = ProcessInfo.processInfo.systemUptime + 10
        var lease = AuthorizationLease()
        var requests: [UUID: Task<Void, Never>] = [:]
        var outbox: [Data] = []
        var latestState: Data?
        var sending = false
        var closing = false
    }
    private let coordinator: HostCoordinator
    private let registry: DeviceRegistry
    private let queue = DispatchQueue(label: "PiRemote.network")
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, any Error>?
    private var peers: [UUID: Peer] = [:]
    private var pending: PendingPair?
    private var pairingObservers: [UUID: AsyncStream<PendingPair?>.Continuation] = [:]
    private var timer: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var running = false

    public init(coordinator: HostCoordinator, registry: DeviceRegistry) {
        self.coordinator = coordinator; self.registry = registry
    }

    public func isRunning() -> Bool { running }

    public func pairingUpdates() -> AsyncStream<PendingPair?> {
        let id = UUID()
        let result = AsyncStream<PendingPair?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pairingObservers[id] = result.continuation
        result.continuation.yield(pending)
        result.continuation.onTermination = { [weak self] _ in Task { await self?.removePairObserver(id) } }
        return result.stream
    }
    private func removePairObserver(_ id: UUID) { pairingObservers.removeValue(forKey: id) }
    private func publishPair(_ value: PendingPair?) {
        pending = value
        for observer in pairingObservers.values { observer.yield(value) }
    }

    public func start(identity: ServerIdentity, address: String, port: UInt16 = 7443) async throws -> UInt16 {
        guard !running, ListenAddress.allowed(address), identity.addresses.contains(address), let host = IPv4Address(address) else {
            throw RemoteFault.invalidRequest
        }
        let tls = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create(identity.identity) else { throw RemoteFault.storageFailure }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = 4 * 1_024 * 1_024; webSocket.autoReplyPing = true
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener; running = true
        let actualPort = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerState(state) } }
                listener.newConnectionHandler = { [weak self] connection in
                    Task {
                        guard let self else { connection.cancel(); return }
                        await self.accept(connection)
                    }
                }
                listener.start(queue: queue)
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.failStartup()
                }
            }
        } onCancel: { [weak self] in Task { await self?.stop() } }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                await self.sweep()
            }
        }
        let states = await coordinator.updates()
        observation = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled, let self else { return }
                await self.broadcast(state)
            }
        }
        return actualPort
    }

    private func listenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            if let port = listener?.port { startup?.resume(returning: port.rawValue); startup = nil; startupTimeout?.cancel() }
        case .failed, .cancelled: await stop()
        default: break
        }
    }
    private func failStartup() async { startup?.resume(throwing: RemoteFault.unavailable); startup = nil; await stop() }

    public func openPairing() async throws -> Data {
        guard running else { throw RemoteFault.unavailable }
        await closePairing()
        return try await registry.openWindow()
    }
    public func closePairing() async {
        await registry.closeWindow()
        if let pending { remove(pending.id) }
        publishPair(nil)
    }
    public func approve(_ connection: UUID) async throws {
        guard let peer = peers[connection], case .pending = peer.phase, peer.deadline > ProcessInfo.processInfo.systemUptime else { throw RemoteFault.expired }
        let credential = try await registry.approve(connection: connection)
        guard peers[connection] != nil else { throw RemoteFault.expired }
        send(.paired(credential: credential, host: coordinator.hostID), to: connection, closeAfter: true)
        publishPair(nil)
    }
    public func deny(_ connection: UUID) async {
        await registry.closeWindow()
        send(.denied, to: connection, closeAfter: true); publishPair(nil)
    }
    public func revoke(_ device: UUID) async throws {
        // Close leases before persistence, so queued network tasks cannot dispatch more work.
        for id in peers.keys.filter({ id in
            if case .authenticated(let value) = peers[id]?.phase { return value == device }; return false
        }) { remove(id) }
        do { try await registry.revoke(device) }
        catch { await stop(); throw error }
    }

    private func accept(_ connection: NWConnection) {
        guard running, peers.count < 16, let nonce = try? PairingProof.randomSecret() else { connection.cancel(); return }
        let id = UUID()
        peers[id] = Peer(connection: connection, nonce: nonce)
        connection.stateUpdateHandler = { [weak self] state in Task { await self?.connectionState(state, id: id) } }
        connection.start(queue: queue)
    }
    private func connectionState(_ state: NWConnection.State, id: UUID) {
        switch state {
        case .ready:
            guard let peer = peers[id] else { return }
            send(.challenge(nonce: peer.nonce), to: id); receive(id)
        case .failed, .cancelled: remove(id)
        default: break
        }
    }
    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receiveMessage { [weak self] data, context, complete, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            Task { await self?.received(id, data: data, opcode: opcode, complete: complete, error: error) }
        }
    }
    private func received(_ id: UUID, data: Data?, opcode: NWProtocolWebSocket.Opcode?, complete: Bool, error: NWError?) async {
        guard let peer = peers[id], peer.deadline > ProcessInfo.processInfo.systemUptime, error == nil, complete else { remove(id); return }
        if opcode == .ping || opcode == .pong { receive(id); return }
        guard opcode == .text || opcode == .binary, let data,
              let packet = try? AppPacket<ClientMessage>.decode(data) else { remove(id); return }
        switch (peer.phase, packet.payload) {
        case (.challenge, .pair(let device, let name, let grant)):
            peers[id]?.phase = .pending; peers[id]?.deadline = ProcessInfo.processInfo.systemUptime + 120
            do {
                let item = try await registry.request(connection: id, device: device, name: name, grant: grant)
                guard peers[id] != nil else { await registry.closeWindow(); return }
                publishPair(PendingPair(id: id, device: item)); send(.approvalRequired, to: id)
            } catch { send(.denied, to: id, closeAfter: true); return }
        case (.challenge, .authenticate(let device, let proof)):
            // Consume this connection's nonce before awaiting the credential lookup.
            peers[id]?.phase = .pending
            do {
                guard try await registry.verify(device: device, nonce: peer.nonce, proof: proof), peers[id] != nil else {
                    send(.denied, to: id, closeAfter: true); return
                }
                peers[id]?.phase = .authenticated(device)
                peers[id]?.deadline = ProcessInfo.processInfo.systemUptime + 60
                send(.authenticated(host: coordinator.hostID, epoch: coordinator.epoch), to: id)
            } catch { send(.denied, to: id, closeAfter: true); return }
        case (.authenticated(let device), .request(let request)):
            guard await registry.contains(device), peers[id] != nil, peer.lease.valid else { remove(id); return }
            guard peers[id]!.requests.count < 8, peers[id]!.requests[request.id] == nil else {
                send(.reply(id: request.id, result: .failure(.capacity), state: nil), to: id); receive(id); return
            }
            peers[id]?.deadline = ProcessInfo.processInfo.systemUptime + 60
            peers[id]?.requests[request.id] = Task { [weak self, coordinator] in
                let result = await coordinator.handle(request, device: device, authorization: peer.lease)
                let state = request.action.mutates ? await coordinator.state() : nil
                await self?.completed(request.id, peer: id, result: result, state: state)
            }
        default: send(.denied, to: id, closeAfter: true); return
        }
        receive(id)
    }

    private func completed(_ request: UUID, peer id: UUID, result: AppResult, state: HostSnapshot?) {
        guard peers[id] != nil else { return }
        peers[id]?.requests.removeValue(forKey: request)
        send(.reply(id: request, result: result, state: state), to: id)
    }
    private func send(_ message: ServerMessage, to id: UUID, closeAfter: Bool = false) {
        guard peers[id] != nil else { return }
        let bounded: ServerMessage
        switch message {
        case .state(let state): bounded = .state(wireState(state))
        case .reply(let request, .snapshot(let state), _): bounded = .reply(id: request, result: .snapshot(wireState(state)), state: nil)
        case .reply(let request, .synchronized(let sync), _):
            bounded = .reply(id: request, result: .synchronized(StateSync(snapshot: sync.snapshot.map(wireState), events: sync.events.map(wireState))), state: nil)
        case .reply(let request, let result, let state): bounded = .reply(id: request, result: result, state: state.map(wireState))
        default: bounded = message
        }
        guard let data = try? AppPacket(bounded).encode() else {
            if case .reply(let request, _, _) = message { send(.reply(id: request, result: .failure(.tooLarge), state: nil), to: id) }
            else { remove(id) }
            return
        }
        guard peers[id]!.outbox.count < 16 else { remove(id); return }
        peers[id]?.outbox.append(data)
        if closeAfter { peers[id]?.closing = true }
        pump(id)
    }
    private func pump(_ id: UUID) {
        guard var peer = peers[id], !peer.sending else { return }
        let data: Data
        if !peer.outbox.isEmpty { data = peer.outbox.removeFirst() }
        else if let state = peer.latestState { data = state; peer.latestState = nil }
        else { if peer.closing { remove(id) }; return }
        peer.sending = true; peers[id] = peer
        let context = NWConnection.ContentContext(identifier: "pi-remote", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        peer.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            Task { await self?.sent(id, error: error) }
        })
    }
    private func sent(_ id: UUID, error: NWError?) {
        guard error == nil, peers[id] != nil else { remove(id); return }
        peers[id]?.sending = false
        pump(id)
    }
    private func wireState(_ original: HostSnapshot) -> HostSnapshot {
        if (try? AppPacket(ServerMessage.state(original)).encode()) != nil { return original }
        var state = HostSnapshot(host: original.host, epoch: original.epoch)
        state.sequence = original.sequence; state.selected = original.selected; state.phase = original.phase
        state.sessions = original.sessions.filter { $0.id == original.selected }
        state.error = .tooLarge; state.hasOlderMessages = true
        state.notices = ["Live state exceeded the display limit. Pi is still running; Stop remains available."]
        return state
    }

    private func broadcast(_ state: HostSnapshot) {
        guard let data = try? AppPacket(ServerMessage.state(wireState(state))).encode() else { return }
        for id in Array(peers.keys) {
            guard case .authenticated = peers[id]?.phase else { continue }
            peers[id]?.latestState = data
            pump(id)
        }
    }
    private func sweep() {
        for id in peers.keys.filter({ (peers[$0]?.deadline ?? 0) <= ProcessInfo.processInfo.systemUptime }) { remove(id) }
    }
    private func remove(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.lease.revoke()
        for task in peer.requests.values { task.cancel() }
        peer.connection.stateUpdateHandler = nil; peer.connection.cancel()
        if pending?.id == id { publishPair(nil) }
    }
    public func stop() async {
        running = false
        startup?.resume(throwing: RemoteFault.unavailable); startup = nil
        startupTimeout?.cancel(); startupTimeout = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil; observation?.cancel(); observation = nil
        for id in Array(peers.keys) { remove(id) }
        await registry.closeWindow(); publishPair(nil)
    }
}
