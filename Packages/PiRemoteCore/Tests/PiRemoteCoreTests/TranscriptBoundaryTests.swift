import Testing
@testable import PiRemoteCore

@Test func turnAndAgentEndRecordsCannotDeclareSettlementOrDuplicateMessages() {
    var reducer = TranscriptReducer()
    reducer.consume(.object(["type": .string("agent_start")]))
    let complete: JSONValue = .object(["role": .string("assistant"), "content": .string("Complete answer")])
    reducer.consume(.object(["type": .string("message_end"), "message": complete]))
    let events: [JSONValue] = [
        .object(["type": .string("turn_start")]),
        .object(["type": .string("turn_end"), "message": complete, "toolResults": .array([])]),
        .object(["type": .string("agent_end"), "messages": .array([complete]), "willRetry": .bool(false)])
    ]
    for event in events {
        reducer.consume(event)
        #expect(reducer.phase == "working")
        #expect(reducer.messages.count == 1)
        #expect(reducer.messages[0].text == "Complete answer")
    }
    reducer.consume(.object(["type": .string("agent_settled"), "aborted": .bool(false)]))
    #expect(reducer.phase == "idle")
}

@Test func branchSummaryRetryRestoresThePriorPhaseWithoutInventingAgentWork() {
    for active in [false, true] {
        var reducer = TranscriptReducer()
        if active { reducer.consume(.object(["type": .string("agent_start")])) }
        reducer.consume(.object(["type": .string("summarization_retry_scheduled"), "attempt": .number(1)]))
        #expect(reducer.phase == "retrying")
        reducer.consume(.object(["type": .string("summarization_retry_attempt_start"), "source": .string("branchSummary")]))
        #expect(reducer.phase == (active ? "working" : "idle"))
        reducer.consume(.object(["type": .string("summarization_retry_finished")]))
        #expect(reducer.phase == (active ? "working" : "idle"))
        #expect(reducer.messages.isEmpty)
    }
}

@Test func opaqueExtensionEntriesAndUnknownEventsDoNotBecomeConversationMessages() {
    var reducer = TranscriptReducer()
    for type in ["entry_appended", "future_event"] {
        reducer.consume(.object(["type": .string(type), "entry": .object([
            "type": .string("custom"), "customType": .string("fixture"), "data": .string("opaque metadata")
        ])]))
    }
    #expect(reducer.messages.isEmpty)
    #expect(reducer.phase == "idle")
}
