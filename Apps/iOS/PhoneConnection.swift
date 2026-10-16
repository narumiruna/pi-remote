import Foundation
import PiRemoteClient
import PiRemoteCore

/// The phone UI uses the production client by default. Tests can supply an isolated connection.
protocol PhoneConnection: Sendable {
    func pair(code: PairingCode, device: UUID, name: String) async throws -> SavedMac
    func updates() async -> AsyncStream<ClientUpdate>
    func connect(_ mac: SavedMac) async throws
    func disconnect(fault: RemoteFault) async
    func forget(_ mac: SavedMac) async throws
    func request(_ action: SessionAction, context: SessionContext) async throws -> AppResult
}

extension RemoteClient: PhoneConnection {}
