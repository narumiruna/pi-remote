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
private func waitUntil(line: Int = #line, _ condition: () async throws -> Bool) async throws {
    for _ in 0..<200 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw CheckFailure.assertion(line)
}

/// Exercises standard installed-Pi UI/state events with a private test-only extension.
@main struct NativeUIStateCheck {
    static func main() async {
        do {
            try await run()
            print("PASS: normalized name and name clearing, thinking event, independent status/widget replacement and clearing, notify/title notices, Stop-cancelled dialog; 10 commands, 0 user messages/provider calls/tokens/cost; settings unchanged; child and fixture removed.")
        } catch {
            if let failure = error as? CheckFailure { print("FAIL: native UI/state check: \(failure)") }
            else { print("FAIL: native UI/state check could not complete.") }
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
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("pi-remote-worker-ui-state-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent("project"), fixture = agent.appendingPathComponent("extensions/ui-state.js")
        for directory in [home, project, fixture.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try #"{"defaultThinkingLevel":"off","compaction":{"enabled":false},"retry":{"enabled":false}}"#
            .write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let telemetry = root.appendingPathComponent("events.jsonl")
        let source = """
        import { appendFileSync } from "node:fs";
        const record = (type, fields = {}) => appendFileSync(\(try literal(telemetry.path)),
            JSON.stringify({ type, ...fields }) + "\\n", { mode: 0o600 });
        export default function (pi) {
            record("loaded", { pid: process.pid });
            pi.registerProvider("native-ui-state-fixture", {
                api: "native-ui-state-fixture", apiKey: "fixture-not-a-secret", baseUrl: "http://127.0.0.1:9",
                models: [{ id: "state", name: "Private UI/state fixture", reasoning: true, input: ["text"],
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 64 }],
                streamSimple: () => { record("provider"); throw new Error("Fixture provider must not run"); }
            });
            pi.on("message_end", (event) => { if (event.message.role === "user") record("user"); });
            pi.on("session_info_changed", (event) => record("name", { name: event.name, cleared: event.name === undefined }));
            pi.on("thinking_level_select", (event) => record("thinking", { level: event.level }));
            pi.on("session_shutdown", () => record("shutdown"));
            pi.registerCommand("native-ui-state", {
                description: "Private generic UI/state verification",
                handler: async (args, ctx) => {
                    record("command", { operation: args });
                    switch (args) {
                        case "notices": ctx.ui.notify("Fixture notification", "warning"); ctx.ui.setTitle("Fixture title"); break;
                        case "both": ctx.ui.setStatus("shared-key", "Status one"); ctx.ui.setWidget("shared-key", ["Widget one", "Second line"]); break;
                        case "status-replace": ctx.ui.setStatus("shared-key", "Status two"); break;
                        case "status-clear": ctx.ui.setStatus("shared-key", undefined); break;
                        case "status-restore": ctx.ui.setStatus("shared-key", "Status three"); break;
                        case "widget-replace": ctx.ui.setWidget("shared-key", ["Widget two"]); break;
                        case "widget-clear": ctx.ui.setWidget("shared-key", undefined); break;
                        case "state": pi.setSessionName(""); pi.setThinkingLevel("high"); break;
                        case "dialog": {
                            // Stop must resolve this before the finite timeout, with no submitted text.
                            const value = await ctx.ui.input("Fixture cancellation", "No text is required", { timeout: 15000 });
                            record("dialog-result", { cancelled: value === undefined });
                            break;
                        }
                        default: throw new Error("Unknown fixture operation");
                    }
                }
            });
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
          --no-approve --provider native-ui-state-fixture --model state "$@"
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
            func command(_ operation: String) async throws {
                _ = try await send(.command(name: "native-ui-state", arguments: operation))
            }
            func expectNotices(_ values: [String], line: Int = #line) async throws {
                try await waitUntil(line: line) {
                    let notices = try await snapshot().notices
                    return notices.count == values.count && Set(notices) == Set(values)
                }
            }
            _ = try await send(.createSession(directory: directory))
            let initial = try await snapshot()
            try require(initial.commands.filter { $0.name == "native-ui-state" }.count == 1)
            try require(initial.messages.isEmpty && initial.notices.isEmpty && initial.dialogs.isEmpty)
            try require(initial.thinking == "off" && initial.thinkingLevels.contains("high"))
            _ = try await send(.rename(name: "  Native\nUI State  "))
            // RPC trims the request; SessionManager also replaces embedded CR/LF with spaces.
            try require(try await snapshot().sessions.first?.title == "Native UI State")
            let baseline = ["Fixture notification", "Fixture title"]
            try await command("notices"); try await expectNotices(baseline)
            try await command("both"); try await expectNotices(baseline + ["Status one", "Widget one\nSecond line"])
            try await command("status-replace"); try await expectNotices(baseline + ["Status two", "Widget one\nSecond line"])
            try await command("status-clear"); try await expectNotices(baseline + ["Widget one\nSecond line"])
            try await command("status-restore"); try await expectNotices(baseline + ["Status three", "Widget one\nSecond line"])
            try await command("widget-replace"); try await expectNotices(baseline + ["Status three", "Widget two"])
            try await command("widget-clear"); try await expectNotices(baseline + ["Status three"])
            try await command("status-clear"); try await expectNotices(baseline)
            try await command("state")
            // The command path does not refresh configuration. These values must arrive as upstream Pi core events.
            try await waitUntil {
                let state = try await snapshot()
                return state.sessions.first?.title == project.lastPathComponent && state.thinking == "high"
            }
            let state = try await snapshot()
            let dialogTask = Task {
                await host.handle(AppRequest(epoch: host.epoch, session: state.selected,
                    action: .command(name: "native-ui-state", arguments: "dialog")), device: device)
            }
            do {
                try await waitUntil { try await snapshot().dialogs.count == 1 }
                let waiting = try await snapshot()
                try require(waiting.phase == "waiting" && waiting.dialogs[0].method == "input")
                let stoppedAt = ContinuousClock.now
                _ = try await send(.stop)
                try require(await dialogTask.value == .ok)
                try await waitUntil { try await snapshot().dialogs.isEmpty }
                try require(stoppedAt.duration(to: .now) < .seconds(5))
            } catch {
                await host.shutdown()
                _ = await dialogTask.value
                throw error
            }
            let final = try await snapshot()
            try require(final.phase == "idle" && final.messages.isEmpty && final.pendingMessages == 0)
            try require(final.error == nil)
            try await expectNotices(baseline)
            guard case .statistics(let usage) = try await send(.statistics) else { throw CheckFailure.assertion(#line) }
            try require(usage.tokens.total == 0 && usage.cost == 0)
            let values = try records(telemetry)
            func matching(_ type: String) -> [JSONValue] { values.filter { $0["type"]?.string == type } }
            try require(matching("command").count == 10)
            try require(matching("command").compactMap { $0["operation"]?.string } == [
                "notices", "both", "status-replace", "status-clear", "status-restore", "widget-replace", "widget-clear", "status-clear", "state", "dialog"])
            try require(matching("provider").isEmpty && matching("user").isEmpty)
            try require(matching("name").count == 2 && matching("name")[0]["name"]?.string == "Native UI State")
            try require(matching("name")[1]["cleared"]?.bool == true)
            try require(matching("thinking").count == 1 && matching("thinking")[0]["level"]?.string == "high")
            try require(matching("dialog-result").count == 1 && matching("dialog-result")[0]["cancelled"]?.bool == true)
            await host.shutdown()
            let shutdown = try records(telemetry)
            try require(shutdown.filter { $0["type"]?.string == "shutdown" }.count == 1)
            let loaded = shutdown.filter { $0["type"]?.string == "loaded" }
            try require(loaded.count == 1)
            guard case .number(let rawPID) = loaded[0]["pid"] else { throw CheckFailure.assertion(#line) }
            let pid = pid_t(rawPID)
            try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
            try require(try settingsData(realSettings) == before)
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path))
        } catch {
            await host.shutdown()
            throw error
        }
    }
}
