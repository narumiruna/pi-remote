import Foundation
import Testing
@testable import PiRemoteCore

private func toolEvent(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    .object(fields.merging(["type": .string(type)]) { _, value in value })
}

private func toolStart(_ id: String = "call", name: String = "read", args: JSONValue = .object(["path": .string("Sources/Main.swift")])) -> JSONValue {
    toolEvent("tool_execution_start", ["toolCallId": .string(id), "toolName": .string(name), "args": args])
}

private func toolResult(_ id: String = "call", name: String? = "read", text: String = "result", error: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = ["role": .string("toolResult"), "toolCallId": .string(id),
                                      "content": .string(text), "isError": .bool(error)]
    fields["toolName"] = name.map(JSONValue.string)
    return .object(fields)
}

private func assistantCalls(_ calls: [(String, String, JSONValue)]) -> JSONValue {
    .object(["role": .string("assistant"), "content": .array(calls.map { id, name, args in
        .object(["type": .string("toolCall"), "id": .string(id), "name": .string(name), "arguments": args])
    })])
}

private func toolDisplayBytes(_ message: TranscriptMessage) -> Int {
    message.text.utf8.count + (message.thinking?.utf8.count ?? 0) + (message.tool?.displayBytes ?? 0)
}

@Test func toolPresentationLiveTargetSurvivesUpdatesEndsAndAuthoritativeMessage() throws {
    for (name, key, target) in [("read", "path", "Sources/Main.swift"), ("write", "path", "new.txt"),
                                ("edit", "path", "existing.txt"), ("bash", "command", "printf '文😀'")] {
        var reducer = TranscriptReducer()
        reducer.consume(toolStart(name: name, args: .object([key: .string(target), "content": .string("not a target")])))
        let id = try #require(reducer.messages.first?.id)
        #expect(reducer.messages.first?.tool == TranscriptTool(name: name, target: target, status: .running))
        #expect(reducer.messages.first?.streaming == true)
        reducer.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "toolName": .string(name),
            "args": .object([key: .string("changed target")]), "partialResult": .object(["content": .string("partial")])]))
        #expect(reducer.messages.first?.tool?.target == target)
        #expect(reducer.messages.first?.tool?.status == .running)
        #expect(reducer.messages.first?.text == name + "\npartial")
        reducer.consume(toolEvent("tool_execution_end", ["toolCallId": .string("call"), "toolName": .string(name),
            "isError": .bool(false), "result": .object(["content": .string("provisional")])]))
        #expect(reducer.messages.first?.tool?.status == .completed)
        #expect(reducer.messages.first?.streaming == false)
        let final = toolEvent("message_end", ["message": toolResult(name: name, text: "authoritative")])
        reducer.consume(final)
        reducer.consume(final)
        reducer.consume(toolEvent("agent_settled"))
        let message = try #require(reducer.messages.first)
        #expect(reducer.messages.count == 1)
        #expect(message.id == id)
        #expect(message.text == name + "\nauthoritative")
        #expect(message.tool == TranscriptTool(name: name, target: target, status: .completed))
        #expect(!message.streaming && !message.isError)
    }
}

@Test func toolMessageEndAloneIsFinalAndRetainsStartNameAndTarget() throws {
    var reducer = TranscriptReducer()
    reducer.consume(toolStart())
    let id = try #require(reducer.messages.first?.id)
    reducer.consume(toolEvent("message_end", ["message": toolResult(name: nil, text: "final without execution end")]))
    #expect(reducer.messages.first?.id == id)
    #expect(reducer.messages.first?.tool == TranscriptTool(name: "read", target: "Sources/Main.swift", status: .completed))
    #expect(reducer.messages.first?.text == "final without execution end")
    #expect(reducer.messages.first?.streaming == false)
}

@Test func toolSettlementWithoutFinalNeverClaimsSuccessOrCancellation() {
    for aborted in [false, true] {
        var reducer = TranscriptReducer()
        reducer.consume(toolEvent("agent_start"))
        reducer.consume(toolStart(name: "bash", args: .object(["command": .string("echo done")])))
        reducer.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "toolName": .string("bash"),
            "partialResult": .object(["content": .string("Completed successfully. Cancelled. exit 0")])]))
        reducer.consume(toolEvent("agent_end"))
        #expect(reducer.messages.first?.tool?.status == .running)
        reducer.consume(toolEvent("agent_settled", ["aborted": .bool(aborted)]))
        #expect(reducer.phase == "idle")
        #expect(reducer.messages.first?.tool?.status == .interrupted)
        #expect(reducer.messages.first?.streaming == false)
        #expect(reducer.messages.first?.isError == false)
        #expect(reducer.messages.first?.tool?.target == "echo done")
        reducer.consume(toolEvent("agent_settled"))
        #expect(reducer.messages.first?.tool?.status == .interrupted)
        // A later authoritative result can resolve an unknown outcome.
        reducer.consume(toolEvent("message_end", ["message": toolResult(name: "bash")]))
        #expect(reducer.messages.first?.tool?.status == .completed)
    }
}

@Test func toolFinalMessagesReplaceProvisionalFlagsWithoutParsingOutput() {
    for failed in [false, true] {
        var reducer = TranscriptReducer()
        reducer.consume(toolStart())
        reducer.consume(toolEvent("tool_execution_end", ["toolCallId": .string("call"), "toolName": .string("read"),
            "isError": .bool(failed), "result": .object(["content": .string("success or failure text is not a status"), "isError": .bool(!failed)])]))
        #expect(reducer.messages.first?.tool?.status == (failed ? .failed : .completed))
        #expect(reducer.messages.first?.isError == failed)
        reducer.consume(toolEvent("message_end", ["message": toolResult(text: "authoritative", error: !failed)]))
        reducer.consume(toolEvent("agent_settled"))
        #expect(reducer.messages.first?.tool?.status == (failed ? .completed : .failed))
        #expect(reducer.messages.first?.isError == !failed)
    }
    var reducer = TranscriptReducer()
    reducer.consume(toolStart())
    reducer.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "isError": .bool(true)]))
    #expect(reducer.messages.first?.tool?.status == .running)
    reducer.consume(toolEvent("agent_settled"))
    #expect(reducer.messages.first?.tool?.status == .interrupted)
    #expect(reducer.messages.first?.isError == true)
}

@Test func toolAuthoritativeFinalCanResolvePartialErrorsAndHookOverrides() {
    var reducer = TranscriptReducer()
    reducer.consume(toolStart())
    reducer.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "partialResult": .object(["content": .string("retrying"), "isError": .bool(true)])]))
    reducer.consume(toolEvent("tool_execution_end", ["toolCallId": .string("call"), "isError": .bool(false), "result": .object(["content": .string("recovered"), "isError": .bool(true)])]))
    #expect(reducer.messages.first?.tool?.status == .completed)
    #expect(reducer.messages.first?.isError == false)
    reducer.consume(toolEvent("message_end", ["message": toolResult(text: "authoritative final")]))
    #expect(reducer.messages.first?.tool?.status == .completed)
    #expect(reducer.messages.first?.isError == false)

    var unresolved = TranscriptReducer()
    unresolved.consume(toolStart())
    unresolved.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "partialResult": .object(["isError": .bool(true)])]))
    unresolved.consume(toolEvent("agent_settled"))
    #expect(unresolved.messages.first?.tool?.status == .interrupted)
    #expect(unresolved.messages.first?.isError == true)
}

@Test func toolHistoryMatchesPrecedingAssistantCallsByExactIDNotPosition() {
    let first: JSONValue = .object(["path": .string("first.swift")])
    let second: JSONValue = .object(["command": .string("printf second")])
    let third: JSONValue = .object(["path": .string("latest.swift")])
    var reducer = TranscriptReducer()
    reducer.replaceHistory([
        toolResult("future", text: "no preceding call"),
        assistantCalls([("one", "edit", first), ("two😀", "bash", second)]),
        toolResult("two😀", name: "bash", text: "second result"),
        toolResult("one", name: nil, text: "first result", error: true),
        assistantCalls([("one", "write", third), ("future", "read", first)]),
        toolResult("one", name: "write", text: "latest result"),
        toolResult("unknown", name: "custom", text: "generic")
    ])
    let rows = reducer.messages.filter { $0.role == "tool" }
    #expect(rows.count == 5)
    #expect(rows[0].tool?.target == nil)
    #expect(rows[1].tool == TranscriptTool(name: "bash", target: "printf second", status: .completed))
    #expect(rows[2].tool == TranscriptTool(name: "edit", target: "first.swift", status: .failed))
    #expect(rows[3].tool == TranscriptTool(name: "write", target: "latest.swift", status: .completed))
    #expect(rows[4].tool == TranscriptTool(name: "custom", status: .completed))
    #expect(rows[2].isError)
    #expect(rows.allSatisfy { !$0.streaming })
}

@Test func toolHistoryRecoversCallsOutsideTheRetainedDisplayRows() {
    var reducer = TranscriptReducer()
    let call = assistantCalls([("old", "read", .object(["path": .string("old.swift")]))])
    let filler: JSONValue = .object(["role": .string("user"), "content": .string("message")])
    reducer.replaceHistory([call] + Array(repeating: filler, count: 110) + [toolResult("old")])
    #expect(reducer.omitted)
    #expect(reducer.messages.count == 100)
    #expect(reducer.messages.last?.tool?.target == "old.swift")
}

@Test func toolPresentationLegacySnapshotsDecodeAndOlderReadersIgnoreMetadata() throws {
    let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"tool","text":"old","isError":false,"streaming":false,"truncated":false}"#.utf8)
    let message = try JSONDecoder().decode(TranscriptMessage.self, from: old)
    #expect(message.tool == nil)
    var snapshot = HostSnapshot(host: UUID(), epoch: UUID())
    snapshot.messages = [message]
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: JSONEncoder().encode(snapshot)).messages.first?.tool == nil)

    struct OlderMessage: Codable {
        let id: UUID
        let role: String
        let text: String
        let isError: Bool
        let streaming: Bool
        let truncated: Bool
    }
    var current = message
    current.tool = TranscriptTool(name: "read", target: "file.swift", status: .interrupted)
    let data = try JSONEncoder().encode(current)
    let older = try JSONDecoder().decode(OlderMessage.self, from: data)
    #expect(older.text == "old" && older.id == current.id)
    #expect(try JSONDecoder().decode(TranscriptMessage.self, from: data) == current)
}

@Test func toolTargetsUseOnlyKnownStringArgumentsAndRemainUntrustedText() {
    let malicious = "../../secret/$(touch /tmp/not-executed);\"\nfile://host/path\u{001B}[31m😀"
    let cases: [(String, JSONValue, String?)] = [
        ("read", .object(["path": .string(malicious)]), malicious),
        ("bash", .object(["command": .string(malicious)]), malicious),
        ("custom", .object(["path": .string("not selected"), "command": .string("not selected"), "token": .string("secret")]), nil),
        ("read", .object(["path": .object(["value": .string("not coerced")])]), nil),
        ("read", .object(["path": .array([.string("not coerced")])]), nil),
        ("read", .object(["path": .number(42)]), nil),
        ("write", .object(["content": .string("file contents are not a target")]), nil),
        ("edit", .object(["path": .null]), nil),
        ("read", .object(["path": .string("")]), nil),
        ("bash", .string("{\"command\":\"not parsed\"}"), nil)
    ]
    for (name, arguments, target) in cases {
        var reducer = TranscriptReducer()
        reducer.consume(toolStart(name: name, args: arguments))
        #expect(reducer.messages.first?.tool == TranscriptTool(name: name, target: target, status: .running))
    }
    var reducer = TranscriptReducer()
    reducer.consume(toolEvent("tool_execution_start", ["toolCallId": .string("call"), "toolName": .number(42)]))
    #expect(reducer.messages.first?.tool?.name == "Tool")
}

@Test func toolPresentationBoundsUnicodeMetadataOnConstructionAndDecode() throws {
    let huge = String(repeating: "😀文e\u{0301}", count: 5_000)
    let tool = TranscriptTool(name: huge, target: huge, status: .running)
    #expect(tool.name.utf8.count <= 128)
    #expect(tool.target!.utf8.count <= 1_024)
    #expect(!tool.name.contains("\u{FFFD}") && !tool.target!.contains("\u{FFFD}"))
    let raw = try JSONEncoder().encode(["name": huge, "target": huge, "status": "running"])
    #expect(try JSONDecoder().decode(TranscriptTool.self, from: raw) == tool)

    var reducer = TranscriptReducer()
    reducer.consume(toolStart(name: huge, args: .object(["path": .string(huge)])))
    #expect(reducer.messages.first?.truncated == true)
    #expect(toolDisplayBytes(reducer.messages[0]) <= 16_384)
    #expect(reducer.messages.first?.tool?.target == nil)
    reducer = TranscriptReducer()
    reducer.consume(toolStart(args: .object(["path": .string(huge)])))
    #expect(reducer.messages.first?.truncated == true)
    #expect(reducer.messages.first!.tool!.target!.utf8.count <= 1_024)
    reducer.consume(toolEvent("message_end", ["message": toolResult(text: "final")]))
    #expect(reducer.messages.first?.truncated == true)
}

@Test func toolMetadataSharesStaticLiveHistoricalAndAggregateDisplayBudgets() throws {
    let huge = String(repeating: "文😀e\u{0301}", count: 10_000)
    let raw = toolResult(name: huge, text: huge)
    let projected = try #require(TranscriptReducer.message(raw))
    #expect(toolDisplayBytes(projected) <= 16_384)
    #expect(projected.truncated)

    var live = TranscriptReducer()
    live.consume(toolStart(args: .object(["path": .string(huge)])))
    live.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "toolName": .string("read"),
        "partialResult": .object(["content": .array([
            .object(["type": .string("text"), "text": .string(huge)]),
            .object(["type": .string("thinking"), "thinking": .string(huge)])])])]))
    #expect(toolDisplayBytes(live.messages[0]) <= 16_384)
    live.consume(toolEvent("agent_settled"))
    #expect(live.messages.first?.tool?.status == .interrupted)
    #expect(toolDisplayBytes(live.messages[0]) <= 16_384)
    #expect(live.messages.first?.truncated == true)

    let assistant = assistantCalls([("call", "read", .object(["path": .string(huge)]))])
    var historical = TranscriptReducer()
    historical.replaceHistory([assistant] + Array(repeating: toolResult(text: huge), count: 120))
    #expect(historical.omitted)
    #expect(historical.messages.allSatisfy { toolDisplayBytes($0) <= 16_384 && $0.truncated })
    #expect(historical.messages.reduce(0) { $0 + toolDisplayBytes($1) } <= 256 * 1_024)
    #expect(historical.messages.last?.tool?.target?.utf8.count == DisplayLimit.text(huge, bytes: 1_024).utf8.count)
    #expect(historical.messages.allSatisfy { !$0.text.contains("\u{FFFD}") })
}

@Test func toolImagesErrorsAndTruncationSurviveMetadataAndFinalReplacement() throws {
    let ids = (0..<18).map { _ in UUID() }
    let images: [JSONValue] = ids.map { .object(["type": .string("image"), "remoteImageID": .string($0.uuidString),
                                               "remoteImageFault": .string("unavailable")]) }
    var reducer = TranscriptReducer()
    reducer.consume(toolStart())
    let id = try #require(reducer.messages.first?.id)
    let final = ["role": JSONValue.string("toolResult"), "toolCallId": .string("call"), "toolName": .string("read"),
                 "isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("failure details")])] + images)]
    reducer.consume(toolEvent("tool_execution_update", ["toolCallId": .string("call"), "toolName": .string("read"),
        "partialResult": .object(["content": .array(images)])]))
    reducer.consume(toolEvent("message_end", ["message": .object(final)]))
    let message = try #require(reducer.messages.first)
    #expect(message.id == id)
    #expect(message.images?.map(\.id) == Array(ids.prefix(16)))
    #expect(message.images?.first?.fault == .unavailable)
    #expect(message.truncated && message.isError)
    #expect(message.text.hasPrefix("read\nfailure details\n[Image]"))
    #expect(message.tool == TranscriptTool(name: "read", target: "Sources/Main.swift", status: .failed))
}

@Test func toolAggregatePressureOmitsMetadataRatherThanLosingOutcome() {
    let call = assistantCalls([("call", "read", .object(["path": .string(String(repeating: "x", count: 1_024))]))])
    let full: JSONValue = .object(["role": .string("user"), "content": .string(String(repeating: "x", count: 16_384))])
    let remainder: JSONValue = .object(["role": .string("user"), "content": .string(String(repeating: "x", count: 16_384 - 100))])
    var reducer = TranscriptReducer()
    reducer.replaceHistory([call, toolResult()] + Array(repeating: full, count: 15) + [remainder])
    #expect(reducer.omitted)
    #expect(reducer.messages.allSatisfy { $0.role != "tool" })
    #expect(reducer.messages.count == 16)
    #expect(reducer.messages.reduce(0) { $0 + toolDisplayBytes($1) } <= 256 * 1_024)
}

@Test func toolPresentationCorrelatesLongUntrustedCallIDsWithoutPrefixCollisions() {
    let prefix = String(repeating: "😀", count: 1_000)
    let first = prefix + "first"
    let second = prefix + "second"
    var reducer = TranscriptReducer()
    reducer.consume(toolStart(first, args: .object(["path": .string("first.swift")])))
    reducer.consume(toolStart(second, args: .object(["path": .string("second.swift")])))
    let ids = reducer.messages.map(\.id)
    reducer.consume(toolEvent("message_end", ["message": toolResult(second, text: "second final", error: true)]))
    reducer.consume(toolEvent("agent_settled"))
    #expect(reducer.messages.map(\.id) == ids)
    #expect(reducer.messages[0].tool == TranscriptTool(name: "read", target: "first.swift", status: .interrupted))
    #expect(reducer.messages[1].tool == TranscriptTool(name: "read", target: "second.swift", status: .failed))
    #expect(reducer.messages[1].text == "read\nsecond final")

    reducer.replaceHistory([
        assistantCalls([(first, "read", .object(["path": .string("first.swift")])),
                        (second, "read", .object(["path": .string("second.swift")]))]),
        toolResult(second), toolResult(first)
    ])
    #expect(reducer.messages[1].tool?.target == "second.swift")
    #expect(reducer.messages[2].tool?.target == "first.swift")
}

@Test func toolPresentationKeepsEmptyFinalErrorsVisibleWithoutStartOrName() throws {
    let empty = toolResult(name: nil, text: "", error: true)
    let message = try #require(TranscriptReducer.message(empty))
    #expect(message.isError)
    #expect(message.tool == TranscriptTool(name: "Tool", status: .failed))
    var reducer = TranscriptReducer()
    reducer.consume(toolEvent("message_end", ["message": empty]))
    reducer.consume(toolEvent("agent_settled"))
    #expect(reducer.messages.count == 1)
    #expect(reducer.messages.first?.tool?.status == .failed)
    #expect(reducer.messages.first?.isError == true)
}
