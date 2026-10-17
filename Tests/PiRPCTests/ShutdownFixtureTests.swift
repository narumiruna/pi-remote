import Darwin
import Foundation
import Testing

/// Ignore stdin and TERM without spinning. Exit independently if the runner dies.
/// The deadline also bounds the fixture if the owner's PID is reused.
func shutdownFixtureScript(lifetime: Int = 15) -> String {
    """
    trap '' TERM
    owner=$PPID
    deadline=$((SECONDS + \(lifetime)))
    if [ -n "$1" ]; then printf '%s\\n' "$$" > "$1"; fi
    while kill -0 "$owner" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
        /bin/sleep 0.05
    done
    """
}

private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@Test func shutdownFixtureExitsAfterOwnerIsKilled() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/bash")
    owner.arguments = ["-c", "/bin/bash -c \"$1\" bounded-rpc-fixture \"$2\" & wait", "fixture-owner",
                       shutdownFixtureScript(), pidFile.path]
    owner.standardInput = FileHandle.nullDevice
    owner.standardOutput = FileHandle.nullDevice
    owner.standardError = FileHandle.nullDevice
    var fixturePID: pid_t?
    defer {
        if owner.isRunning { kill(owner.processIdentifier, SIGKILL) }
        if let fixturePID { kill(fixturePID, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile)
    }
    try owner.run()
    let ready = try await waitUntil {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        fixturePID = pid
        return true
    }
    #expect(ready)
    let pid = try #require(fixturePID)
    #expect(kill(pid, 0) == 0)
    // SIGKILL bypasses all owner cleanup, as a test runner crash can do.
    #expect(kill(owner.processIdentifier, SIGKILL) == 0)
    let exited = try await waitUntil { kill(pid, 0) != 0 && errno == ESRCH }
    #expect(exited)
    if exited { fixturePID = nil }
    #expect(try await waitUntil { !owner.isRunning })
}

@Test func shutdownFixtureExpiresWhileOwnerIsAlive() async throws {
    let fixture = Process()
    fixture.executableURL = URL(fileURLWithPath: "/bin/bash")
    fixture.arguments = ["-c", shutdownFixtureScript(lifetime: 2)]
    fixture.standardInput = FileHandle.nullDevice
    fixture.standardOutput = FileHandle.nullDevice
    fixture.standardError = FileHandle.nullDevice
    defer { if fixture.isRunning { kill(fixture.processIdentifier, SIGKILL) } }
    try fixture.run()
    #expect(try await waitUntil { !fixture.isRunning })
    #expect(fixture.terminationStatus == 0)
}
