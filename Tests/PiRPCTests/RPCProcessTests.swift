import Foundation
import PiRemoteCore
import Testing
@testable import PiRPC

private let readCommand = #"""
while IFS= read -r line; do
    id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    command=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
"""# + "\n"

private func fake(_ body: String, eventCapacity: Int = 256, executable: String = "/bin/sh") throws -> RPCProcess {
    try RPCProcess(
        executable: URL(fileURLWithPath: executable),
        arguments: ["-c", body],
        workingDirectory: FileManager.default.temporaryDirectory,
        eventCapacity: eventCapacity
    )
}

@Test func correlatesConcurrentResponses() async throws {
    let child = try fake(readCommand + #"""
    printf '{"id":"%s","type":"response","command":"%s","success":true,"data":{"value":"%s"}}\n' "$id" "$command" "$command"
done
"""#)
    do {
        async let a = child.request("first")
        async let b = child.request("second")
        let values = try await (a, b)
        #expect(values.0["value"]?.string == "first")
        #expect(values.1["value"]?.string == "second")
    } catch { await child.shutdown(); throw error }
    await child.shutdown()
}

@Test func stopClearsQueueBeforeAbortAndConfirmsIdle() async throws {
    let child = try fake(readCommand + #"""
    case "$command" in
        clear_queue) expected=abort ;;
        abort) [ "$expected" = abort ] || exit 12; expected=get_state ;;
        get_state) [ "$expected" = get_state ] || exit 13 ;;
        *) exit 14 ;;
    esac
    printf '{"id":"%s","type":"response","command":"%s","success":true,"data":{"isStreaming":false,"isCompacting":false,"pendingMessageCount":0}}\n' "$id" "$command"
done
"""#)
    do { try await child.stopWork() }
    catch { await child.shutdown(); throw error }
    await child.shutdown()
}

@Test func timeoutHasUnknownOutcomeAndDoesNotResend() async throws {
    let child = try fake("while IFS= read -r line; do :; done")
    await #expect(throws: RPCFailure.unknownOutcome) {
        try await child.request("prompt", timeout: 0.05)
    }
    await child.shutdown()
}

@Test func unexpectedExitHasUnknownOutcome() async throws {
    let child = try fake("IFS= read -r line; exit 3")
    await #expect(throws: RPCFailure.unknownOutcome) { try await child.request("prompt") }
    await child.shutdown()
}

@Test func rejectsMalformedStdout() async throws {
    let child = try fake("IFS= read -r line; printf 'not-json\\n'")
    await #expect(throws: RPCFailure.unknownOutcome) { try await child.request("get_state") }
    await child.shutdown()
}

@Test func rejectsMismatchedResponseCommand() async throws {
    let child = try fake(readCommand + #"""
    printf '{"id":"%s","type":"response","command":"wrong","success":true}\n' "$id"
done
"""#)
    await #expect(throws: RPCFailure.invalidResponse) { try await child.request("get_state") }
    await child.shutdown()
}

@Test func drainsStderrWithoutBlockingResponse() async throws {
    let child = try fake(readCommand + #"""
    /usr/bin/awk 'BEGIN { for (i=0;i<10000;i++) print "diagnostic" }' >&2
    printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$command"
done
"""#)
    do { _ = try await child.request("get_state", timeout: 5) }
    catch { await child.shutdown(); throw error }
    await child.shutdown()
}

@Test func eventOverflowDoesNotStopDrainingStdout() async throws {
    let child = try fake(readCommand + #"""
    printf '{"type":"agent_start"}\n{"type":"agent_end"}\n'
    printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$command"
done
"""#, eventCapacity: 1)
    do {
        _ = try await child.request("get_state")
        await #expect(throws: RPCFailure.eventOverflow) {
            for try await _ in child.events {}
        }
        _ = try await child.request("get_state")
    } catch { await child.shutdown(); throw error }
    await child.shutdown()
}

@Test(.timeLimit(.minutes(1))) func resumedEventsUseFreshBuffersAndOriginalCapacity() async throws {
    let child = try fake(readCommand + #"""
    case "$command" in
        overflow) printf '{"type":"first"}\n{"type":"second"}\n{"type":"lost"}\n' ;;
        later) printf '{"type":"later"}\n' ;;
    esac
    printf '{"id":"%s","type":"response","command":"%s","success":true,"data":"%s"}\n' "$id" "$command" "$command"
done
"""#, eventCapacity: 2)
    do {
        _ = try await child.request("overflow")
        var initial = child.events.makeAsyncIterator()
        #expect(try await initial.next()?["type"]?.string == "first")
        #expect(try await initial.next()?["type"]?.string == "second")
        await #expect(throws: RPCFailure.eventOverflow) { try await initial.next() }
        let resumed = try child.resumeEvents()
        #expect(try await child.request("later") == .string("later"))
        var iterator = resumed.makeAsyncIterator()
        #expect(try await iterator.next()?["type"]?.string == "later")
        // The replacement has the original capacity, not a larger recovery buffer.
        _ = try await child.request("overflow")
        #expect(try await iterator.next()?["type"]?.string == "first")
        #expect(try await iterator.next()?["type"]?.string == "second")
        await #expect(throws: RPCFailure.eventOverflow) { try await iterator.next() }
        var final = try child.resumeEvents().makeAsyncIterator()
        async let first = child.request("later")
        async let second = child.request("get_state")
        let results = try await (first, second)
        #expect(results.0 == .string("later"))
        #expect(results.1 == .string("get_state"))
        #expect(try await final.next()?["type"]?.string == "later")
        #expect(await child.shutdown())
        #expect(try await final.next() == nil)
        #expect(throws: RPCFailure.closed) { try child.resumeEvents() }
    } catch { await child.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func replacingActiveSubscriptionFinishesOnlyOldStream() async throws {
    let child = try fake(readCommand + #"""
    printf '{"type":"later"}\n'
    printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$command"
done
"""#)
    do {
        let replacement = try child.resumeEvents()
        var original = child.events.makeAsyncIterator()
        await #expect(throws: RPCFailure.eventOverflow) { try await original.next() }
        var iterator = replacement.makeAsyncIterator()
        _ = try await child.request("get_state")
        #expect(try await iterator.next()?["type"]?.string == "later")
    } catch { await child.shutdown(); throw error }
    await child.shutdown()
}

@Test(.timeLimit(.minutes(1))) func resubscriptionRacesWithDeliveryAndOtherSubscribers() async throws {
    let child = try fake(readCommand + #"""
    printf '{"type":"first"}\n{"type":"second"}\n'
    printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$command"
done
"""#, eventCapacity: 1)
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try child.resumeEvents()
                    _ = try await child.request("get_state")
                    _ = try child.resumeEvents()
                }
            }
            try await group.waitForAll()
        }
        // A late finish from an old subscription must not terminate this one.
        var iterator = try child.resumeEvents().makeAsyncIterator()
        _ = try await child.request("get_state")
        #expect(try await iterator.next()?["type"]?.string == "first")
        await #expect(throws: RPCFailure.eventOverflow) { try await iterator.next() }
        #expect(await child.shutdown())
        #expect(throws: RPCFailure.closed) { try child.resumeEvents() }
    } catch { await child.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func resubscriptionRejectsStoppingAndExitedChildren() async throws {
    let child = try fake(shutdownFixtureScript(), executable: "/bin/bash")
    let shutdown = Task { await child.shutdown() }
    var rejected = false
    for _ in 0..<100 {
        do { _ = try child.resumeEvents() }
        catch RPCFailure.closed { rejected = true; break }
        catch { Issue.record("Unexpected resubscription error: \(error)"); break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(rejected)
    #expect(await shutdown.value)
    #expect(throws: RPCFailure.closed) { try child.resumeEvents() }

    let exited = try fake("exit 0")
    await #expect(throws: RPCFailure.closed) {
        for try await _ in exited.events {}
    }
    #expect(throws: RPCFailure.closed) { try exited.resumeEvents() }
    await exited.shutdown()
}

@Test func missingExecutableFailsAtStartup() {
    #expect(throws: (any Error).self) {
        try RPCProcess(
            executable: URL(fileURLWithPath: "/does-not-exist/pi"),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }
}

@Test func returnsCommandsRejectedByPiWithoutLeakingErrorText() async throws {
    let child = try fake(readCommand + #"""
    printf '{"id":"%s","type":"response","command":"%s","success":false,"error":"private diagnostic"}\n' "$id" "$command"
done
"""#)
    await #expect(throws: RPCFailure.rejected("set_model")) { try await child.request("set_model") }
    await child.shutdown()
}

@Test func providerAuthenticationFailureDoesNotExposeCredentialText() async throws {
    let child = try fake(readCommand + #"""
    printf '{"id":"%s","type":"response","command":"%s","success":false,"error":"No API key found: private diagnostic"}\n' "$id" "$command"
done
"""#)
    await #expect(throws: RPCFailure.providerAuthenticationRequired) { try await child.request("prompt") }
    await child.shutdown()
}

@Test func correlatesReversedResponses() async throws {
    let child = try fake(readCommand + #"""
    if [ -z "$first_id" ]; then
        first_id=$id; first_command=$command
    else
        printf '{"id":"%s","type":"response","command":"%s","success":true,"data":"%s"}\n' "$id" "$command" "$command"
        printf '{"id":"%s","type":"response","command":"%s","success":true,"data":"%s"}\n' "$first_id" "$first_command" "$first_command"
    fi
done
"""#)
    do {
        async let first = child.request("one")
        async let second = child.request("two")
        let values = try await (first, second)
        #expect(values.0 == .string("one"))
        #expect(values.1 == .string("two"))
    } catch { await child.shutdown(); throw error }
    await child.shutdown()
}

@Test func cancellationReportsUnknownOutcome() async throws {
    let child = try fake("while IFS= read -r line; do :; done")
    let request = Task { try await child.request("prompt") }
    try await Task.sleep(for: .milliseconds(20))
    request.cancel()
    await #expect(throws: RPCFailure.unknownOutcome) { try await request.value }
    await child.shutdown()
}

@Test func shutsDownChildThatIgnoresTERM() async throws {
    let child = try fake(shutdownFixtureScript(), executable: "/bin/bash")
    #expect(await child.shutdown())
}

@Test func shutdownIsBoundedWhenStdinIsNotDrained() async throws {
    let child = try fake(shutdownFixtureScript(), executable: "/bin/bash")
    let request = Task {
        try await child.request("prompt", fields: ["message": .string(String(repeating: "x", count: 60_000))])
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await child.shutdown())
    await #expect(throws: RPCFailure.unknownOutcome) { try await request.value }
}

@Test func rejectsReservedCommandFields() async throws {
    let child = try fake("while IFS= read -r line; do :; done")
    await #expect(throws: RPCFailure.invalidCommand) {
        try await child.request("get_state", fields: ["type": .string("bash")])
    }
    await child.shutdown()
}
