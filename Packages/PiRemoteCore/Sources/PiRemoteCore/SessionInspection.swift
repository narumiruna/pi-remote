/// A bounded option returned by Pi's get_fork_messages operation.
public struct SessionForkOption: Codable, Sendable, Equatable {
    public let entryID: String
    public let text: String
    public let truncated: Bool

    public init(entryID: String, text: String, truncated: Bool) {
        self.entryID = entryID; self.text = text; self.truncated = truncated
    }
}

/// One flat node in Pi's tree order. An orphan root retains its missing parent ID.
public struct SessionTreeNode: Codable, Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let kind: String
    public let label: String?
    /// Exact ISO 8601 string from labelTimestamp, not the entry timestamp.
    public let labelTimestamp: String?
    public let text: String
    public let truncated: Bool
    public let canFork: Bool

    public init(id: String, parentID: String?, kind: String, label: String?, labelTimestamp: String?,
                text: String, truncated: Bool, canFork: Bool) {
        self.id = id; self.parentID = parentID; self.kind = kind
        self.label = label; self.labelTimestamp = labelTimestamp
        self.text = text; self.truncated = truncated; self.canFork = canFork
    }
}

/// Bounded tree inspection. The active leaf can be null even when entries exist.
public struct SessionTreeInspection: Codable, Sendable, Equatable {
    public let nodes: [SessionTreeNode]
    public let leafID: String?

    public init(nodes: [SessionTreeNode], leafID: String?) {
        self.nodes = nodes; self.leafID = leafID
    }
}
