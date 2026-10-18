import Foundation
import Testing
import PiRemoteCore
@testable import PiRPC

@Test func explicitIDCannotBeReusedAfterTimeoutOrLateResponse() async throws {
    let child = try RPCProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"""
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
      /bin/sleep 0.1
      printf '{"id":"%s","type":"response","command":"bash","success":true,"data":{"id":"%s"}}\n' "$id" "$id"
    done
    """#], workingDirectory: FileManager.default.temporaryDirectory)
    do {
        await #expect(throws: RPCFailure.unknownOutcome) { try await child.request("bash", timeout: 0.02, id: "first") }
        await #expect(throws: RPCFailure.invalidCommand) { try await child.request("bash", id: "first") }
        let second = try await child.request("bash", id: "second")
        #expect(second["id"]?.string == "second")
        await #expect(throws: RPCFailure.invalidCommand) { try await child.request("bash", id: "first") }
        await child.shutdown()
    } catch { await child.shutdown(); throw error }
}
