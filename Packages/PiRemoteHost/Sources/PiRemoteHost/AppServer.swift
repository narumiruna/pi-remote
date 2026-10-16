import Foundation
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
        var connection: SecurePeer
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
    private var listener: SecureListener?
    private var peers: [UUID: Peer] = [:]
    private var pending: PendingPair?
    private var pairingObservers: [UUID: AsyncStream<PendingPair?>.Continuation] = [:]
    private var timer: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var running = false
    private var stopping = false

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
        guard !running, !stopping, ListenAddress.allowed(address), identity.addresses.contains(address) else {
            throw RemoteFault.invalidRequest
        }
        let listener = try SecureListener(identity: identity)
        self.listener = listener; running = true
        let actualPort: UInt16
        do {
            actualPort = try await listener.start(address: address, port: port) { [weak self] connection in
                Task {
                    guard let self else { connection.cancel(); return }
                    await self.accept(connection)
                }
            }
            guard running, self.listener === listener, !Task.isCancelled else { throw RemoteFault.cancelled }
        } catch {
            await listener.stop()
            if self.listener === listener { self.listener = nil; running = false }
            throw error
        }
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

    private func accept(_ connection: SecurePeer) {
        guard running, peers.count < 16, let nonce = try? PairingProof.randomSecret() else { connection.cancel(); return }
        let id = UUID()
        peers[id] = Peer(connection: connection, nonce: nonce)
        send(.challenge(nonce: nonce), to: id); receive(id)
    }
    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive { [weak self] data, error in
            Task { await self?.received(id, data: data, error: error) }
        }
    }
    private func received(_ id: UUID, data: Data?, error: (any Error)?) async {
        guard let peer = peers[id], peer.deadline > ProcessInfo.processInfo.systemUptime, error == nil else { remove(id); return }
        guard let data, let packet = try? AppPacket<ClientMessage>.decode(data) else { remove(id); return }
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
        peer.connection.send(data) { [weak self] error in
            Task { await self?.sent(id, error: error) }
        }
    }
    private func sent(_ id: UUID, error: (any Error)?) {
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
        peer.connection.cancel()
        if pending?.id == id { publishPair(nil) }
    }
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        running = false
        let old = listener; listener = nil
        timer?.cancel(); timer = nil; observation?.cancel(); observation = nil
        for id in Array(peers.keys) { remove(id) }
        await old?.stop()
        await registry.closeWindow(); publishPair(nil)
    }
}
