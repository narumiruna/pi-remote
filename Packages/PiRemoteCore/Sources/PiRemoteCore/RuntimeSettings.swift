import Foundation

public enum QueueKind: String, Codable, Sendable { case steering, followUp }
public enum QueueMode: String, Codable, Sendable, CaseIterable {
    case all
    case oneAtATime = "one-at-a-time"
}

/// Pi-reported settings. These changes can also affect future terminal sessions.
public struct RuntimeSettings: Codable, Sendable, Equatable {
    public var steeringMode: QueueMode
    public var followUpMode: QueueMode
    public var autoCompactionEnabled: Bool
    public init(steeringMode: QueueMode, followUpMode: QueueMode, autoCompactionEnabled: Bool) {
        self.steeringMode = steeringMode; self.followUpMode = followUpMode
        self.autoCompactionEnabled = autoCompactionEnabled
    }
}
