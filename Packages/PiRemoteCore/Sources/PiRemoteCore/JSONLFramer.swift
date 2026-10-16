import Foundation

public enum JSONLFailure: Error, Sendable, Equatable {
    case frameTooLarge
    case invalidRecord
    case truncatedRecord
}

/// Splits on LF bytes only, preserving UTF-8 sequences across reads.
public struct JSONLFramer: Sendable {
    private var pending = Data()
    private let maximumRecordBytes: Int
    private var failed = false

    public init(maximumRecordBytes: Int = 8 * 1_024 * 1_024) {
        precondition(maximumRecordBytes > 0)
        self.maximumRecordBytes = maximumRecordBytes
    }

    public mutating func append(
        _ bytes: Data,
        receive: (JSONValue) throws -> Void
    ) throws {
        guard !failed else { throw JSONLFailure.invalidRecord }
        do {
            for byte in bytes {
                if byte == 0x0A {
                    if pending.last == 0x0D { pending.removeLast() }
                    guard String(data: pending, encoding: .utf8) != nil,
                          let record = try? JSONDecoder().decode(JSONValue.self, from: pending),
                          case .object = record else {
                        throw JSONLFailure.invalidRecord
                    }
                    pending.removeAll(keepingCapacity: true)
                    try receive(record)
                } else {
                    guard pending.count < maximumRecordBytes else {
                        throw JSONLFailure.frameTooLarge
                    }
                    pending.append(byte)
                }
            }
        } catch {
            failed = true
            pending.removeAll()
            throw error
        }
    }

    public mutating func finish() throws {
        guard !failed else { throw JSONLFailure.invalidRecord }
        guard pending.isEmpty else {
            failed = true
            pending.removeAll()
            throw JSONLFailure.truncatedRecord
        }
    }
}
