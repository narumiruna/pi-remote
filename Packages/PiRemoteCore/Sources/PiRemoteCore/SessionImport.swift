import Foundation

/// Structural validation shared by the import review and host. Pi migrates the managed copy.
public struct SessionImport: Sendable, Equatable {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public let piID: String
    public let directory: String
    public let title: String
    public let entryCount: Int
    public let version: Int

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw RemoteFault.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw RemoteFault.invalidRequest }
        // Split only on LF bytes. Swift Character splitting does not split CRLF at LF.
        let lines = data.split(separator: 10).filter { !$0.allSatisfy { [9, 13, 32].contains($0) } }
        guard let first = lines.first, first.count < 65_536,
              let header = try? JSONDecoder().decode(JSONValue.self, from: Data(first)),
              header["type"]?.string == "session",
              let id = header["id"]?.string, id.utf8.count <= 128,
              id.range(of: #"\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z"#, options: .regularExpression) != nil,
              let cwd = header["cwd"]?.string, cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4_096 else {
            throw RemoteFault.invalidRequest
        }
        let version: Int
        switch header["version"] {
        case nil, .number(1): version = 1
        case .number(2): version = 2
        case .number(3): version = 3
        default: throw RemoteFault.invalidRequest
        }
        var ids: Set<String> = []
        var name = "Imported session"
        let types: Set<String> = ["message", "model_change", "thinking_level_change", "usage", "compaction",
                                  "context_edit", "branch_summary", "custom", "custom_message", "label", "session_info"]
        for (position, line) in lines.enumerated().dropFirst() {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let type = entry["type"]?.string, types.contains(type) else { throw RemoteFault.invalidRequest }
            if version >= 2 {
                guard let entryID = entry["id"]?.string, !entryID.isEmpty, entryID.utf8.count <= 128,
                      !ids.contains(entryID), let parent = entry["parentId"],
                      parent == .null || parent.string.map({ ids.contains($0) }) == true else { throw RemoteFault.invalidRequest }
                if type == "compaction" {
                    guard let kept = entry["firstKeptEntryId"]?.string,
                          kept == entryID || ids.contains(kept) else { throw RemoteFault.invalidRequest }
                }
                ids.insert(entryID)
            } else if type == "compaction" {
                guard case .number(let kept) = entry["firstKeptEntryIndex"], kept >= 1,
                      kept <= Double(position), kept.rounded(.towardZero) == kept else { throw RemoteFault.invalidRequest }
            }
            if type == "message" {
                guard let role = entry["message"]?["role"]?.string,
                      ["system", "user", "assistant", "toolResult", "bashExecution", "custom"].contains(role) ||
                        (version < 3 && role == "hookMessage") else { throw RemoteFault.invalidRequest }
            }
            if type == "session_info", let value = entry["name"]?.string, !value.isEmpty {
                name = DisplayLimit.text(value, bytes: 256)
            }
        }
        piID = id; directory = cwd; title = name; entryCount = lines.count - 1; self.version = version
    }
}
