import Foundation

/// Session-bound capability. Image bytes are fetched separately from snapshots.
public struct OutputImageReference: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fault: RemoteFault?
    public init(id: UUID, fault: RemoteFault? = nil) { self.id = id; self.fault = fault }
}
