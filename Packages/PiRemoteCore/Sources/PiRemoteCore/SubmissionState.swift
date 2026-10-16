import Foundation

/// Persist needsReview before dispatch; concurrent acknowledgements cannot clear another pending action.
public struct SubmissionState: Sendable {
    private var pending: Set<UUID> = []
    public private(set) var uncertain: Bool
    public init(uncertain: Bool = false) { self.uncertain = uncertain }
    public var needsReview: Bool { uncertain || !pending.isEmpty }
    public mutating func begin(_ id: UUID) { pending.insert(id) }
    public mutating func finish(_ id: UUID, fault: RemoteFault?) {
        pending.remove(id)
        if fault == .unknownOutcome || fault == .storageFailure { uncertain = true }
    }
    public mutating func reviewed() { uncertain = false }
}
