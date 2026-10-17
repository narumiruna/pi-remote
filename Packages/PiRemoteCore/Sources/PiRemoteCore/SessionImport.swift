import Foundation

/// Validation shared by the import review and host. The host repeats it before any write.
public struct SessionImport: Sendable, Equatable {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public let piID: String
    public let directory: String
    public let title: String
    public let entryCount: Int

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw RemoteFault.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw RemoteFault.invalidRequest }
        // Split only on LF bytes. Swift Character splitting does not split CRLF at LF.
        let lines = data.split(separator: 10).filter { !$0.allSatisfy { [9, 13, 32].contains($0) } }
        guard let first = lines.first, first.count < 65_536,
              let header = try? JSONDecoder().decode(JSONValue.self, from: Data(first)),
              header["type"]?.string == "session", header["version"] == .number(3),
              let id = header["id"]?.string, !id.isEmpty, id.utf8.count <= 128, !id.contains("\0"),
              let cwd = header["cwd"]?.string, cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4_096 else {
            throw RemoteFault.invalidRequest
        }
        var ids: Set<String> = []
        var name = "Imported session"
        let types: Set<String> = ["message", "model_change", "thinking_level_change", "usage", "compaction",
                                  "context_edit", "branch_summary", "custom", "custom_message", "label", "session_info"]
        for line in lines.dropFirst() {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let type = entry["type"]?.string, types.contains(type),
                  let entryID = entry["id"]?.string, !entryID.isEmpty, entryID.utf8.count <= 128,
                  !ids.contains(entryID), let parent = entry["parentId"],
                  parent == .null || parent.string.map({ ids.contains($0) }) == true else { throw RemoteFault.invalidRequest }
            if type == "message" {
                guard let role = entry["message"]?["role"]?.string,
                      ["system", "user", "assistant", "toolResult", "bashExecution", "custom"].contains(role) else { throw RemoteFault.invalidRequest }
            }
            if type == "session_info", let value = entry["name"]?.string, !value.isEmpty {
                name = DisplayLimit.text(value, bytes: 256)
            }
            ids.insert(entryID)
        }
        guard !ids.isEmpty else { throw RemoteFault.invalidRequest }
        piID = id; directory = cwd; title = name; entryCount = ids.count
    }
}
