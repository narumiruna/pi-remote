import CryptoKit
import Foundation

/// Persist unknown before dispatch. An unfinished command is never dispatched again.
public struct RequestJournal: Codable, Sendable {
    public struct Record: Codable, Sendable {
        public var fingerprint: Data
        public var finished: Bool
        public var fault: RemoteFault?
    }
    public enum Decision: Sendable, Equatable {
        case dispatch, completed(RemoteFault?), unknown
    }
    public var epoch: UUID
    private var records: [String: Record] = [:]

    public init(epoch: UUID) { self.epoch = epoch }

    public mutating func begin(device: UUID, request: AppRequest) throws -> Decision {
        guard request.epoch == epoch else { throw RemoteFault.unknownOutcome }
        let key = device.uuidString + "/" + request.id.uuidString
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = Data(SHA256.hash(data: try encoder.encode(request)))
        if let record = records[key] {
            guard record.fingerprint == fingerprint else { throw RemoteFault.conflict }
            return record.finished ? .completed(record.fault) : .unknown
        }
        guard records.count < 10_000 else { throw RemoteFault.capacity }
        records[key] = Record(fingerprint: fingerprint, finished: false, fault: nil)
        return .dispatch
    }

    public mutating func finish(device: UUID, request: AppRequest, fault: RemoteFault?) {
        let key = device.uuidString + "/" + request.id.uuidString
        guard var record = records[key] else { return }
        record.finished = true; record.fault = fault; records[key] = record
    }
}
