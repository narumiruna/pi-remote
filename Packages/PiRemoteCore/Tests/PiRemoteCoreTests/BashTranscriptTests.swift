import Foundation
import Testing
@testable import PiRemoteCore

@Test func savedShellMessagesPreserveCommandExitAndContextExclusion() throws {
    let record: JSONValue = .object([
        "role": .string("bashExecution"), "command": .string("printf 'fixture'"),
        "output": .string("fixture"), "exitCode": .number(7), "excludeFromContext": .bool(true)
    ])
    let message = try #require(TranscriptReducer.message(record))
    #expect(message.role == "bash")
    #expect(message.text == "!! printf 'fixture'\nfixture\n[exit 7 · excluded from model context]")
    #expect(message.isError)
    #expect(!message.truncated)
}

@Test func savedShellTranscriptRetainsTwoResultsAndBoundsOutput() {
    var reducer = TranscriptReducer()
    let first: JSONValue = .object(["role": .string("bashExecution"), "command": .string("first"), "output": .string("one"), "exitCode": .number(0)])
    let second: JSONValue = .object(["role": .string("bashExecution"), "command": .string("second"), "output": .string(String(repeating: "文", count: 30_000)), "cancelled": .bool(true)])
    reducer.replaceHistory([first, second])
    #expect(reducer.messages.count == 2)
    #expect(reducer.messages[0].text.hasPrefix("! first\none"))
    #expect(reducer.messages[1].role == "bash")
    #expect(reducer.messages[1].text.utf8.count <= 16_384)
    #expect(reducer.messages[1].truncated)
    #expect(!reducer.messages[1].isError)
}
