import Foundation
import Testing
@testable import PiRemoteCore

private func event(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    .object(fields.merging(["type": .string(type)]) { _, value in value })
}
private func update(_ type: String, index: Int, text: String) -> JSONValue {
    event("message_update", ["assistantMessageEvent": event(type, ["contentIndex": .number(Double(index)),
                                                                type.hasSuffix("_end") ? "content" : "delta": .string(text)])])
}

@Test func interleavedBlocksUseAuthoritativeEndsAndFinalMessages() throws {
    var reducer = TranscriptReducer()
    reducer.consume(event("agent_start"))
    reducer.consume(event("message_start", ["message": .object(["role": .string("assistant")])]))
    reducer.consume(update("thinking_delta", index: 0, text: "Partial thought"))
    reducer.consume(update("text_delta", index: 1, text: "Partial answer"))
    reducer.consume(update("text_delta", index: 3, text: "Second block"))
    reducer.consume(update("thinking_end", index: 0, text: "Complete thought"))
    reducer.consume(update("text_end", index: 1, text: "Complete answer"))
    #expect(reducer.messages.first?.thinking == "Complete thought")
    #expect(reducer.messages.first?.text == "Complete answer\nSecond block")
    let final: JSONValue = .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("thinking"), "thinking": .string("Final thought"), "thinkingSignature": .string("private-signature")]),
        .object(["type": .string("thinking"), "redacted": .bool(true), "thinking": .string("must not display"), "thinkingSignature": .string("encrypted")]),
        .object(["type": .string("text"), "text": .string("Final answer")])])])
    reducer.consume(event("message_end", ["message": final]))
    #expect(reducer.messages.first?.text == "Final answer")
    #expect(reducer.messages.first?.thinking == "Final thought")
    let encoded = try JSONEncoder().encode(reducer.messages)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("signature"))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("must not display"))
    reducer.consume(event("agent_end"))
    #expect(reducer.phase == "working")
    reducer.consume(event("agent_settled"))
    #expect(reducer.phase == "idle")
}

@Test func thinkingSharesTheUTF8DisplayBudgetAndLegacyMessagesDecode() throws {
    let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"old","isError":false,"streaming":false,"truncated":false}"#.utf8)
    #expect(try JSONDecoder().decode(TranscriptMessage.self, from: old).thinking == nil)
    let huge = "x" + String(repeating: "\u{0301}", count: 100_000)
    let raw: JSONValue = .object(["role": .string("assistant"), "content": .array([
        .object(["type": .string("text"), "text": .string("Answer")]),
        .object(["type": .string("thinking"), "thinking": .string(huge)])])])
    var reducer = TranscriptReducer()
    reducer.replaceHistory(Array(repeating: raw, count: 200))
    #expect(reducer.omitted)
    #expect(reducer.messages.allSatisfy { $0.text.utf8.count + ($0.thinking?.utf8.count ?? 0) <= 16_384 && $0.truncated })
    #expect(reducer.messages.reduce(0) { $0 + $1.text.utf8.count + ($1.thinking?.utf8.count ?? 0) } <= 256 * 1_024)
}

@Test func emptyErrorsRemainVisibleAndHiddenCustomMessagesStayHidden() {
    #expect(TranscriptReducer.message(.object(["role": .string("custom"), "display": .bool(false), "content": .string("hidden")])) == nil)
    let message = TranscriptReducer.message(.object(["role": .string("assistant"), "stopReason": .string("error"), "errorMessage": .string("Provider unavailable"), "content": .array([])]))
    #expect(message?.isError == true && message?.text == "Provider unavailable")
}

@Test func retryCompactionAndCancellationWaitForSettlement() {
    var reducer = TranscriptReducer()
    reducer.consume(event("agent_start")); reducer.consume(event("auto_retry_start"))
    #expect(reducer.phase == "retrying")
    reducer.consume(event("compaction_start")); #expect(reducer.phase == "compacting")
    reducer.consume(event("compaction_end", ["aborted": .bool(true)]))
    reducer.consume(event("agent_end")); #expect(reducer.phase != "idle")
    reducer.consume(event("agent_settled", ["aborted": .bool(true)])); #expect(reducer.phase == "idle")
}

@Test func markdownPreservesBlocksInlineStylesAndTables() {
    let document = MarkdownDocument("# Heading\n\nA **bold** paragraph.\n\n1. First\n2. Second\n\n> Quoted\n\n| A | B |\n|---|---|\n| one | two |\n\n~~~swift\nlet a = 1\n~~~\n\n---")
    #expect(document.blocks.contains { $0.kind == .heading(1) })
    #expect(document.blocks.contains { $0.marker == "2." })
    #expect(document.blocks.contains { $0.quoted && String($0.text.characters) == "Quoted" })
    #expect(document.blocks.contains { $0.kind == .code && $0.language == "swift" && String($0.text.characters).contains("let a = 1") })
    #expect(document.blocks.contains { $0.kind == .rule })
    let table = document.blocks.first { $0.kind == .table }
    #expect(table?.rows.map { $0.map { String($0.characters) } } == [["A", "B"], ["one", "two"]])
    let paragraph = document.blocks.first { String($0.text.characters).contains("bold") }
    #expect(paragraph?.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true } == true)
}

@Test func oversizedTablesFallBackToCompleteSourceInsteadOfDroppingCells() {
    let source = "|" + Array(repeating: "Header", count: 257).joined(separator: "|") + "|\n|" +
        Array(repeating: "---", count: 257).joined(separator: "|") + "|\n|" +
        Array(repeating: "Value", count: 257).joined(separator: "|") + "|"
    let document = MarkdownDocument(source)
    #expect(document.blocks.count == 1)
    #expect(String(document.blocks[0].text.characters).contains(source))
}

@Test func markdownHandlesUnfinishedFencesAndNestedLists() {
    let document = MarkdownDocument("- Outer\n  - Inner\n\n````\n```literal\n")
    #expect(document.blocks.contains { $0.indent == 2 && String($0.text.characters) == "Inner" })
    #expect(document.blocks.contains { $0.kind == .code && String($0.text.characters).contains("```literal") })
}
