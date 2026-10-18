import Foundation
import Testing
import PiRemoteCore
@testable import PiRPC

@Test func bashExplicitIDCorrelatesStreamAndRejectsPendingCollision() async throws {
    let child = try RPCProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"""
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
      command=$(printf '%s' "$line" | /usr/bin/plutil -extract type raw -o - -)
      case "$command" in
        bash) bashid=$id; printf '{"type":"bash_execution_update","id":"%s","delta":"fixture"}\n' "$id" ;;
        abort_bash)
          printf '{"id":"%s","type":"response","command":"bash","success":true,"data":{"output":"fixture"}}\n' "$bashid"
          printf '{"id":"%s","type":"response","command":"abort_bash","success":true}\n' "$id" ;;
      esac
    done
    """#], workingDirectory: FileManager.default.temporaryDirectory)
    do {
        let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pending = Task { try await child.request("bash", id: "shell-id", onEnqueued: { ready.continuation.yield(()) }) }
        for await _ in ready.stream { break }
        ready.continuation.finish()
        var events = child.events.makeAsyncIterator()
        let event = try await events.next()
        #expect(event?["id"]?.string == "shell-id")
        await #expect(throws: RPCFailure.invalidCommand) { try await child.request("bash", id: "shell-id") }
        _ = try await child.request("abort_bash")
        #expect(try await pending.value["output"]?.string == "fixture")
        await #expect(throws: RPCFailure.invalidCommand) { try await child.request("bash", id: "shell-id") }
        await #expect(throws: RPCFailure.invalidCommand) { try await child.request("bash", fields: ["id": .string("override")]) }
        await #expect(throws: RPCFailure.invalidCommand) { try await child.request("bash", fields: ["type": .string("override")]) }
        await child.shutdown()
    } catch { await child.shutdown(); throw error }
}
