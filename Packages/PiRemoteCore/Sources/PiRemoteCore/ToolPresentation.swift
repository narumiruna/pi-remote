import Foundation

public enum TranscriptToolStatus: String, Codable, Sendable {
    case running, completed, failed, interrupted
}

/// Untrusted display text only. A target does not authorize file access or execution.
public struct TranscriptTool: Codable, Sendable, Equatable {
    public let name: String
    public let target: String?
    public var status: TranscriptToolStatus

    public init(name: String, target: String? = nil, status: TranscriptToolStatus) {
        self.name = DisplayLimit.text(name.isEmpty ? "Tool" : name, bytes: 128)
        self.target = target.map { DisplayLimit.text($0, bytes: 1_024) }
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case name, target, status }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try container.decode(String.self, forKey: .name),
                  target: try container.decodeIfPresent(String.self, forKey: .target),
                  status: try container.decode(TranscriptToolStatus.self, forKey: .status))
    }

    var displayBytes: Int { name.utf8.count + (target?.utf8.count ?? 0) + status.rawValue.utf8.count }

    static func presentation(name: String?, arguments: JSONValue?, status: TranscriptToolStatus) -> (tool: Self, truncated: Bool) {
        let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
        // Do not serialize arbitrary arguments: they can contain file contents or secrets.
        let key: String?
        switch name {
        case "read", "write", "edit": key = "path"
        case "bash": key = "command"
        default: key = nil
        }
        let target = key.flatMap { arguments?[$0]?.string }.flatMap { $0.isEmpty ? nil : $0 }
        return (Self(name: name, target: target, status: status),
                name.utf8.count > 128 || (target?.utf8.count ?? 0) > 1_024)
    }
}
