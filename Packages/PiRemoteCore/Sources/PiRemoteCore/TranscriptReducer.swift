import Foundation

/// Bounded display state. Pi's managed session files remain the complete history.
public enum DisplayLimit {
    public static func text(_ string: String, bytes: Int) -> String {
        var data = Data(string.utf8.prefix(max(0, bytes)))
        for _ in 0..<4 {
            if let value = String(data: data, encoding: .utf8) { return value }
            if !data.isEmpty { data.removeLast() }
        }
        return ""
    }
}

public struct TranscriptReducer: Sendable {
    public private(set) var messages: [TranscriptMessage] = []
    public private(set) var phase = "idle"
    public private(set) var omitted = false
    private var assistant: UUID?
    private var tools: [String: UUID] = [:]

    public init() {}

    public mutating func replaceHistory(_ values: [JSONValue]) {
        messages = values.compactMap(Self.message)
        assistant = nil
        tools.removeAll()
        omitted = false
        bound()
    }

    public mutating func consume(_ event: JSONValue) {
        switch event["type"]?.string {
        case "agent_start": phase = "working"
        case "agent_settled":
            phase = "idle"
            for i in messages.indices where messages[i].streaming {
                messages[i].streaming = false
            }
        case "compaction_start": phase = "compacting"
        case "auto_retry_start", "summarization_retry_scheduled": phase = "retrying"
        case "message_start":
            if event["message"]?["role"]?.string == "assistant" {
                let item = TranscriptMessage(role: "assistant", text: "", streaming: true)
                assistant = item.id
                messages.append(item)
            }
        case "message_update":
            let update = event["assistantMessageEvent"]
            if update?["type"]?.string == "text_delta", let id = assistant,
               let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += update?["delta"]?.string ?? ""
            }
        case "message_end":
            guard let raw = event["message"] else { break }
            if raw["role"]?.string == "assistant", let id = assistant,
               let index = messages.firstIndex(where: { $0.id == id }) {
                if var complete = Self.message(raw) {
                    complete.id = id
                    messages[index] = complete
                } else { messages.remove(at: index) }
                assistant = nil
            } else if raw["role"]?.string == "toolResult",
                      let tool = raw["toolCallId"]?.string, tools[tool] != nil {
                break
            } else if let item = Self.message(raw) { messages.append(item) }
        case "tool_execution_start":
            if let id = event["toolCallId"]?.string {
                let item = TranscriptMessage(role: "tool", text: (event["toolName"]?.string ?? "Tool") + " — Running", streaming: true)
                tools[id] = item.id
                messages.append(item)
            }
        case "tool_execution_update", "tool_execution_end":
            if let id = event["toolCallId"]?.string, let item = tools[id],
               let index = messages.firstIndex(where: { $0.id == item }) {
                let result = event["result"] ?? event["partialResult"]
                messages[index].text = (event["toolName"]?.string ?? "Tool") + "\n" + Self.content(result?["content"])
                messages[index].streaming = event["type"]?.string != "tool_execution_end"
                messages[index].isError = event["isError"]?.bool == true
            }
        default: break
        }
        bound()
    }

    public static func message(_ value: JSONValue) -> TranscriptMessage? {
        guard let role = value["role"]?.string, role != "system" else { return nil }
        let text = content(value["content"])
        let fallback = value["summary"]?.string ?? value["output"]?.string ?? ""
        let body = text.isEmpty ? fallback : text
        guard !body.isEmpty else { return nil }
        return TranscriptMessage(
            role: role == "toolResult" ? "tool" : role,
            text: DisplayLimit.text(body, bytes: 16_384),
            isError: value["isError"]?.bool == true || value["stopReason"]?.string == "error",
            truncated: body.utf8.count > 16_384
        )
    }

    public static func content(_ value: JSONValue?) -> String {
        if let string = value?.string { return string }
        return (value?.array ?? []).compactMap { block -> String? in
            switch block["type"]?.string {
            case "text": return block["text"]?.string
            case "image": return "[Image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    private mutating func bound() {
        // Keep even maximally escaped UTF-8 display text below the wire-frame budget.
        var remaining = 256 * 1_024
        var retained: [TranscriptMessage] = []
        for var message in messages.suffix(100).reversed() {
            guard remaining > 0 else { omitted = true; break }
            let limit = min(16_384, remaining)
            guard limit > 0 else { omitted = true; break }
            if message.text.utf8.count > limit {
                message.text = DisplayLimit.text(message.text, bytes: limit); message.truncated = true
            }
            remaining -= message.text.utf8.count
            retained.append(message)
        }
        if retained.count < messages.count { omitted = true }
        messages = retained.reversed()
        let ids = Set(messages.map(\.id))
        tools = tools.filter { ids.contains($0.value) }
    }
}
