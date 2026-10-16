import Foundation

/// Restricted diagnostic messages only. This is not a generic Pi RPC bridge.
public enum TransportSpikePayload: Codable, Sendable, Equatable {
    case challenge(nonce: Data)
    case pair(device: UUID, grant: Data)
    case paired(credential: Data)
    case authenticate(device: UUID, proof: Data)
    case authenticated
    case ping(id: UUID)
    case pong(id: UUID)
    case denied
}

public struct TransportSpikeMessage: Codable, Sendable, Equatable {
    public let version: Int
    public let payload: TransportSpikePayload

    public init(_ payload: TransportSpikePayload, version: Int = 1) {
        self.version = version
        self.payload = payload
    }

    public static func decode(_ data: Data) throws -> TransportSpikeMessage {
        guard data.count <= 16_384 else { throw TransportSpikeFailure.messageTooLarge }
        let message = try JSONDecoder().decode(Self.self, from: data)
        guard message.version == 1 else { throw TransportSpikeFailure.unsupportedVersion }
        return message
    }

    public func encode() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 16_384 else { throw TransportSpikeFailure.messageTooLarge }
        return data
    }
}

public enum TransportSpikeFailure: Error, Sendable, Equatable {
    case unsupportedVersion
    case messageTooLarge
    case invalidMessage
    case invalidIdentity
    case timedOut
    case unavailable
}
