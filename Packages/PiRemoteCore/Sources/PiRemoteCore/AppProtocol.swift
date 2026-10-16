import Foundation

public enum RemoteFault: String, Error, Codable, Sendable {
    case unsupportedVersion, invalidRequest, unauthorized, expired, conflict, busy
    case unavailable, permissionDenied, staleDirectory, tooLarge, unknownOutcome
    case incompatiblePi, unsupportedFeature, storageFailure, capacity, cancelled, providerAuthenticationRequired
}

public enum Delivery: String, Codable, Sendable, CaseIterable {
    case prompt, steer, followUp
}

public enum SessionAction: Codable, Sendable, Equatable {
    case snapshot
    case synchronize(epoch: UUID?, after: UInt64?)
    case directories(id: UUID?, cursor: UUID?)
    case preview(id: UUID)
    case createSession(directory: UUID)
    case resumeSession(id: UUID)
    case prompt(text: String, delivery: Delivery, image: ImageAttachment?)
    case stop
    case model(provider: String, id: String)
    case thinking(level: String)
    case compact(instructions: String)
    case rename(name: String)
    case history
    case historyPage(cursor: UUID?)
    case historyEntry(id: UUID)
    case fork(entry: String)
    case clone
    case command(name: String, arguments: String)
    case answer(dialog: String, value: String?, confirmed: Bool?, cancelled: Bool)
    case diff
    case statistics
    case outputImage(id: UUID)
    case lastAssistant
    case runtimeSettings
    case queueMode(kind: QueueKind, mode: QueueMode)
    case autoCompaction(enabled: Bool)
    case closeSession

    public var mutates: Bool {
        switch self {
        case .snapshot, .synchronize, .directories, .preview, .history, .historyPage, .historyEntry, .diff, .statistics, .outputImage, .lastAssistant, .runtimeSettings: false
        default: true
        }
    }

    public var changesSession: Bool {
        switch self {
        case .createSession, .resumeSession, .fork, .clone, .closeSession: true
        default: false
        }
    }

    public var needsSession: Bool {
        switch self {
        case .snapshot, .synchronize, .directories, .preview, .createSession, .resumeSession: false
        default: true
        }
    }
}

public struct ImageAttachment: Codable, Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

public struct AppRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var epoch: UUID
    public var session: UUID?
    public var action: SessionAction
    public init(id: UUID = UUID(), epoch: UUID, session: UUID?, action: SessionAction) {
        self.id = id; self.epoch = epoch; self.session = session; self.action = action
    }
}

public enum ClientMessage: Codable, Sendable {
    case pair(device: UUID, name: String, grant: Data)
    case authenticate(device: UUID, proof: Data)
    case request(AppRequest)
}

public enum AppResult: Codable, Sendable, Equatable {
    case ok
    case snapshot(HostSnapshot)
    case synchronized(StateSync)
    case directories(DirectoryPage)
    case preview(FilePreview)
    case history([HistoryItem])
    case historyPage(HistoryPage)
    case statistics(SessionStatistics)
    case image(ImageAttachment)
    case runtimeSettings(RuntimeSettings)
    case failure(RemoteFault)
}

public enum ServerMessage: Codable, Sendable {
    case challenge(nonce: Data)
    case approvalRequired
    case paired(credential: Data, host: UUID)
    case authenticated(host: UUID, epoch: UUID)
    case reply(id: UUID, result: AppResult, state: HostSnapshot?)
    case state(HostSnapshot)
    case denied
}

public struct AppPacket<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: Int
    public let payload: Payload
    public init(_ payload: Payload, version: Int = 1) { self.version = version; self.payload = payload }

    public func encode() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4 * 1_024 * 1_024 else { throw RemoteFault.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1_024 * 1_024 else { throw RemoteFault.tooLarge }
        // Check the version before decoding a potentially incompatible payload.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = object?["version"] as? Int, version == 1 else { throw RemoteFault.unsupportedVersion }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
