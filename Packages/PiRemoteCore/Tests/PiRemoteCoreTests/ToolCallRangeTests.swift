import Foundation
import Testing
@testable import PiRemoteCore

private func toolCall(_ name: String, _ arguments: JSONValue) -> JSONValue {
    .object(["type": .string("toolCall"), "name": .string(name), "arguments": arguments])
}

private func callText(in message: TranscriptMessage) -> [String] {
    let bytes = Array(message.text.utf8)
    return (message.toolCallRanges ?? []).map { String(decoding: bytes[$0], as: UTF8.self) }
}

private func proseText(in message: TranscriptMessage) -> String {
    let bytes = Array(message.text.utf8)
    var cursor = 0
    var prose = ""
    for range in message.toolCallRanges ?? [] {
        prose += String(decoding: bytes[cursor..<range.lowerBound], as: UTF8.self)
        cursor = range.upperBound
    }
    return prose + String(decoding: bytes[cursor...], as: UTF8.self)
}

private func rangeUpdate(_ type: String, index: Int = 0, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    .object(["type": .string("message_update"), "assistantMessageEvent": .object(fields.merging([
        "type": .string(type), "contentIndex": .number(Double(index))
    ]) { _, new in new })])
}

private func restoredSnapshotMessage(_ message: TranscriptMessage) throws -> TranscriptMessage {
    var snapshot = HostSnapshot(host: UUID(), epoch: UUID())
    snapshot.messages = [message]
    let data = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(HostSnapshot.self, from: data)
    return try #require(restored.messages.first)
}

@Test func toolCallRangesPreserveMixedProseUnicodeAndMultipleCalls() throws {
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("text"), "text": .string("檢查 😀")]),
        toolCall("read", .object(["path": .string("檔案.swift")])),
        .object(["type": .string("text"), "text": .string("Keep this explanation visible.")]),
        toolCall("bash", .object(["command": .string("git status")])),
        .object(["type": .string("text"), "text": .string("Done.")])
    ])])
    let message = try #require(TranscriptReducer.message(raw))
    #expect(callText(in: message) == ["read\n{\"path\":\"檔案.swift\"}", "bash\n{\"command\":\"git status\"}"])
    #expect(message.text == TranscriptReducer.content(raw["content"]))
    var reducer = TranscriptReducer()
    reducer.replaceHistory([raw])
    #expect(reducer.messages.first?.toolCallRanges == message.toolCallRanges)
    #expect(try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(message)) == message)
}

@Test func toolCallRangesFollowStreamingArgumentsAndFinalReplacement() throws {
    var reducer = TranscriptReducer()
    reducer.consume(.object(["type": .string("message_start"), "message": .object(["role": .string("assistant")])]))
    func update(_ type: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("message_update"), "assistantMessageEvent": .object(fields.merging([
            "type": .string(type), "contentIndex": .number(0)
        ]) { _, new in new })])
    }
    reducer.consume(update("toolcall_start", ["toolName": .string("read")]))
    reducer.consume(update("toolcall_delta", ["delta": .string("{\"path\":\"partial")]))
    #expect(callText(in: try #require(reducer.messages.first)) == ["read\n{\"path\":\"partial"])
    let call = toolCall("read", .object(["path": .string("complete.swift")]))
    reducer.consume(update("toolcall_end", ["toolCall": call]))
    let id = reducer.messages.first?.id
    reducer.consume(.object(["type": .string("message_end"), "message": .object([
        "role": .string("assistant"), "content": .array([call])
    ])]))
    let message = try #require(reducer.messages.first)
    #expect(message.id == id)
    #expect(callText(in: message) == ["read\n{\"path\":\"complete.swift\"}"])
    #expect(!message.streaming)
}

@Test func toolCallRangesStayWithinTruncatedTextAndDisplayBudget() throws {
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array([
        toolCall("write", .object(["content": .string(String(repeating: "界😀", count: 10_000))]))
    ])])
    let message = try #require(TranscriptReducer.message(raw))
    #expect(message.truncated)
    let range = try #require(message.toolCallRanges?.first)
    #expect(range.lowerBound == 0)
    #expect(range.upperBound == message.text.utf8.count)
    #expect(String(bytes: Array(message.text.utf8)[range], encoding: .utf8) != nil)
    #expect(message.text.utf8.count + (message.toolCallRanges?.count ?? 0) * 16 <= 16_384)
    var reducer = TranscriptReducer()
    reducer.replaceHistory(Array(repeating: raw, count: 100))
    #expect(reducer.messages.reduce(0) { $0 + $1.text.utf8.count + ($1.toolCallRanges?.count ?? 0) * 16 } <= 256 * 1_024)
}

@Test func excessiveToolCallRangesTruncateBeforeUnclassifiedArgumentsWithoutEvictingOlderHistory() throws {
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array(
        Array(repeating: toolCall("x", .object([:])), count: 1_025)
    )])
    let message = try #require(TranscriptReducer.message(raw))
    #expect(message.truncated)
    #expect((message.toolCallRanges?.count ?? 0) > 256)
    #expect(proseText(in: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(message.text.utf8.count + (message.toolCallRanges?.count ?? 0) * 16 <= 16_384)
    #expect(try restoredSnapshotMessage(message) == message)
    var reducer = TranscriptReducer()
    reducer.replaceHistory([.object(["role": .string("user"), "content": .string("Keep this older message")]), raw])
    #expect(reducer.messages.count == 2)
    #expect(reducer.messages[0].text == "Keep this older message")
    #expect(reducer.messages[1].text == message.text)
    #expect(!reducer.omitted)
}

@Test func typedEditArgumentsStaySeparateFromProseDuringStreamingAndSnapshotRestore() throws {
    var reducer = TranscriptReducer()
    reducer.consume(.object(["type": .string("message_start"), "message": .object(["role": .string("assistant")])]))
    let prose = "Keep this example visible: edit {\"edits\":[]} 😀"
    reducer.consume(rangeUpdate("text_delta", index: 0, ["delta": .string(prose)]))
    reducer.consume(rangeUpdate("toolcall_start", index: 1, ["toolName": .string("edit")]))
    let partial = #"{"edits":[{"newText":"struct SpaceListView"#
    reducer.consume(rangeUpdate("toolcall_delta", index: 1, ["delta": .string(partial)]))
    reducer.consume(rangeUpdate("text_end", index: 2, ["content": .string("The explanation stays visible.")]))
    let streaming = try #require(reducer.messages.first)
    #expect(streaming.streaming)
    #expect(callText(in: streaming) == ["edit\n" + partial])
    #expect(proseText(in: streaming).contains(prose))
    #expect(proseText(in: streaming).contains("The explanation stays visible."))
    #expect(!proseText(in: streaming).contains("struct SpaceListView"))
    #expect(try restoredSnapshotMessage(streaming) == streaming)

    let call = toolCall("edit", .object(["edits": .array([
        .object(["newText": .string("struct SpaceListView {}")])
    ])]))
    reducer.consume(rangeUpdate("toolcall_end", index: 1, ["toolCall": call]))
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("text"), "text": .string(prose)]), call,
        .object(["type": .string("text"), "text": .string("The explanation stays visible.")])
    ])])
    reducer.consume(.object(["type": .string("message_end"), "message": raw]))
    let complete = try #require(reducer.messages.first)
    #expect(!complete.streaming)
    #expect(callText(in: complete) == ["edit\n{\"edits\":[{\"newText\":\"struct SpaceListView {}\"}]}"])
    #expect(proseText(in: complete) == proseText(in: streaming))
    #expect(try restoredSnapshotMessage(complete) == complete)
    reducer.replaceHistory([raw])
    let history = try #require(reducer.messages.first)
    #expect(callText(in: history) == callText(in: complete))
    #expect(proseText(in: history) == proseText(in: complete))
}

@Test func toolDeltasWithoutStartAndEmptyNamesStillHaveSafeDisclosureHeadings() throws {
    var reducer = TranscriptReducer()
    reducer.consume(.object(["type": .string("message_start"), "message": .object(["role": .string("assistant")])]))
    let partial = #"{"edits":[{"newText":"private arguments"#
    reducer.consume(rangeUpdate("toolcall_delta", ["delta": .string(partial)]))
    #expect(callText(in: try #require(reducer.messages.first)) == ["Tool\n" + partial])
    reducer.consume(rangeUpdate("toolcall_start", ["toolName": .string("")]))
    reducer.consume(rangeUpdate("toolcall_delta", ["delta": .string(partial)]))
    #expect(callText(in: try #require(reducer.messages.first)) == ["Tool\n" + partial])
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("toolCall"), "name": .string("")]),
        toolCall("edit", .object(["newText": .string("private arguments")]))
    ])])
    let message = try #require(TranscriptReducer.message(raw))
    #expect(callText(in: message) == ["Tool", "edit\n{\"newText\":\"private arguments\"}"])
    #expect(proseText(in: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func aggregateTruncationNeverLeavesArgumentsWithoutTheirRanges() throws {
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array(
        [.object(["type": .string("text"), "text": .string("Visible explanation 😀")])] +
        Array(repeating: toolCall("edit", .object(["newText": .string("PRIVATE_ARGUMENTS")])), count: 700)
    )])
    var reducer = TranscriptReducer()
    reducer.replaceHistory(Array(repeating: raw, count: 100))
    #expect(reducer.omitted)
    for message in reducer.messages {
        #expect(!proseText(in: message).contains("PRIVATE_ARGUMENTS"))
        #expect(try restoredSnapshotMessage(message) == message)
        for range in message.toolCallRanges ?? [] {
            #expect(!range.isEmpty)
            #expect(String(bytes: Array(message.text.utf8)[range], encoding: .utf8) != nil)
        }
    }
    #expect(reducer.messages.reduce(0) { $0 + $1.text.utf8.count + ($1.toolCallRanges?.count ?? 0) * 16 } <= 256 * 1_024)
}

@Test func ordinaryTextAndOlderSnapshotsHaveNoToolCallRanges() throws {
    let message = try #require(TranscriptReducer.message(.object(["role": .string("assistant"), "content": .string("read\n{\"path\":\"example\"}")])))
    #expect(message.toolCallRanges == nil)
    let old = Data(#"{"id":"11111111-1111-1111-1111-111111111111","role":"assistant","text":"read {}","isError":false,"streaming":false,"truncated":false}"#.utf8)
    #expect(try JSONDecoder().decode(TranscriptMessage.self, from: old).toolCallRanges == nil)
}
