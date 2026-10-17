import Foundation
import PiRemoteCore

/// Maps decoded RPC response data, not response envelopes. No files or processes are accessed.
public enum SessionInspectionMapper {
    public static let maximumItems = 10_000
    public static let maximumIdentifierBytes = 128
    public static let maximumPreviewBytes = 512
    public static let maximumLabelBytes = 512

    public static func forks(_ response: JSONValue) throws -> [SessionForkOption] {
        guard let messages = response["messages"]?.array else { throw RemoteFault.incompatiblePi }
        guard messages.count <= maximumItems else { throw RemoteFault.tooLarge }
        var ids = Set<String>()
        return try messages.map { message in
            let id = try identifier(message["entryId"])
            guard ids.insert(id).inserted, let text = message["text"]?.string, !text.isEmpty else {
                throw RemoteFault.incompatiblePi
            }
            return SessionForkOption(entryID: id, text: DisplayLimit.text(text, bytes: maximumPreviewBytes),
                                     truncated: text.utf8.count > maximumPreviewBytes)
        }
    }

    /// Flattens the wire tree in depth-first order without recursive traversal.
    /// Fork eligibility comes only from the supplied authoritative fork options.
    /// Missing parents are valid only on orphan roots, as in Pi's get_tree output.
    public static func tree(_ response: JSONValue, forks: [SessionForkOption]) throws -> SessionTreeInspection {
        guard let roots = response["tree"]?.array, let rawLeaf = response["leafId"] else {
            throw RemoteFault.incompatiblePi
        }
        guard roots.count <= maximumItems, forks.count <= maximumItems else { throw RemoteFault.tooLarge }
        let leaf = rawLeaf == .null ? nil : try identifier(rawLeaf)
        var options: [String: SessionForkOption] = [:]
        for option in forks {
            _ = try identifier(.string(option.entryID))
            guard !option.text.isEmpty, options[option.entryID] == nil else { throw RemoteFault.incompatiblePi }
            guard option.text.utf8.count <= maximumPreviewBytes else { throw RemoteFault.tooLarge }
            options[option.entryID] = option
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        func timestamp(_ value: JSONValue) throws -> String {
            guard let text = value.string else { throw RemoteFault.incompatiblePi }
            guard text.utf8.count <= 128 else { throw RemoteFault.tooLarge }
            guard fractional.date(from: text) != nil || whole.date(from: text) != nil else {
                throw RemoteFault.incompatiblePi
            }
            return text
        }
        var stack: [(value: JSONValue, parent: String?)] = roots.reversed().map { ($0, nil) }
        var nodes: [SessionTreeNode] = []
        var ids = Set<String>()
        var orphanParents: [String] = []
        var matchedForks = Set<String>()
        while let item = stack.popLast() {
            guard let entry = item.value["entry"], let children = item.value["children"]?.array,
                  let rawParent = entry["parentId"] else { throw RemoteFault.incompatiblePi }
            let id = try identifier(entry["id"])
            let kind = try identifier(entry["type"])
            guard kind != "session", ids.insert(id).inserted else { throw RemoteFault.incompatiblePi }
            let parent = rawParent == .null ? nil : try identifier(rawParent)
            guard parent != id else { throw RemoteFault.incompatiblePi }
            if let expected = item.parent {
                guard parent == expected else { throw RemoteFault.incompatiblePi }
            } else if let parent { orphanParents.append(parent) }
            guard let entryTimestamp = entry["timestamp"] else { throw RemoteFault.incompatiblePi }
            _ = try timestamp(entryTimestamp)
            var label: String?
            var labelTimestamp: String?
            if let raw = item.value["label"] {
                guard let text = raw.string, !text.isEmpty else { throw RemoteFault.incompatiblePi }
                guard text.utf8.count <= maximumLabelBytes else { throw RemoteFault.tooLarge }
                label = text
            }
            if let raw = item.value["labelTimestamp"] {
                guard label != nil else { throw RemoteFault.incompatiblePi }
                labelTimestamp = try timestamp(raw)
            }
            let preview = try preview(entry, kind: kind)
            if let option = options[id] {
                guard kind == "message", entry["message"]?["role"]?.string == "user" else {
                    throw RemoteFault.incompatiblePi
                }
                let text = try content(entry["message"]?["content"], images: false)
                guard text.hasText, text.text == option.text, text.truncated == option.truncated else {
                    throw RemoteFault.incompatiblePi
                }
                matchedForks.insert(id)
            }
            nodes.append(SessionTreeNode(id: id, parentID: parent, kind: kind, label: label,
                                         labelTimestamp: labelTimestamp, text: preview.text,
                                         truncated: preview.truncated, canFork: options[id] != nil))
            // Bound pending work before appending children, including wide trees.
            guard children.count <= maximumItems - nodes.count - stack.count else { throw RemoteFault.tooLarge }
            for child in children.reversed() { stack.append((child, id)) }
        }
        guard orphanParents.allSatisfy({ !ids.contains($0) }),
              leaf.map({ ids.contains($0) }) ?? true, matchedForks.count == options.count else {
            throw RemoteFault.incompatiblePi
        }
        return SessionTreeInspection(nodes: nodes, leafID: leaf)
    }

    private static func identifier(_ value: JSONValue?) throws -> String {
        guard let text = value?.string, !text.isEmpty else { throw RemoteFault.incompatiblePi }
        guard text.utf8.count <= maximumIdentifierBytes else { throw RemoteFault.tooLarge }
        return text
    }

    private struct Preview {
        var text = ""
        var truncated = false
        var hasText = false

        mutating func append(_ value: String) {
            hasText = hasText || !value.isEmpty
            guard !truncated else { return }
            let remaining = maximumPreviewBytes - text.utf8.count
            if value.utf8.count > remaining { truncated = true }
            // Never join complete source blocks into an unbounded intermediate string.
            text += DisplayLimit.text(value, bytes: remaining)
        }
    }

    private static func content(_ value: JSONValue?, images: Bool) throws -> Preview {
        var preview = Preview()
        if let text = value?.string { preview.append(text); return preview }
        guard let blocks = value?.array else { throw RemoteFault.incompatiblePi }
        guard blocks.count <= maximumItems else { throw RemoteFault.tooLarge }
        for block in blocks {
            guard let type = block["type"]?.string else { throw RemoteFault.incompatiblePi }
            if type == "text" {
                guard let text = block["text"]?.string else { throw RemoteFault.incompatiblePi }
                preview.append(text)
            } else if images && type == "image" { preview.append("[Image]") }
        }
        return preview
    }

    private static func preview(_ entry: JSONValue, kind: String) throws -> Preview {
        if kind == "message" {
            guard let message = entry["message"], let role = message["role"]?.string else {
                throw RemoteFault.incompatiblePi
            }
            if role == "system" || (role == "custom" && message["display"]?.bool == false) { return Preview() }
            if let value = message["content"] { return try content(value, images: true) }
            for key in ["summary", "output", "errorMessage"] {
                if let value = message[key]?.string { var result = Preview(); result.append(value); return result }
            }
            throw RemoteFault.incompatiblePi
        }
        if kind == "custom_message" {
            if entry["display"]?.bool == false { return Preview() }
            return try content(entry["content"], images: true)
        }
        var result = Preview()
        result.append(entry["summary"]?.string ?? kind)
        return result
    }
}
