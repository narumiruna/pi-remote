import Foundation
import PiRemoteConnection
import PiRemoteCore
import PiRemoteSecurity

public enum ClientUpdate: Sendable {
    case state(HostSnapshot)
    case disconnected(RemoteFault)
}

public actor RemoteClient {
    private struct Waiting: Sendable {
        var continuation: CheckedContinuation<AppResult, any Error>
        var deadline: Task<Void, Never>
        var mutation: Bool
    }
    private var channel: PinnedChannel?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var waiting: [UUID: Waiting] = [:]
    private var snapshot: HostSnapshot?
    private var checkpoint: HostSnapshot?
    private var mac: SavedMac?
    private var generation = UUID()
    private var observers: [UUID: AsyncStream<ClientUpdate>.Continuation] = [:]
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public static func pair(code: PairingCode, device: UUID, name: String, secrets: any SecretStore) async throws -> SavedMac {
        guard code.expires > Date(), code.grant.count == 32 else { throw RemoteFault.expired }
        let channel = try PinnedChannel(url: code.url, certificate: code.certificate)
        defer { channel.close() }
        guard case .challenge(let nonce) = try AppPacket<ServerMessage>.decode(await channel.receive(timeout: 10)).payload,
              nonce.count == 32 else { throw RemoteFault.unauthorized }
        try await channel.send(AppPacket(ClientMessage.pair(device: device, name: String(name.prefix(64)), grant: code.grant)).encode())
        var response = try AppPacket<ServerMessage>.decode(await channel.receive(timeout: 10)).payload
        if case .approvalRequired = response { response = try AppPacket<ServerMessage>.decode(await channel.receive(timeout: 130)).payload }
        guard case .paired(let credential, let host) = response, host == code.host, credential.count == 32 else { throw RemoteFault.unauthorized }
        let mac = SavedMac(id: host, name: code.name, url: code.url, certificate: code.certificate, device: device)
        guard !Task.isCancelled else { throw RemoteFault.cancelled }
        try secrets.put(credential, account: account(mac))
        return mac
    }

    private static func account(_ mac: SavedMac) -> String { mac.id.uuidString + "/" + mac.device.uuidString }

    public func updates() -> AsyncStream<ClientUpdate> {
        let id = UUID()
        let stream = AsyncStream<ClientUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        if let snapshot { stream.continuation.yield(.state(snapshot)) }
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func emit(_ update: ClientUpdate) { for observer in observers.values { observer.yield(update) } }

    public func connect(_ mac: SavedMac) async throws {
        disconnect()
        let token = generation
        guard let credential = try secrets.get(Self.account(mac)) else { throw RemoteFault.unauthorized }
        let channel = try PinnedChannel(url: mac.url, certificate: mac.certificate)
        do {
            guard case .challenge(let nonce) = try AppPacket<ServerMessage>.decode(await channel.receive(timeout: 10)).payload,
                  nonce.count == 32 else { throw RemoteFault.unauthorized }
            let proof = DeviceProof.create(secret: credential, device: mac.device, nonce: nonce)
            try await channel.send(AppPacket(ClientMessage.authenticate(device: mac.device, proof: proof)).encode())
            guard case .authenticated(let host, let epoch) = try AppPacket<ServerMessage>.decode(await channel.receive(timeout: 10)).payload,
                  host == mac.id else { throw RemoteFault.unauthorized }
            guard token == generation, !Task.isCancelled else { throw RemoteFault.cancelled }
            self.mac = mac; self.channel = channel
            let previous = checkpoint.flatMap { $0.host == host && $0.epoch == epoch ? $0 : nil }
            snapshot = previous ?? HostSnapshot(host: host, epoch: epoch)
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let packet = try AppPacket<ServerMessage>.decode(await channel.receive(timeout: 45))
                        await self?.received(packet.payload, generation: token)
                    }
                } catch { await self?.connectionEnded(token) }
            }
            _ = try await request(.synchronize(epoch: previous?.epoch, after: previous?.sequence))
            guard token == generation, !Task.isCancelled else { throw RemoteFault.cancelled }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self else { return }
                    do { _ = try await self.request(.snapshot) } catch { return }
                }
            }
        } catch { channel.close(); if token == generation { disconnect() }; throw error }
    }

    public func request(_ action: SessionAction) async throws -> AppResult {
        try await request(action, expectedSession: snapshot?.selected)
    }

    public func request(_ action: SessionAction, expectedSession: UUID?) async throws -> AppResult {
        guard let channel, let snapshot else { throw RemoteFault.unavailable }
        guard !action.needsSession || expectedSession != nil else { throw RemoteFault.conflict }
        let request = AppRequest(epoch: snapshot.epoch, session: expectedSession, action: action)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiting.count < 8, !Task.isCancelled else { continuation.resume(throwing: RemoteFault.capacity); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(150)) } catch { return }
                    await self?.timeout(request.id)
                }
                waiting[request.id] = Waiting(continuation: continuation, deadline: deadline, mutation: action.mutates)
                let token = generation
                Task { [weak self] in await self?.send(request, channel: channel, generation: token) }
            }
        } onCancel: { [weak self] in Task { await self?.timeout(request.id) } }
    }

    private func send(_ request: AppRequest, channel: PinnedChannel, generation token: UUID) async {
        guard token == generation, waiting[request.id] != nil else { return }
        let data: Data
        do { data = try AppPacket(ClientMessage.request(request)).encode() }
        catch {
            if let item = waiting.removeValue(forKey: request.id) {
                item.deadline.cancel()
                item.continuation.resume(throwing: error as? RemoteFault ?? .invalidRequest)
            }
            return
        }
        do { try await channel.send(data) } catch { timeout(request.id) }
    }

    private func received(_ message: ServerMessage, generation token: UUID) {
        guard generation == token else { return }
        switch message {
        case .state(let state): apply(state)
        case .reply(let id, let result, let state):
            guard let item = waiting.removeValue(forKey: id) else { return }
            item.deadline.cancel()
            if let state, !apply(state) {
                item.continuation.resume(throwing: item.mutation ? RemoteFault.unknownOutcome : RemoteFault.unavailable)
                return
            }
            if case .snapshot(let state) = result, !apply(state) {
                item.continuation.resume(throwing: item.mutation ? RemoteFault.unknownOutcome : RemoteFault.unavailable)
                return
            }
            if case .synchronized(let sync) = result {
                let states = sync.snapshot.map { [$0] } ?? sync.events
                for state in states where !apply(state) {
                    item.continuation.resume(throwing: item.mutation ? RemoteFault.unknownOutcome : RemoteFault.unavailable)
                    return
                }
                if states.isEmpty, let snapshot { emit(.state(snapshot)) }
            }
            if case .failure(let fault) = result { item.continuation.resume(throwing: fault) }
            else { item.continuation.resume(returning: result) }
        case .denied: disconnect(fault: .unauthorized)
        default: disconnect(fault: .invalidRequest)
        }
    }
    @discardableResult
    private func apply(_ state: HostSnapshot) -> Bool {
        guard state.host == mac?.id, state.epoch == snapshot?.epoch else {
            disconnect(fault: .unknownOutcome)
            return false
        }
        if state.sequence < (snapshot?.sequence ?? 0) { return true }
        snapshot = state; checkpoint = state; emit(.state(state))
        return true
    }
    private func timeout(_ id: UUID) {
        guard let item = waiting.removeValue(forKey: id) else { return }
        item.deadline.cancel()
        item.continuation.resume(throwing: item.mutation ? RemoteFault.unknownOutcome : RemoteFault.unavailable)
    }
    private func connectionEnded(_ token: UUID) { if token == generation { disconnect() } }

    public func disconnect(fault: RemoteFault = .unavailable) {
        generation = UUID(); receiver?.cancel(); receiver = nil; heartbeat?.cancel(); heartbeat = nil
        channel?.close(); channel = nil
        for item in waiting.values {
            item.deadline.cancel()
            item.continuation.resume(throwing: item.mutation ? RemoteFault.unknownOutcome : fault)
        }
        waiting.removeAll(); snapshot = nil
        emit(.disconnected(fault))
    }

    public func forget(_ mac: SavedMac) throws {
        if self.mac?.id == mac.id { disconnect() }
        try secrets.remove(Self.account(mac))
        if checkpoint?.host == mac.id { checkpoint = nil }
    }
}
