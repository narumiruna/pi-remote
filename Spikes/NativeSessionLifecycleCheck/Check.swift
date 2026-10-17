import Darwin
import Foundation
import PiRPC
import PiRemoteHost
import PiRemoteCore

private enum CheckFailure: Error { case arguments, assertion(Int) }
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
private func waitUntil(line: Int = #line, _ condition: () throws -> Bool) async throws {
    for _ in 0..<200 {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw CheckFailure.assertion(line)
}
private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

/// Direct upstream Pi core RPC lifecycle checks. The JavaScript extension is a private test fixture only.
@main struct NativeSessionLifecycleCheck {
    static func main() async {
        do {
            try await run()
            try await runHost()
            print("PASS: 2 new_session and 3 switch_session replacements in one PID; new/resume cancellation preserved state; parent metadata without history inheritance; session cwd changed while process cwd stayed fixed; 0 provider calls/runs/replayed user events/tokens/cost; settings unchanged; child and fixture removed.")
        } catch {
            if let failure = error as? CheckFailure { print("FAIL: native session lifecycle check: \(failure)") }
            else if let failure = error as? RPCFailure { print("FAIL: native session lifecycle RPC: \(failure)") }
            else { print("FAIL: native session lifecycle check could not complete.") }
            exit(1)
        }
    }

    private static func runHost() async throws {
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        let realAgent = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        let settings = realAgent.appendingPathComponent("settings.json"), before = try settingsData(realAgent.appendingPathComponent("settings.json"))
        let root = URL(fileURLWithPath: "/tmp/pi-remote-worker-session-lifecycle-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent("project"), other = root.appendingPathComponent("other")
        let fixture = agent.appendingPathComponent("extensions/host.js"), telemetry = root.appendingPathComponent("events.jsonl")
        for folder in [home, project, other, fixture.deletingLastPathComponent()] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try #"{"compaction":{"enabled":false},"retry":{"enabled":false}}"#.write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let source = """
        import { appendFileSync, existsSync, writeFileSync } from "node:fs";
        const suppressForkUI = \(try literal(root.appendingPathComponent("suppress-fork-ui").path));
        const record = (type, data = {}) => appendFileSync(\(try literal(telemetry.path)), JSON.stringify({ type, pid: process.pid, ...data }) + "\\n", { mode: 0o600 });
        export default function (pi) {
            let cancel;
            record("loaded");
            pi.registerProvider("host-lifecycle-fixture", { api: "host-lifecycle-fixture", apiKey: "fixture-not-a-secret", baseUrl: "http://127.0.0.1:9",
                models: [{ id: "metadata", name: "Host lifecycle fixture", reasoning: false, input: ["text"],
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 64 }],
                streamSimple: () => { record("provider"); throw new Error("Fixture provider must not run"); } });
            const ui = (ctx, label) => {
                ctx.ui.setEditorText(label + " draft"); ctx.ui.notify(label + " notify"); ctx.ui.setTitle(label + " title");
                ctx.ui.setStatus("shared", label + " status"); ctx.ui.setWidget("shared", [label + " widget"]);
            };
            pi.on("session_start", (event, ctx) => { pi.setSessionName("Incoming session");
                if (["new", "resume", "fork"].includes(event.reason) && !(event.reason === "fork" && existsSync(suppressForkUI))) ui(ctx, "Incoming " + event.reason); });
            pi.on("session_shutdown", () => record("shutdown"));
            pi.on("session_before_switch", (event, ctx) => { const blocked = event.reason === cancel; cancel = undefined;
                record("before", { reason: event.reason, cancelled: blocked });
                if (blocked) { ui(ctx, "Cancelled hook"); return { cancel: true }; } });
            pi.on("session_before_fork", () => record("before-fork"));
            pi.on("agent_start", () => record("run"));
            pi.on("message_end", (event) => { if (event.message.role === "user") record("user"); });
            pi.registerCommand("host-lifecycle", { description: "Private host lifecycle fixture", handler: async (args, ctx) => {
                if (args === "cancel-new") cancel = "new";
                else if (args === "cancel-resume") cancel = "resume";
                else if (args === "metadata") { ctx.ui.setEditorText("Retained draft"); ctx.ui.setStatus("lifecycle", "Retained status"); }
                else if (args === "suppress-fork-ui") writeFileSync(suppressForkUI, "fixture-only", { mode: 0o600 });
                else if (args === "inspect") record("inspect", { id: ctx.sessionManager.getSessionId(), file: ctx.sessionManager.getSessionFile(),
                    header: ctx.sessionManager.getHeader(), cwd: ctx.cwd, processCwd: process.cwd() });
                else throw new Error("Unknown fixture operation");
            }});
        }
        """
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("isolated-pi"), path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let script = """
        #!/bin/sh
        exec /usr/bin/env -i HOME=\(quoted(home.path)) PATH=\(quoted(path)) TMPDIR=\(quoted(root.path)) PI_CODING_AGENT_DIR=\(quoted(agent.path)) PI_OFFLINE=1 PI_TELEMETRY=0 \\
          \(quoted(pi.path)) --offline --no-mcp --no-context-files --no-tools --no-skills --no-prompt-templates --no-approve --provider host-lifecycle-fixture --model metadata "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: wrapper)
        do {
            let device = UUID(), directory = try await host.directories.register(project), different = try await host.directories.register(other)
            func send(_ action: SessionAction, line: Int = #line) async throws {
                let state = await host.state()
                let result = await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: action), device: device)
                guard result == .ok else { throw CheckFailure.assertion(line) }
            }
            func command(_ operation: String) async throws { try await send(.command(name: "host-lifecycle", arguments: operation)) }
            func inspect(_ cwd: URL) async throws -> JSONValue {
                try await command("inspect")
                let value = try records(telemetry).last(where: { $0["type"]?.string == "inspect" })!
                try require(canonical(value["cwd"]?.string ?? "") == canonical(cwd.path))
                try require(canonical(value["header"]?["cwd"]?.string ?? "") == canonical(cwd.path))
                try require(canonical(value["processCwd"]?.string ?? "") == canonical(cwd.path))
                let state = await host.state()
                try require(state.selected != nil && state.phase == "idle")
                return value
            }
            func expectUI(_ label: String) async throws {
                for _ in 0..<200 {
                    let state = await host.state()
                    if state.draft == label + " draft", [" notify", " title", " status", " widget"].allSatisfy({ state.notices.contains(label + $0) }) { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw CheckFailure.assertion(#line)
            }
            func seed(_ label: String) throws -> Data {
                let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString), "cwd": .string(canonical(project.path)), "timestamp": .string("2026-10-17T00:00:00.000Z")])
                let user: JSONValue = .object(["type": .string("message"), "id": .string("11111111"), "parentId": .null, "timestamp": .string("2026-10-17T00:00:00.000Z"),
                    "message": .object(["role": .string("user"), "content": .string(label), "timestamp": .number(1)])])
                var data = try JSONEncoder().encode(header); data.append(10); data.append(try JSONEncoder().encode(user)); data.append(10)
                return data
            }
            try await send(.createSession(directory: directory))
            let initial = try await inspect(project), original = await host.state().selected!
            try await send(.importSession(data: seed("Saved A")))
            try await expectUI("Incoming resume")
            let savedA = await host.state().selected!
            try require(try await inspect(project)["pid"] == initial["pid"])
            try await send(.importSession(data: seed("Saved B")))
            try await expectUI("Incoming resume")
            let savedB = await host.state().selected!
            let parentInfo = try await inspect(project)
            try require(parentInfo["pid"] == initial["pid"])
            try await send(.autoRetry(enabled: false))
            try await send(.rename(name: "Parent source"))
            try await command("metadata")
            for _ in 0..<200 { if await host.state().draft != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
            for action in [SessionAction.newSession(parent: true), .createSession(directory: directory), .resumeSession(id: savedA), .importSession(data: try seed("Cancelled import"))] {
                switch action { case .newSession, .createSession: try await command("cancel-new"); default: try await command("cancel-resume") }
                let prior = await host.state()
                let catalog = try Data(contentsOf: root.appendingPathComponent("support/sessions.json"))
                let result = await host.handle(AppRequest(epoch: host.epoch, session: prior.selected, action: action), device: device)
                try require(result == .failure(.cancelled))
                try await expectUI("Cancelled hook")
                let after = await host.state()
                try require(after.selected == prior.selected && after.sessions == prior.sessions && after.messages == prior.messages)
                // Explicit standard UI emitted by a cancelling hook belongs to the retained context.
                try require(after.draft == "Cancelled hook draft")
                try require(try Data(contentsOf: root.appendingPathComponent("support/sessions.json")) == catalog)
            }
            let request = AppRequest(epoch: host.epoch, session: savedB, action: .newSession(parent: true))
            try require(await host.handle(request, device: device) == .ok)
            try require(await host.handle(request, device: device) == .ok)
            try await expectUI("Incoming new")
            let childSession = await host.state().selected!, created = try await inspect(project)
            try require(created["pid"] == initial["pid"] && created["id"] != parentInfo["id"])
            try require(created["header"]?["parentSession"] == parentInfo["file"])
            let emptyState = await host.state()
            try require(emptyState.messages.isEmpty && emptyState.draft == "Incoming new draft")
            try require(!emptyState.notices.contains("Retained status"))
            try require(await host.state().runtime?.acknowledgedAutoRetry == false)
            try require(await host.state().sessions.first(where: { $0.id == savedB })?.title == "Parent source")
            try await send(.resumeSession(id: savedA))
            try await expectUI("Incoming resume")
            try require(try await inspect(project)["pid"] == initial["pid"])
            try require(await host.state().messages.filter { $0.role == "user" }.map(\.text) == ["Saved A"])
            try await send(.rename(name: "Branch source"))
            try await send(.clone)
            try await expectUI("Incoming fork")
            let cloned = try await inspect(project)
            try require(cloned["pid"] == initial["pid"])
            try require(await host.state().sessions.first(where: { $0.id == savedA })?.title == "Branch source")
            let branchState = await host.state()
            guard case .sessionTree(let tree) = await host.handle(AppRequest(epoch: host.epoch, session: branchState.selected, action: .sessionTree(cursor: nil)), device: device),
                  let option = tree.items.first(where: { $0.node.canFork }) else { throw CheckFailure.assertion(#line) }
            try await send(.fork(entry: option.id))
            try await expectUI("Incoming fork")
            try require(try await inspect(project)["pid"] == initial["pid"])
            // A real upstream Pi core fork returns the complete imported user text, even beyond the native draft budget.
            try await send(.importSession(data: seed(String(repeating: "x", count: 257 * 1_024))))
            try await expectUI("Incoming resume")
            try await command("suppress-fork-ui")
            let largeSource = await host.state()
            guard case .sessionTree(let largeTree) = await host.handle(AppRequest(epoch: host.epoch, session: largeSource.selected, action: .sessionTree(cursor: nil)), device: device),
                  let largeOption = largeTree.items.first(where: { $0.node.canFork }) else { throw CheckFailure.assertion(#line) }
            let forkCount = try records(telemetry).filter { $0["type"]?.string == "before-fork" }.count
            let largeFork = AppRequest(epoch: host.epoch, session: largeSource.selected, action: .fork(entry: largeOption.id))
            try require(await host.handle(largeFork, device: device) == .ok)
            try require(await host.handle(largeFork, device: device) == .ok)
            let largeResult = await host.state()
            try require(try records(telemetry).filter { $0["type"]?.string == "before-fork" }.count == forkCount + 1)
            try require(largeResult.selected != largeSource.selected && largeResult.sessions.count == largeSource.sessions.count + 1)
            try require(largeResult.draft == nil && largeResult.draftID == nil && largeResult.error == nil)
            try require(largeResult.notices.contains { $0.contains("Fork succeeded") && $0.contains("256 KiB") })
            try require(try AppPacket(AppResult.snapshot(largeResult)).encode().count < 4 * 1_024 * 1_024)
            try require(try await inspect(project)["pid"] == initial["pid"])
            try await send(.createSession(directory: directory))
            let unparented = try await inspect(project)
            try require(unparented["pid"] == initial["pid"] && unparented["header"]?["parentSession"] == nil)
            try await send(.resumeSession(id: childSession))
            let reopened = try await inspect(project)
            try require(reopened["pid"] != initial["pid"] && reopened["id"] == created["id"])
            try require(reopened["header"]?["parentSession"] == created["header"]?["parentSession"])
            try require(await host.state().runtime?.acknowledgedAutoRetry == nil)
            let hooks = try records(telemetry).filter { $0["type"]?.string == "before" }.count
            try await send(.createSession(directory: different))
            let cross = try await inspect(other)
            try require(cross["pid"] != reopened["pid"])
            try require(try records(telemetry).filter { $0["type"]?.string == "before" }.count == hooks)
            try require(await host.state().sessions.contains { $0.id == original })
            guard case .statistics(let usage) = await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: .statistics), device: device) else { throw CheckFailure.assertion(#line) }
            try require(usage.tokens.total == 0 && usage.cost == 0)
            await host.shutdown()
            let values = try records(telemetry), loaded = values.filter { $0["type"]?.string == "loaded" }
            try require(loaded.count == 12 && values.filter { $0["type"]?.string == "shutdown" }.count == 12)
            let pids = Set(loaded.compactMap { value -> Int32? in if case .number(let pid) = value["pid"] { return Int32(pid) }; return nil })
            try require(pids.count == 3)
            for pid in pids { try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH } }
            try require(values.filter { $0["type"]?.string == "before" }.count == 10)
            try require(values.filter { $0["type"]?.string == "before-fork" }.count == 3)
            try require(values.filter { $0["type"]?.string == "before" && $0["cancelled"]?.bool == true }.count == 4)
            try require(values.allSatisfy { !["provider", "run", "user"].contains($0["type"]?.string ?? "") })
            try require(try settingsData(settings) == before)
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path))
            print("PASS: native host same-child new/import/resume/fork/clone, 4 cancelled hooks, incoming/cancelled-hook prefill/status/widget/notify/title preservation, ancestry, oversized imported fork handling, deduplication, empty reopen and cross-directory activation; 3 PIDs fully stopped, 0 inference or prompt replay.")
        } catch { await host.shutdown(); throw error }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(FileManager.default.isExecutableFile(atPath: pi.path))
        let realAgent = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        let realSettings = realAgent.appendingPathComponent("settings.json")
        let before = try settingsData(realSettings)
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("pi-remote-worker-session-lifecycle-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), agent = root.appendingPathComponent("agent")
        let projectA = root.appendingPathComponent("project-a"), projectB = root.appendingPathComponent("project-b")
        let sessions = root.appendingPathComponent("sessions"), fixture = agent.appendingPathComponent("extensions/lifecycle.js")
        for directory in [home, projectA, projectB, sessions, fixture.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try #"{"compaction":{"enabled":false},"retry":{"enabled":false}}"#
            .write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let seedA = sessions.appendingPathComponent("seed-a.jsonl"), seedB = sessions.appendingPathComponent("seed-b.jsonl")
        let idA = UUID().uuidString, idB = UUID().uuidString
        func seed(_ file: URL, id: String, cwd: URL, text: String) throws {
            let date = ISO8601DateFormatter().string(from: Date())
            let values: [JSONValue] = [
                .object(["type": .string("session"), "version": .number(3), "id": .string(id), "timestamp": .string(date), "cwd": .string(canonical(cwd.path))]),
                .object(["type": .string("message"), "id": .string("11111111"), "parentId": .null, "timestamp": .string(date),
                         "message": .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string(text)])]), "timestamp": .number(Date().timeIntervalSince1970 * 1000)])])
            ]
            var bytes = Data()
            for value in values { bytes.append(try JSONEncoder().encode(value)); bytes.append(10) }
            try bytes.write(to: file)
        }
        try seed(seedA, id: idA, cwd: projectA, text: "Seed A; never submit or replay.")
        try seed(seedB, id: idB, cwd: projectB, text: "Seed B; never submit or replay.")
        let seedBytesA = try Data(contentsOf: seedA), seedBytesB = try Data(contentsOf: seedB)
        let telemetry = root.appendingPathComponent("events.jsonl")
        let source = """
        import { appendFileSync } from "node:fs";
        const record = (type, fields = {}) => appendFileSync(\(try literal(telemetry.path)),
            JSON.stringify({ type, pid: process.pid, ...fields }) + "\\n", { mode: 0o600 });
        export default function (pi) {
            let cancelNext;
            record("loaded");
            pi.registerProvider("native-session-fixture", {
                api: "native-session-fixture", apiKey: "fixture-not-a-secret", baseUrl: "http://127.0.0.1:9",
                models: [{ id: "metadata", name: "Private lifecycle fixture", reasoning: false, input: ["text"],
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 64 }],
                streamSimple: () => { record("provider"); throw new Error("Fixture provider must not run"); }
            });
            pi.on("session_start", (event, ctx) => record("start", { reason: event.reason,
                previous: event.previousSessionFile, file: ctx.sessionManager.getSessionFile() }));
            pi.on("session_shutdown", (event) => record("shutdown", { reason: event.reason }));
            pi.on("session_before_switch", (event) => {
                const cancel = cancelNext === event.reason;
                cancelNext = undefined;
                record("before", { reason: event.reason, target: event.targetSessionFile, cancel });
                if (cancel) return { cancel: true };
            });
            pi.on("agent_start", () => record("run"));
            pi.on("message_end", (event) => { if (event.message.role === "user") record("user"); });
            pi.registerCommand("native-lifecycle", {
                description: "Private lifecycle metadata and cancellation check",
                handler: async (args, ctx) => {
                    record("command", { operation: args });
                    if (args === "cancel-new") cancelNext = "new";
                    else if (args === "cancel-resume") cancelNext = "resume";
                    else if (args === "inspect") record("inspect", { file: ctx.sessionManager.getSessionFile(),
                        id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd, sessionCwd: ctx.sessionManager.getCwd(),
                        processCwd: process.cwd(), header: ctx.sessionManager.getHeader() });
                    else throw new Error("Unknown fixture operation");
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
          --no-approve --provider native-session-fixture --model metadata "$@"
        """
        try launcher.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let child = try RPCProcess(executable: wrapper, arguments: ["--mode", "rpc", "--session", seedA.path, "--session-dir", sessions.path], workingDirectory: projectA)
        do {
            func request(_ type: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
                try await child.request(type, fields: fields, timeout: 10)
            }
            func command(_ operation: String) async throws {
                let result = try await request("prompt", ["message": .string("/native-lifecycle " + operation)])
                try require(result["disposition"]?.string == "handled")
            }
            var pid: Double?
            func inspect(cwd: URL, expectedID: String? = nil, expectedFile: URL? = nil, parent: URL? = nil, history: String? = nil) async throws -> JSONValue {
                let count = try records(telemetry).filter { $0["type"]?.string == "inspect" }.count
                try await command("inspect")
                let values = try records(telemetry).filter { $0["type"]?.string == "inspect" }
                try require(values.count == count + 1)
                let info = values.last!
                guard case .number(let currentPID) = info["pid"] else { throw CheckFailure.assertion(#line) }
                if let pid { try require(currentPID == pid) } else { pid = currentPID }
                try require(kill(pid_t(currentPID), 0) == 0)
                let state = try await request("get_state")
                try require(state["sessionId"] == info["id"] && state["sessionFile"] == info["file"])
                try require(state["isStreaming"]?.bool == false && state["isCompacting"]?.bool == false && state["pendingMessageCount"] == .number(0))
                if let expectedID { try require(state["sessionId"]?.string == expectedID) }
                if let expectedFile { try require(canonical(state["sessionFile"]?.string ?? "") == canonical(expectedFile.path)) }
                try require(canonical(info["cwd"]?.string ?? "") == canonical(cwd.path))
                try require(canonical(info["sessionCwd"]?.string ?? "") == canonical(cwd.path))
                try require(canonical(info["header"]?["cwd"]?.string ?? "") == canonical(cwd.path))
                try require(canonical(info["processCwd"]?.string ?? "") == canonical(projectA.path))
                try require(info["header"]?["id"] == info["id"])
                if let parent { try require(info["header"]?["parentSession"]?.string == parent.path) }
                else { try require(info["header"]?["parentSession"] == nil) }
                let messages = try await request("get_messages")["messages"]?.array ?? []
                if let history {
                    try require(messages.count == 1 && messages[0]["role"]?.string == "user")
                    try require(messages[0]["content"]?.array?.first?["text"]?.string == history)
                } else { try require(messages.isEmpty) }
                let stats = try await request("get_session_stats")
                try require(stats["tokens"]?["total"] == .number(0) && stats["cost"] == .number(0))
                return info
            }
            _ = try await inspect(cwd: projectA, expectedID: idA, expectedFile: seedA, history: "Seed A; never submit or replay.")
            try require(try await request("new_session", ["parentSession": .string(seedA.path)])["cancelled"]?.bool == false)
            let fresh = try await inspect(cwd: projectA, parent: seedA)
            try require(fresh["id"]?.string != idA)
            let freshFile = fresh["file"]?.string ?? ""
            try require(canonical(freshFile).hasPrefix(canonical(sessions.path) + "/"))
            // Header and path exist in memory; metadata-only sessions are deliberately not persisted.
            try require(!FileManager.default.fileExists(atPath: freshFile))
            try await command("cancel-new")
            try require(try await request("new_session")["cancelled"]?.bool == true)
            let cancelledNew = try await inspect(cwd: projectA, parent: seedA)
            try require(cancelledNew["id"] == fresh["id"] && cancelledNew["file"] == fresh["file"])
            try await command("cancel-resume")
            try require(try await request("switch_session", ["sessionPath": .string(seedB.path)])["cancelled"]?.bool == true)
            let cancelledResume = try await inspect(cwd: projectA, parent: seedA)
            try require(cancelledResume["id"] == fresh["id"] && cancelledResume["file"] == fresh["file"])
            try require(try await request("switch_session", ["sessionPath": .string(seedA.path)])["cancelled"]?.bool == false)
            _ = try await inspect(cwd: projectA, expectedID: idA, expectedFile: seedA, history: "Seed A; never submit or replay.")
            try require(try await request("switch_session", ["sessionPath": .string(seedB.path)])["cancelled"]?.bool == false)
            _ = try await inspect(cwd: projectB, expectedID: idB, expectedFile: seedB, history: "Seed B; never submit or replay.")
            try require(try await request("new_session")["cancelled"]?.bool == false)
            let unparented = try await inspect(cwd: projectB)
            try require(unparented["id"]?.string != idB && unparented["id"] != fresh["id"])
            try require(!FileManager.default.fileExists(atPath: unparented["file"]?.string ?? ""))
            try require(try await request("switch_session", ["sessionPath": .string(seedA.path)])["cancelled"]?.bool == false)
            _ = try await inspect(cwd: projectA, expectedID: idA, expectedFile: seedA, history: "Seed A; never submit or replay.")
            try require(await child.shutdown())
            guard let pid else { throw CheckFailure.assertion(#line) }
            try await waitUntil { kill(pid_t(pid), 0) == -1 && errno == ESRCH }
            let values = try records(telemetry)
            func matching(_ type: String) -> [JSONValue] { values.filter { $0["type"]?.string == type } }
            print("Lifecycle counts: loaded=\(matching("loaded").count), start=\(matching("start").count), shutdown=\(matching("shutdown").count), before=\(matching("before").count), command=\(matching("command").count), inspect=\(matching("inspect").count).")
            // Pi 1.3.0 rebinds in finishSessionReplacement and again in the RPC command handler.
            // Each successful RPC replacement therefore emits session_start twice, without reloading twice.
            try require(matching("loaded").count == 6 && matching("start").count == 11 && matching("shutdown").count == 6)
            try require(Set(values.compactMap { value -> Double? in if case .number(let number) = value["pid"] { return number }; return nil }) == [pid])
            try require(matching("before").count == 7 && matching("before").filter { $0["cancel"]?.bool == true }.count == 2)
            try require(matching("start").compactMap { $0["reason"]?.string } == ["startup", "new", "new", "resume", "resume", "resume", "resume", "new", "new", "resume", "resume"])
            for index in stride(from: 1, to: 11, by: 2) {
                try require(matching("start")[index]["file"] == matching("start")[index + 1]["file"])
                try require(matching("start")[index]["previous"] == matching("start")[index + 1]["previous"])
            }
            try require(matching("before").compactMap { $0["reason"]?.string } == ["new", "new", "resume", "resume", "resume", "new", "resume"])
            try require(matching("before")[2]["target"]?.string == seedB.path)
            try require(matching("start")[1]["previous"]?.string == seedA.path)
            try require(matching("command").count == 10 && matching("inspect").count == 8)
            try require(matching("provider").isEmpty && matching("run").isEmpty && matching("user").isEmpty)
            for (file, original) in [(seedA, seedBytesA), (seedB, seedBytesB)] {
                let bytes = try Data(contentsOf: file)
                let entries = try records(file)
                print("Seed entry types: \(entries.compactMap { $0["type"]?.string }.joined(separator: ",")).")
                try require(bytes.starts(with: original))
                try require(entries.filter { $0["type"]?.string == "message" }.count == 1)
                try require(entries.dropFirst(2).allSatisfy { ["model_change", "thinking_level_change"].contains($0["type"]?.string ?? "") })
            }
            try require(try settingsData(realSettings) == before)
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path))
        } catch {
            _ = await child.shutdown()
            throw error
        }
    }
}
