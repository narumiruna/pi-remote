import Foundation
import Testing
@testable import PiRemoteCore

private func record(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    .object(fields.merging(["type": .string(type)]) { _, new in new })
}
private func assistantUpdate(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    record("message_update", ["assistantMessageEvent": record(type, fields.merging(["contentIndex": .number(0)]) { old, _ in old })])
}

@Test func standaloneManualCompactionRestoresIdleOnFailureAndCancellation() {
    for aborted in [false, true] {
        var reducer = TranscriptReducer()
        reducer.consume(record("compaction_start", ["reason": .string("manual")]))
        #expect(reducer.phase == "compacting")
        reducer.consume(record("compaction_end", ["reason": .string("manual"), "aborted": .bool(aborted),
                                                  "errorMessage": .string("Compaction failed: unavailable")]))
        #expect(reducer.phase == "idle")
        #expect(reducer.messages.count == (aborted ? 0 : 1))
        if !aborted { #expect(reducer.messages.first?.isError == true) }
    }
}

@Test func manualCompactionSuccessAndHistoryRefreshPreserveActivity() {
    for active in [false, true] {
        var reducer = TranscriptReducer()
        if active { reducer.consume(record("agent_start")) }
        reducer.consume(record("compaction_start", ["reason": .string("manual")]))
        reducer.replaceHistory([])
        #expect(reducer.phase == "compacting")
        reducer.consume(record("compaction_end", ["reason": .string("manual"), "result": .object([:])]))
        #expect(reducer.phase == (active ? "working" : "idle"))
    }
}

@Test func automaticCompactionAndRetryNeverSettleAnActiveRun() {
    for reason in ["threshold", "overflow"] {
        var reducer = TranscriptReducer()
        reducer.consume(record("compaction_start", ["reason": .string(reason)]))
        reducer.consume(record("compaction_end", ["willRetry": .bool(reason == "overflow")]))
        #expect(reducer.phase == "working")
        reducer.consume(record("auto_retry_start", ["attempt": .number(1), "maxAttempts": .number(3)]))
        #expect(reducer.phase == "retrying")
        reducer.replaceHistory([])
        #expect(reducer.phase == "retrying")
        reducer.consume(record("auto_retry_end", ["success": .bool(true), "attempt": .number(1)]))
        #expect(reducer.phase == "working")
        reducer.consume(record("agent_end"))
        #expect(reducer.phase == "working")
        reducer.consume(record("agent_settled"))
        #expect(reducer.phase == "idle")
    }
}

@Test func summarizationRetryRestoresCompactionBetweenAttemptsAndOnCompletion() {
    var reducer = TranscriptReducer()
    reducer.consume(record("compaction_start", ["reason": .string("manual")]))
    for attempt in 1...2 {
        reducer.consume(record("summarization_retry_scheduled", ["attempt": .number(Double(attempt)), "errorMessage": .string("transient")]))
        #expect(reducer.phase == "retrying")
        reducer.consume(record("summarization_retry_attempt_start", ["source": .string("compaction"), "reason": .string("manual")]))
        #expect(reducer.phase == "compacting")
    }
    reducer.consume(record("summarization_retry_finished"))
    #expect(reducer.phase == "compacting")
    #expect(reducer.messages.isEmpty)
    reducer.consume(record("compaction_end", ["aborted": .bool(true)]))
    #expect(reducer.phase == "idle")
}

@Test func finalRetryErrorsUseOnlyContractFieldsAndRemainBounded() {
    var reducer = TranscriptReducer()
    reducer.consume(record("auto_retry_start", ["errorMessage": .string("transient")]))
    #expect(reducer.messages.isEmpty)
    reducer.consume(record("auto_retry_end", ["success": .bool(false), "errorMessage": .string("not final")]))
    #expect(reducer.messages.isEmpty)
    let error = String(repeating: "界", count: 20_000)
    reducer.consume(record("auto_retry_end", ["success": .bool(false), "finalError": .string(error)]))
    #expect(reducer.messages.first?.isError == true)
    #expect(reducer.messages.first?.truncated == true)
    #expect(reducer.messages.first!.text.utf8.count <= 16_384)
    #expect(reducer.phase == "working")
    reducer.consume(record("agent_settled"))
    #expect(reducer.phase == "idle")
    reducer.consume(record("compaction_start", ["reason": .string("manual")]))
    reducer.consume(record("compaction_end", ["aborted": .bool(false), "errorMessage": .string(error)]))
    #expect(reducer.messages.last?.truncated == true)
    #expect(reducer.phase == "idle")
}

@Test func finalToolResultReplacesExecutionResultWithStableIdentityAndImages() {
    var reducer = TranscriptReducer()
    let image = UUID()
    reducer.consume(record("tool_execution_start", ["toolCallId": .string("call"), "toolName": .string("read")]))
    let id = reducer.messages[0].id
    reducer.consume(record("tool_execution_end", ["toolCallId": .string("call"), "toolName": .string("read"),
                                                "result": .object(["content": .string("provisional")])]))
    let final: JSONValue = .object(["role": .string("toolResult"), "toolCallId": .string("call"), "toolName": .string("read"),
                                   "isError": .bool(true), "content": .array([
                                    .object(["type": .string("text"), "text": .string("corrected")]),
                                    .object(["type": .string("image"), "remoteImageID": .string(image.uuidString)])])])
    reducer.consume(record("message_end", ["message": final]))
    reducer.consume(record("message_end", ["message": final]))
    #expect(reducer.messages.count == 1)
    #expect(reducer.messages[0].id == id)
    #expect(reducer.messages[0].text == "read\ncorrected\n[Image]")
    #expect(reducer.messages[0].isError)
    #expect(!reducer.messages[0].streaming)
    #expect(reducer.messages[0].images?.first?.id == image)
}

@Test func toolCallBlocksRenderArgumentsAndAuthoritativeCompletion() {
    var reducer = TranscriptReducer()
    reducer.consume(record("message_start", ["message": .object(["role": .string("assistant")])]))
    reducer.consume(assistantUpdate("toolcall_start", ["id": .string("call"), "toolName": .string("read")]))
    reducer.consume(assistantUpdate("toolcall_delta", ["delta": .string("{\"path\":\"partial")]))
    #expect(reducer.messages[0].text == "read\n{\"path\":\"partial")
    let call: JSONValue = .object(["type": .string("toolCall"), "id": .string("call"), "name": .string("read"),
                                  "arguments": .object(["path": .string("complete.swift")])])
    reducer.consume(assistantUpdate("toolcall_end", ["toolCall": call]))
    #expect(reducer.messages[0].text == "read\n{\"path\":\"complete.swift\"}")
    reducer.consume(record("message_end", ["message": .object(["role": .string("assistant"), "content": .array([call])])]))
    #expect(reducer.messages.count == 1)
    #expect(reducer.messages[0].text == "read\n{\"path\":\"complete.swift\"}")
    #expect(!reducer.messages[0].streaming)
}

@Test func toolArgumentsRespectUTF8BlockMessageAndAggregateBudgets() {
    var reducer = TranscriptReducer()
    let huge = String(repeating: "😀", count: 20_000)
    reducer.consume(record("message_start", ["message": .object(["role": .string("assistant")])]))
    reducer.consume(assistantUpdate("toolcall_start", ["toolName": .string(huge)]))
    reducer.consume(assistantUpdate("toolcall_delta", ["delta": .string(huge)]))
    #expect(reducer.messages[0].truncated)
    #expect(reducer.messages[0].text.utf8.count <= 16_384)
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("toolCall"), "name": .string("write"), "arguments": .object(["content": .string(huge)])])])])
    reducer.replaceHistory(Array(repeating: raw, count: 200))
    #expect(reducer.omitted)
    #expect(reducer.messages.count <= 100)
    #expect(reducer.messages.allSatisfy { $0.truncated && $0.text.utf8.count <= 16_384 })
    #expect(reducer.messages.reduce(0) { $0 + $1.text.utf8.count } <= 256 * 1_024)
}
