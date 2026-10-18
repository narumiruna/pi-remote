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
    #expect(reducer.messages[1].text.hasSuffix("\n[cancelled]"))
}

private func shellRecord(command: String = "printf fixture", output: String = "fixture",
                         exit: JSONValue? = .number(0), cancelled: Bool = false,
                         excluded: Bool = false, truncated: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = [
        "role": .string("bashExecution"), "command": .string(command), "output": .string(output),
        "cancelled": .bool(cancelled), "excludeFromContext": .bool(excluded), "truncated": .bool(truncated)
    ]
    fields["exitCode"] = exit
    return .object(fields)
}

@Test func savedShellLargeOutputPreservesEveryOutcomeAndExclusion() throws {
    let cases: [(JSONValue?, Bool, String, Bool)] = [
        (.number(7), false, "exit 7", true),
        (.number(7), true, "cancelled", false),
        (.number(0), false, "exit 0", false),
        (nil, false, "exit unavailable", false),
        (.null, false, "exit unavailable", false)
    ]
    for (exit, cancelled, status, isError) in cases {
        for excluded in [false, true] {
            let message = try #require(TranscriptReducer.message(shellRecord(
                output: String(repeating: "文😀e\u{0301}", count: 5_000), exit: exit,
                cancelled: cancelled, excluded: excluded)))
            let footer = "\n[" + status + (excluded ? " · excluded from model context" : "") + "]"
            #expect(message.text.hasPrefix((excluded ? "!! " : "! ") + "printf fixture\n"))
            #expect(message.text.hasSuffix(footer))
            #expect(message.text.utf8.count <= 16_384)
            #expect(!message.text.contains("\u{FFFD}"))
            #expect(message.truncated)
            #expect(message.isError == isError)
        }
    }
}

@Test func savedShellExitCodesRequireFiniteInt32Integers() throws {
    let cases: [(JSONValue, String, Bool)] = [
        (.number(-1), "exit -1", true),
        (.number(0), "exit 0", false),
        (.number(-2_147_483_648), "exit -2147483648", true),
        (.number(2_147_483_647), "exit 2147483647", true),
        (.number(0.4), "exit unavailable", false),
        (.number(-0.4), "exit unavailable", false),
        (.number(2_147_483_648), "exit unavailable", false),
        (.number(-2_147_483_649), "exit unavailable", false),
        (.number(.infinity), "exit unavailable", false),
        (.number(.nan), "exit unavailable", false),
        (.string("0"), "exit unavailable", false)
    ]
    for (exit, status, isError) in cases {
        let message = try #require(TranscriptReducer.message(shellRecord(exit: exit)))
        #expect(message.text == "! printf fixture\nfixture\n[" + status + "]")
        #expect(message.isError == isError)
        #expect(!message.truncated)
    }
}

@Test func savedShellLongUnicodeCommandKeepsHeaderAndOutcome() throws {
    for cancelled in [false, true] {
        let command = "printf '" + String(repeating: "😀文e\u{0301}", count: 5_000) + "'"
        let message = try #require(TranscriptReducer.message(shellRecord(
            command: command, output: String(repeating: "output", count: 5_000),
            exit: .number(9), cancelled: cancelled, excluded: true)))
        #expect(message.text.hasPrefix("!! printf '😀文"))
        #expect(message.text.hasSuffix(cancelled
            ? "\n[cancelled · excluded from model context]"
            : "\n[exit 9 · excluded from model context]"))
        #expect(message.text.utf8.count <= 16_384)
        #expect(!message.text.contains("\u{FFFD}"))
        #expect(message.truncated)
        #expect(message.isError == !cancelled)
    }
}

@Test func savedShellExactUTF8BoundaryAndUpstreamTruncation() throws {
    let command = "printf 文"
    let header = "!! " + command + "\n"
    let footer = "\n[exit 0 · excluded from model context]"
    let outputBudget = 16_384 - header.utf8.count - footer.utf8.count
    for offset in [-1, 0, 1] {
        for upstreamTruncated in [false, true] {
            let output = "😀" + String(repeating: "x", count: outputBudget - 4 + offset)
            let message = try #require(TranscriptReducer.message(shellRecord(
                command: command, output: output, excluded: true, truncated: upstreamTruncated)))
            #expect(message.text == header + DisplayLimit.text(output, bytes: outputBudget) + footer)
            #expect(message.text.utf8.count == min(16_384, 16_384 + offset))
            #expect(message.truncated == (offset > 0 || upstreamTruncated))
            #expect(!message.isError)
        }
    }
    // The byte boundary falls inside a four-byte scalar, not after one.
    let splitScalar = try #require(TranscriptReducer.message(shellRecord(
        command: command, output: String(repeating: "x", count: outputBudget - 1) + "😀", excluded: true)))
    #expect(splitScalar.text == header + String(repeating: "x", count: outputBudget - 1) + footer)
    #expect(splitScalar.truncated)
}

@Test func savedShellAggregateBudgetKeepsWholeRowsOrOmitsThem() throws {
    let raw = shellRecord(output: String(repeating: "文😀", count: 5_000), exit: .number(23), excluded: true)
    let projected = try #require(TranscriptReducer.message(raw))
    // Fifteen full rows leave at most 16 KiB for the oldest shell row.
    for remaining in [1, 64, 4_096, projected.text.utf8.count - 1, projected.text.utf8.count, 16_384] {
        var reducer = TranscriptReducer()
        let full: JSONValue = .object(["role": .string("user"), "content": .string(String(repeating: "x", count: 16_384))])
        var newer = Array(repeating: full, count: 15)
        if remaining < 16_384 {
            newer.append(.object(["role": .string("user"), "content": .string(String(repeating: "x", count: 16_384 - remaining))]))
        }
        reducer.replaceHistory([raw] + newer)
        let shells = reducer.messages.filter { $0.role == "bash" }
        if remaining >= projected.text.utf8.count {
            let retained = try #require(shells.first)
            #expect(shells.count == 1)
            #expect(retained.text == projected.text)
            #expect(retained.isError && retained.truncated)
            #expect(!reducer.omitted)
            let id = retained.id
            reducer.consume(.object(["type": .string("future_event")]))
            #expect(reducer.messages.first?.id == id)
            #expect(reducer.messages.first?.text == projected.text)
        } else {
            #expect(shells.isEmpty)
            #expect(reducer.omitted)
            #expect(reducer.messages.count == newer.count)
        }
        #expect(reducer.messages.allSatisfy { $0.text.utf8.count <= 16_384 })
        #expect(reducer.messages.reduce(0) { $0 + $1.text.utf8.count } <= 256 * 1_024)
    }
}

@Test func savedShellLatestOutcomeSurvivesAggregatePressure() throws {
    for cancelled in [false, true] {
        let raw = shellRecord(output: String(repeating: "文", count: 10_000), exit: .number(5),
                              cancelled: cancelled, excluded: true)
        let older: JSONValue = .object(["role": .string("user"), "content": .string(String(repeating: "x", count: 16_384))])
        var reducer = TranscriptReducer()
        reducer.replaceHistory(Array(repeating: older, count: 20) + [raw])
        let latest = try #require(reducer.messages.last)
        #expect(latest.role == "bash")
        #expect(latest.text.hasPrefix("!! printf fixture\n"))
        #expect(latest.text.hasSuffix(cancelled
            ? "\n[cancelled · excluded from model context]"
            : "\n[exit 5 · excluded from model context]"))
        #expect(latest.isError == !cancelled)
        #expect(latest.truncated)
        #expect(reducer.omitted)
        #expect(reducer.messages.reduce(0) { $0 + $1.text.utf8.count } <= 256 * 1_024)
    }
}

@Test func savedShellMessageEndUsesSameProjectionWithoutDuplicateOutput() throws {
    let raw = shellRecord(output: String(repeating: "文", count: 10_000), cancelled: true, excluded: true)
    let projected = try #require(TranscriptReducer.message(raw))
    var reducer = TranscriptReducer()
    reducer.consume(.object(["type": .string("message_end"), "message": raw]))
    #expect(reducer.messages.count == 1)
    let retained = try #require(reducer.messages.first)
    #expect(retained.text == projected.text)
    #expect(retained.text.hasSuffix("\n[cancelled · excluded from model context]"))
    #expect(retained.truncated && !retained.isError)
    reducer.consume(.object(["type": .string("agent_settled")]))
    #expect(reducer.messages.count == 1)
    #expect(reducer.messages.first?.id == retained.id)
}
