import Foundation

/// Structural validation shared by the import review and host. Pi migrates the managed copy.
public struct SessionImport: Sendable, Equatable {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public let piID: String
    public let directory: String?
    public let title: String
    public let entryCount: Int
    public let version: Int

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw RemoteFault.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw RemoteFault.invalidRequest }
        // Split only on LF bytes. Swift Character splitting does not split CRLF at LF.
        let lines = data.split(separator: 10).filter { !$0.allSatisfy { [9, 13, 32].contains($0) } }
        guard let first = lines.first, first.count < 65_536,
              let header = try? Self.record(Data(first)),
              header["type"]?.string == "session",
              let id = header["id"]?.string, id.utf8.count <= 128,
              id.range(of: #"\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z"#, options: .regularExpression) != nil else {
            throw RemoteFault.invalidRequest
        }
        let cwd: String?
        switch header["cwd"] {
        case nil, .null, .string(""): cwd = nil
        case .string(let path):
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else { throw RemoteFault.invalidRequest }
            cwd = path
        default: throw RemoteFault.invalidRequest
        }
        let version: Int
        switch header["version"] {
        case nil, .number(1): version = 1
        case .number(2): version = 2
        case .number(3): version = 3
        default: throw RemoteFault.invalidRequest
        }
        var ids: [String: Data] = [:]
        var name = "Imported session"
        let types: Set<String> = ["message", "model_change", "thinking_level_change", "usage", "compaction",
                                  "context_edit", "branch_summary", "custom", "custom_message", "label", "session_info"]
        for (position, line) in lines.enumerated().dropFirst() {
            guard let entry = try? Self.record(Data(line)),
                  let type = entry["type"]?.string, types.contains(type) else { throw RemoteFault.invalidRequest }
            if version >= 2 {
                guard let entryID = entry["id"]?.string, !entryID.isEmpty, entryID.utf8.count <= 128,
                      ids[entryID] == nil, let parent = entry["parentId"],
                      parent == .null || parent.string.map({ ids[$0] == Data($0.utf8) }) == true else { throw RemoteFault.invalidRequest }
                let identity = Data(entryID.utf8)
                if type == "compaction" {
                    guard let kept = entry["firstKeptEntryId"]?.string,
                          Data(kept.utf8) == identity || ids[kept] == Data(kept.utf8) else { throw RemoteFault.invalidRequest }
                }
                ids[entryID] = identity
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

    /// Foundation keeps the first duplicate key; Node keeps the last. Reject ambiguity.
    private static func record(_ data: Data) throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let bytes = [UInt8](data)
        var frames: [ImportJSONFrame] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91:
                frames.append(ImportJSONFrame(isObject: bytes[index] == 123, expectsKey: bytes[index] == 123))
            case 125, 93: _ = frames.popLast()
            case 44:
                if let top = frames.indices.last, frames[top].isObject { frames[top].expectsKey = true }
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2 }
                    else if bytes[index] == 34 { index += 1; break }
                    else { index += 1 }
                }
                guard index <= bytes.count else { throw RemoteFault.invalidRequest }
                if let top = frames.indices.last, frames[top].isObject, frames[top].expectsKey {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    guard frames[top].keys.insert(key).inserted else { throw RemoteFault.invalidRequest }
                    frames[top].expectsKey = false
                }
                continue
            default: break
            }
            index += 1
        }
        return value
    }

    /// Prepare only the managed copy. Retain message bytes and never change the source.
    public static func preparedCopy(of data: Data, directory: String? = nil) throws -> Data {
        _ = try Self(data: data)
        guard let first = data.split(separator: 10).first(where: { !$0.allSatisfy { [9, 13, 32].contains($0) } }) else {
            throw RemoteFault.invalidRequest
        }
        var result = Data(data[first.startIndex...])
        if let directory {
            guard directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4_096 else { throw RemoteFault.invalidRequest }
            let boundary = result.firstIndex(of: 10) ?? result.endIndex
            guard case .object(var header) = try JSONDecoder().decode(JSONValue.self, from: Data(result[..<boundary])) else { throw RemoteFault.invalidRequest }
            header["cwd"] = .string(directory)
            var replaced = try JSONEncoder().encode(JSONValue.object(header))
            guard replaced.count < 65_536 else { throw RemoteFault.tooLarge }
            replaced.append(10)
            if boundary < result.endIndex { replaced.append(result[result.index(after: boundary)...]) }
            result = replaced
        }
        if result.last != 10 { result.append(10) }
        guard result.count <= maximumBytes else { throw RemoteFault.tooLarge }
        _ = try Self(data: result)
        return result
    }
}

private struct ImportJSONFrame {
    let isObject: Bool
    var expectsKey: Bool
    var keys: Set<String> = []
}
