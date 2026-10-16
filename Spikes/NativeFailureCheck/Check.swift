import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case arguments, assertion(Int) }
private func require(_ condition: Bool, line: Int = #line) throws {
    if !condition { throw CheckFailure.assertion(line) }
}
private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Uses an empty home, agent directory and environment. No real credentials are read.
@main struct NativeFailureCheck {
    static func main() async {
        do { try await run(); print("PASS: installed Pi missing-credential rejection, deduplication and empty-session restoration.") }
        catch {
            if let failure = error as? CheckFailure { print("FAIL: \(failure)") }
            else { print("FAIL: isolated missing-credential check could not complete.") }
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-remote-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("isolated-pi")
        let path = [pi.deletingLastPathComponent().path, ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let script = """
        #!/bin/sh
        exec /usr/bin/env -i HOME=\(quoted(root.path)) PATH=\(quoted(path)) TMPDIR=\(quoted(root.path)) PI_CODING_AGENT_DIR=\(quoted(root.appendingPathComponent("agent").path)) PI_TELEMETRY=0 \(quoted(pi.path)) --offline --no-extensions --no-mcp --no-skills --no-prompt-templates --no-context-files --no-tools --provider openai --model gpt-4o "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: wrapper)
        do {
            let directory = try await host.directories.register(root)
            let device = UUID()
            try require(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
            let state = await host.state()
            let selected = try state.selected.unwrap()
            let prompt = AppRequest(epoch: host.epoch, session: selected, action: .prompt(text: "Credential isolation fixture. Reply OK.", delivery: .prompt, image: nil))
            try require(await host.handle(prompt, device: device) == .failure(.providerAuthenticationRequired))
            try require(await host.handle(prompt, device: device) == .failure(.providerAuthenticationRequired))
            let rejected = await host.state()
            try require(rejected.phase == "idle" && rejected.sessions.first?.interrupted == false)
            try require(rejected.messages.isEmpty)
            try require(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .resumeSession(id: selected)), device: device) == .ok)
            try require(await host.state().messages.isEmpty)
            await host.shutdown()
        } catch { await host.shutdown(); throw error }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CheckFailure.assertion(#line) }
        return value
    }
}
