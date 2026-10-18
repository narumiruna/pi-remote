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
    private struct Block: Sendable { var kind: String; var text: String; var name = ""; var truncated = false }
    private var blocks: [Int: Block] = [:]
    private var activeRun = false
    private var compacting = false
    private var retrying = false
    private var summaryRetryPhase: String?

    public init() {}

    public mutating func replaceHistory(_ values: [JSONValue]) {
        messages = values.compactMap(Self.message)
        assistant = nil; blocks.removeAll()
        tools.removeAll()
        omitted = false
        bound()
    }

    public mutating func consume(_ event: JSONValue) {
        switch event["type"]?.string {
        case "agent_start": activeRun = true; restorePhase()
        case "agent_settled":
            activeRun = false; compacting = false; retrying = false; summaryRetryPhase = nil
            phase = "idle"
            for i in messages.indices where messages[i].streaming {
                messages[i].streaming = false
            }
        case "compaction_start":
            // Automatic compaction can precede agent_start, but only settlement ends that operation.
            if let reason = event["reason"]?.string, reason != "manual" { activeRun = true }
            compacting = true; restorePhase()
        case "compaction_end":
            compacting = false; summaryRetryPhase = nil
            if event["willRetry"]?.bool == true { activeRun = true }
            restorePhase()
            if event["aborted"]?.bool != true, event["result"] == nil || event["result"] == .null {
                appendError(event["errorMessage"]?.string)
            }
        case "auto_retry_start":
            activeRun = true; retrying = true; restorePhase()
        case "auto_retry_end":
            retrying = false; restorePhase()
            if event["success"]?.bool == false { appendError(event["finalError"]?.string) }
        case "summarization_retry_scheduled":
            if summaryRetryPhase == nil { summaryRetryPhase = phase }
            phase = "retrying"
        case "summarization_retry_attempt_start":
            phase = event["source"]?.string == "compaction" ? "compacting" : (summaryRetryPhase ?? "working")
        case "summarization_retry_finished":
            if let previous = summaryRetryPhase { phase = previous }
            summaryRetryPhase = nil
        case "message_start":
            if event["message"]?["role"]?.string == "assistant" {
                let item = TranscriptMessage(role: "assistant", text: "", streaming: true)
                assistant = item.id; blocks.removeAll()
                messages.append(item)
            }
        case "message_update": updateBlocks(event["assistantMessageEvent"])
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
                      let tool = raw["toolCallId"]?.string, let id = tools[tool],
                      let index = messages.firstIndex(where: { $0.id == id }) {
                if var complete = Self.message(raw) {
                    complete.id = id
                    messages[index] = complete
                } else { messages.remove(at: index); tools.removeValue(forKey: tool) }
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
                messages[index].images = Self.imageReferences(result?["content"])
                if (result?["content"]?.array ?? []).filter({ $0["type"]?.string == "image" }).count > 16 { messages[index].truncated = true }
                messages[index].streaming = event["type"]?.string != "tool_execution_end"
                messages[index].isError = event["isError"]?.bool == true
            }
        default: break
        }
        bound()
    }

    public static func message(_ value: JSONValue) -> TranscriptMessage? {
        guard let role = value["role"]?.string, role != "system",
              !(role == "custom" && value["display"]?.bool == false) else { return nil }
        if role == "bashExecution" {
            let command = value["command"]?.string ?? "Command unavailable"
            let output = value["output"]?.string ?? ""
            let excluded = value["excludeFromContext"]?.bool == true
            let cancelled = value["cancelled"]?.bool == true
            let exit: Double?
            if case .number(let code) = value["exitCode"], code.isFinite,
               code.rounded() == code, code >= -2_147_483_648, code <= 2_147_483_647 { exit = code }
            else { exit = nil }
            let status = cancelled ? "cancelled" : exit.map { "exit " + String(format: "%.0f", $0) } ?? "exit unavailable"
            let outcome = "\n[" + status + (excluded ? " · excluded from model context" : "") + "]"
            let body = (excluded ? "!! " : "! ") + command + "\n" + output
            return TranscriptMessage(role: "bash", text: DisplayLimit.text(body, bytes: 16_384 - outcome.utf8.count) + outcome,
                                     isError: !cancelled && exit.map { $0 != 0 } == true,
                                     truncated: value["truncated"]?.bool == true || body.utf8.count + outcome.utf8.count > 16_384)
        }
        let text = content(value["content"])
        let fallback = value["summary"]?.string ?? value["output"]?.string ?? value["errorMessage"]?.string ?? ""
        let toolPrefix = role == "toolResult" ? value["toolName"]?.string.flatMap { $0.isEmpty ? nil : $0 + "\n" } ?? "" : ""
        let body = toolPrefix + (text.isEmpty ? fallback : text)
        let thinking = (value["content"]?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "thinking", block["redacted"]?.bool != true else { return nil }
            return block["thinking"]?.string
        }.joined(separator: "\n")
        guard !body.isEmpty || !thinking.isEmpty else { return nil }
        return TranscriptMessage(
            role: role == "toolResult" ? "tool" : role,
            text: DisplayLimit.text(body, bytes: 16_384),
            thinking: thinking.isEmpty ? nil : DisplayLimit.text(thinking, bytes: max(0, 16_384 - min(body.utf8.count, 16_384))),
            isError: value["isError"]?.bool == true || value["stopReason"]?.string == "error",
            truncated: body.utf8.count + thinking.utf8.count > 16_384 || (value["content"]?.array ?? []).filter({ $0["type"]?.string == "image" }).count > 16,
            images: imageReferences(value["content"])
        )
    }

    public static func imageReferences(_ content: JSONValue?) -> [OutputImageReference]? {
        let references = (content?.array ?? []).filter { $0["type"]?.string == "image" }.prefix(16).compactMap { block -> OutputImageReference? in
            guard let text = block["remoteImageID"]?.string, let id = UUID(uuidString: text) else { return nil }
            return OutputImageReference(id: id, fault: block["remoteImageFault"]?.string.flatMap(RemoteFault.init(rawValue:)))
        }
        return references.isEmpty ? nil : references
    }

    public static func content(_ value: JSONValue?) -> String {
        if let string = value?.string { return string }
        return (value?.array ?? []).compactMap { block -> String? in
            switch block["type"]?.string {
            case "text": return block["text"]?.string
            case "image": return "[Image]"
            case "toolCall": return toolCallText(block)
            default: return nil
            }
        }.joined(separator: "\n")
    }

    private mutating func updateBlocks(_ update: JSONValue?) {
        guard let type = update?["type"]?.string,
              ["text_start", "text_delta", "text_end", "thinking_start", "thinking_delta", "thinking_end",
               "toolcall_start", "toolcall_delta", "toolcall_end"].contains(type),
              let id = assistant, let row = messages.firstIndex(where: { $0.id == id }) else { return }
        var index = 0
        if case .number(let value) = update?["contentIndex"] {
            guard value.isFinite, value >= 0, value <= 255, value.rounded() == value else { return }
            index = Int(value)
        }
        guard blocks[index] != nil || blocks.count < 64 else { messages[row].truncated = true; return }
        let kind = type.hasPrefix("thinking") ? "thinking" : (type.hasPrefix("toolcall") ? "tool" : "text")
        var block = blocks[index] ?? Block(kind: kind, text: "")
        if type == "toolcall_start" {
            let name = update?["toolName"]?.string ?? "Tool"
            block = Block(kind: kind, text: "", name: DisplayLimit.text(name, bytes: 16_384), truncated: name.utf8.count > 16_384)
        } else if type == "toolcall_end" {
            block = Block(kind: kind, text: Self.toolCallText(update?["toolCall"]))
        } else if type.hasSuffix("_start") { block = Block(kind: kind, text: "") }
        else if type.hasSuffix("_end") { block = Block(kind: kind, text: update?["content"]?.string ?? "") }
        else { block.text += update?["delta"]?.string ?? "" }
        if block.text.utf8.count > 16_384 { block.text = DisplayLimit.text(block.text, bytes: 16_384); block.truncated = true }
        blocks[index] = block
        let ordered = blocks.sorted { $0.key < $1.key }.map(\.value)
        messages[row].text = ordered.filter { $0.kind != "thinking" }.map {
            $0.name.isEmpty ? $0.text : $0.name + "\n" + $0.text
        }.joined(separator: "\n")
        let thinking = ordered.filter { $0.kind == "thinking" }.map(\.text).joined(separator: "\n")
        messages[row].thinking = thinking.isEmpty ? nil : thinking
        messages[row].truncated = messages[row].truncated || ordered.contains { $0.truncated }
    }

    private mutating func restorePhase() {
        phase = compacting ? "compacting" : (retrying ? "retrying" : (activeRun ? "working" : "idle"))
    }

    private mutating func appendError(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        messages.append(TranscriptMessage(role: "assistant", text: DisplayLimit.text(text, bytes: 16_384),
                                          isError: true, truncated: text.utf8.count > 16_384))
    }

    private static func toolCallText(_ call: JSONValue?) -> String {
        let name = call?["name"]?.string ?? "Tool"
        guard let args = call?["arguments"] else { return name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(args) else { return name }
        return name + "\n" + String(decoding: data, as: UTF8.self)
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
                // Omit a shell row rather than remove its command or final outcome.
                if message.role == "bash" { omitted = true; break }
                message.text = DisplayLimit.text(message.text, bytes: limit); message.truncated = true
            }
            let thoughtLimit = max(0, limit - message.text.utf8.count)
            if let thinking = message.thinking, thinking.utf8.count > thoughtLimit {
                message.thinking = DisplayLimit.text(thinking, bytes: thoughtLimit); message.truncated = true
            }
            remaining -= message.text.utf8.count + (message.thinking?.utf8.count ?? 0)
            retained.append(message)
        }
        if retained.count < messages.count { omitted = true }
        messages = retained.reversed()
        let ids = Set(messages.map(\.id))
        tools = tools.filter { ids.contains($0.value) }
    }
}
