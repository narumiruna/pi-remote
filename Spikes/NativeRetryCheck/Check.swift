import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case arguments, assertion(Int), rejected(RemoteFault, Int) }
private func require(_ condition: Bool, line: Int = #line) throws {
    if !condition { throw CheckFailure.assertion(line) }
}
private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func literal(_ text: String) throws -> String { String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }
private func settingsData(_ url: URL) throws -> Data? {
    do { return try Data(contentsOf: url) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
}
private func records(_ url: URL) throws -> [JSONValue] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
}
private func count(_ type: String, in values: [JSONValue]) -> Int {
    values.filter { $0["type"]?.string == type }.count
}
private func waitUntil(line: Int = #line, _ condition: () async throws -> Bool) async throws {
    for _ in 0..<200 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw CheckFailure.assertion(line)
}

/// Test-only provider and isolated installed Pi. No network or real inference is used.
@main struct NativeRetryCheck {
    static func main() async {
        do {
            try await run()
            print("PASS: active retry observed and cancelled; disabled retry stayed disabled; 2 provider attempts, 2 user messages, 0 tokens/cost; settings unchanged; child and fixture removed.")
        } catch {
            if let failure = error as? CheckFailure { print("FAIL: native retry check: \(failure)") }
            else { print("FAIL: native retry check could not complete.") }
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(FileManager.default.isExecutableFile(atPath: pi.path))
        let realAgent = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        let realSettings = realAgent.appendingPathComponent("settings.json")
        let before = try settingsData(realSettings)
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("pi-remote-worker-retry-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent("project"), fixture = agent.appendingPathComponent("extensions/retry.js")
        for directory in [home, project, fixture.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Five seconds permits observation and cancellation before a second attempt.
        try #"{"compaction":{"enabled":false},"retry":{"enabled":false,"maxRetries":2,"baseDelayMs":5000,"maxAgentDelayMs":5000}}"#
            .write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let telemetry = root.appendingPathComponent("events.jsonl")
        let source = """
        import { appendFileSync } from "node:fs";
        import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
        const record = (type, fields = {}) => appendFileSync(\(try literal(telemetry.path)),
            JSON.stringify({ type, ...fields }) + "\\n", { mode: 0o600 });
        export default function (pi) {
            record("loaded", { pid: process.pid });
            pi.registerProvider("native-retry-fixture", {
                api: "native-retry-fixture", apiKey: "fixture-not-a-secret", baseUrl: "http://127.0.0.1:9",
                models: [{ id: "retry", name: "Private retry fixture", reasoning: false, input: ["text"],
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 64 }],
                streamSimple: (model) => {
                    record("attempt");
                    const stream = createAssistantMessageEventStream();
                    const message = { role: "assistant", content: [], api: model.api, provider: model.provider,
                        model: model.id, timestamp: Date.now(), stopReason: "error", errorMessage: "503 overloaded synthetic fixture",
                        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
                            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
                    stream.push({ type: "error", reason: "error", error: message });
                    stream.end();
                    return stream;
                }
            });
            pi.on("message_end", (event) => { if (event.message.role === "user") record("user"); });
            pi.on("agent_settled", () => record("settled"));
            pi.on("session_shutdown", () => record("shutdown"));
        }
        """
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("isolated-pi")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let launcher = """
        #!/bin/sh
        exec /usr/bin/env -i HOME=\(quoted(home.path)) PATH=\(quoted(path)) TMPDIR=\(quoted(root.path)) \\
          PI_CODING_AGENT_DIR=\(quoted(agent.path)) PI_OFFLINE=1 PI_TELEMETRY=0 \\
          \(quoted(pi.path)) --offline --no-mcp --no-context-files --no-tools --no-skills --no-prompt-templates \\
          --no-approve --provider native-retry-fixture --model retry "$@"
        """
        try launcher.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: wrapper)
        do {
            let device = UUID(), directory = try await host.directories.register(project)
            func send(_ action: SessionAction, line: Int = #line) async throws -> AppResult {
                let state = await host.state()
                let result = await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: action), device: device)
                if case .failure(let fault) = result { throw CheckFailure.rejected(fault, line) }
                return result
            }
            func snapshot() async throws -> HostSnapshot {
                guard case .snapshot(let state) = try await send(.snapshot) else { throw CheckFailure.assertion(#line) }
                return state
            }
            func checkCounts(_ expected: Int) async throws {
                let values = try records(telemetry)
                try require(count("attempt", in: values) == expected)
                try require(count("user", in: values) == expected)
                let state = try await snapshot()
                try require(state.messages.filter { $0.role == "user" }.count == expected)
                guard case .statistics(let usage) = try await send(.statistics) else { throw CheckFailure.assertion(#line) }
                try require(usage.tokens.total == 0 && usage.cost == 0)
            }
            _ = try await send(.createSession(directory: directory))
            _ = try await send(.autoRetry(enabled: true))
            try require(try await snapshot().runtime?.acknowledgedAutoRetry == true)
            _ = try await send(.prompt(text: "Synthetic retry cancellation check.", delivery: .prompt, image: nil))
            try await waitUntil { try await snapshot().phase == "retrying" }
            try require(try await snapshot().working)
            try require(count("attempt", in: try records(telemetry)) == 1)
            let cancelledAt = ContinuousClock.now
            _ = try await send(.abortRetry)
            try await waitUntil { try await snapshot().phase == "idle" }
            try require(cancelledAt.duration(to: .now) < .seconds(3))
            // Observe beyond the original delay, not merely until the abort response.
            try await Task.sleep(for: .milliseconds(5500))
            try require(try await snapshot().phase == "idle")
            try await checkCounts(1)
            try require(count("settled", in: try records(telemetry)) == 1)
            _ = try await send(.autoRetry(enabled: false))
            try require(try await snapshot().runtime?.acknowledgedAutoRetry == false)
            _ = try await send(.prompt(text: "Synthetic disabled retry check.", delivery: .prompt, image: nil))
            var settled = false
            for _ in 0..<200 {
                let state = try await snapshot()
                try require(state.phase != "retrying")
                if state.phase == "idle", count("settled", in: try records(telemetry)) == 2 { settled = true; break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try require(settled)
            try await Task.sleep(for: .milliseconds(5500))
            try require(try await snapshot().phase == "idle")
            try await checkCounts(2)
            try require(count("settled", in: try records(telemetry)) == 2)
            await host.shutdown()
            let values = try records(telemetry)
            // Executable version inspection does not load the fixture; exactly one RPC child does.
            try require(count("loaded", in: values) == 1 && count("shutdown", in: values) == 1)
            guard case .number(let rawPID) = values.first(where: { $0["type"]?.string == "loaded" })?["pid"] else {
                throw CheckFailure.assertion(#line)
            }
            let pid = pid_t(rawPID)
            try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
            try require(try settingsData(realSettings) == before)
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path))
        } catch {
            await host.shutdown()
            // shutdown owns and reaps the RPC child; no process-name based termination is used.
            throw error
        }
    }
}
