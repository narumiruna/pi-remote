import Foundation

/// Each event is an authoritative display state, not a raw Pi delta.
public struct StateSync: Codable, Sendable, Equatable {
    public var snapshot: HostSnapshot?
    public var events: [HostSnapshot]
    public init(snapshot: HostSnapshot? = nil, events: [HostSnapshot] = []) {
        self.snapshot = snapshot; self.events = events
    }
}

/// Keep a contiguous suffix. Overflow requires a snapshot, never a partial replay.
public struct StateReplay: Sendable {
    private var entries: [(state: HostSnapshot, bytes: Int)] = []
    private var bytes = 0
    public init() {}
    public mutating func append(_ state: HostSnapshot) {
        guard let data = try? JSONEncoder().encode(state), data.count <= 2 * 1_024 * 1_024 else {
            entries = []; bytes = 0; return
        }
        entries.append((state, data.count)); bytes += data.count
        while entries.count > 32 || bytes > 2 * 1_024 * 1_024 {
            bytes -= entries.removeFirst().bytes
        }
    }
    public func synchronize(current: HostSnapshot, epoch: UUID?, after: UInt64?) -> StateSync {
        guard epoch == current.epoch, let after, after <= current.sequence,
              let first = entries.first, first.state.sequence > 0,
              after >= first.state.sequence - 1, entries.last?.state.sequence == current.sequence else {
            return StateSync(snapshot: current)
        }
        return StateSync(events: entries.filter { $0.state.sequence > after }.map(\.state))
    }
}
