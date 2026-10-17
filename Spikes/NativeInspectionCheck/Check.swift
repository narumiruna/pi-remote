import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case arguments, assertion(Int), rejected(RemoteFault, Int) }
private func require(_ value: Bool, line: Int = #line) throws { if !value { throw CheckFailure.assertion(line) } }
private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func literal(_ text: String) throws -> String { String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }
private func optionalData(_ file: URL) throws -> Data? {
    do { return try Data(contentsOf: file) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
}
private func records(_ file: URL) throws -> [JSONValue] {
    guard let bytes = try optionalData(file) else { return [] }
    return try bytes.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
}
private func jsonl(_ values: [JSONValue]) throws -> Data {
    try values.reduce(into: Data()) { data, value in data.append(try JSONEncoder().encode(value)); data.append(10) }
}

/// Private installed-Pi inspection checks. No user prompt, inference, personal resources or network access.
@main struct NativeInspectionCheck {
    private static let provider = "native-inspection-fixture"
    private static let labelTimestamp = "2024-12-03T14:30:00.125Z"
    private static let abandonedText = "Abandoned branch. " + String(repeating: "Unicode 日本語 preview. ", count: 100)
    private static let whitespace = " \n\t"
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF9sAAAAASUVORK5CYII=")!

    static func main() async {
        do {
            try await run()
            print("PASS: installed-Pi imported multi-branch tree, exact labels/timestamps/leaf, paged inspection and full/image previews; text/whitespace fork eligibility and image-only exclusion; abandoned-message fork, draft/catalog and host restart restoration; 0 prompts/runs/provider calls/tokens/cost; network denied; settings/source unchanged; recorded children and private fixture removed.")
        } catch {
            if let failure = error as? CheckFailure { print("FAIL: native inspection check: \(failure)") }
            else if let failure = error as? RemoteFault { print("FAIL: native inspection check: \(failure)") }
            else { print("FAIL: native inspection check could not complete.") }
            exit(1)
        }
    }

    private struct Fixture {
        var root: URL
        var wrapper: URL
        var source: URL
        var data: Data
        var entries: [JSONValue]
        var telemetry: URL
        var agentSettings: URL
        var initialSettings: Data
    }
    private struct Restored {
        var session: UUID
        var catalog: [SessionInfo]
        var tree: SessionTreeInspection
        var messages: [TranscriptMessage]
    }

    private static func seed(project: URL) throws -> (Data, [JSONValue]) {
        let timestamp = "2024-12-03T14:00:00.000Z"
        var values: [JSONValue] = [.object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString),
                                           "cwd": .string(project.resolvingSymlinksInPath().path), "timestamp": .string(timestamp)])]
        func entry(_ id: String, _ parent: String?, _ type: String, _ fields: [String: JSONValue], time: String = "2024-12-03T14:00:00.000Z") -> JSONValue {
            var result = fields
            result["id"] = .string(id); result["parentId"] = parent.map(JSONValue.string) ?? .null
            result["type"] = .string(type); result["timestamp"] = .string(time)
            return .object(result)
        }
        func user(_ id: String, _ parent: String, _ content: JSONValue) -> JSONValue {
            entry(id, parent, "message", ["message": .object(["role": .string("user"), "content": content, "timestamp": .number(1_733_234_400_000)])])
        }
        values.append(entry("model", nil, "model_change", ["provider": .string(provider), "modelId": .string("metadata")]))
        values.append(entry("thinking", "model", "thinking_level_change", ["thinkingLevel": .string("off")]))
        values.append(user("root", "thinking", .string("Shared root. Never submit or replay.")))
        values.append(entry("answer", "root", "message", ["message": .object([
            "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("Seeded assistant; no inference.")])]),
            "api": .string(provider), "provider": .string(provider), "model": .string("metadata"),
            "usage": .object(["input": .number(0), "output": .number(0), "cacheRead": .number(0), "cacheWrite": .number(0), "totalTokens": .number(0),
                              "cost": .object(["input": .number(0), "output": .number(0), "cacheRead": .number(0), "cacheWrite": .number(0), "total": .number(0)])]),
            "stopReason": .string("stop"), "timestamp": .number(1_733_234_400_000)])]))
        let abandonedBlocks: JSONValue = .array([
            .object(["type": .string("text"), "text": .string("Abandoned branch. ")]),
            .object(["type": .string("text"), "text": .string(String(abandonedText.dropFirst("Abandoned branch. ".count)))])
        ])
        values.append(user("abandoned", "answer", abandonedBlocks))
        values.append(user("whitespace", "answer", .string(whitespace)))
        values.append(user("image-only", "answer", .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())])])))
        values.append(user("empty-text", "answer", .array([.object(["type": .string("text"), "text": .string("")])])))
        for index in 0..<205 { values.append(user("side-\(index)", "answer", .string("Side branch \(index). Never replay."))) }
        values.append(entry("label-old", "answer", "label", ["targetId": .string("root"), "label": .string("Old bookmark")]))
        values.append(entry("label-current", "label-old", "label", ["targetId": .string("root"), "label": .string("Root checkpoint")], time: labelTimestamp))
        values.append(entry("label-side", "label-current", "label", ["targetId": .string("abandoned"), "label": .string("Side checkpoint")], time: "2024-12-03T14:31:00.250Z"))
        values.append(user("active-leaf", "answer", .string("Active branch. Never submit or replay.")))
        return (try jsonl(values), Array(values.dropFirst()))
    }

    private static func makeFixture(pi: URL, root: URL) throws -> Fixture {
        let home = root.appendingPathComponent("home"), agent = root.appendingPathComponent("agent"), project = root.appendingPathComponent("project")
        let fixture = agent.appendingPathComponent("extensions/inspection.js"), telemetry = root.appendingPathComponent("events.jsonl")
        for directory in [home, project, fixture.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let settings = agent.appendingPathComponent("settings.json")
        let settingsBytes = Data(#"{"defaultThinkingLevel":"off","compaction":{"enabled":false},"retry":{"enabled":false}}"#.utf8)
        try settingsBytes.write(to: settings)
        let source = """
        import { appendFileSync } from "node:fs";
        const record = (type, fields = {}) => appendFileSync(\(try literal(telemetry.path)),
            JSON.stringify({ type, pid: process.pid, ...fields }) + "\\n", { mode: 0o600 });
        export default function (pi) {
            record("loaded");
            pi.registerProvider("\(provider)", {
                api: "\(provider)", apiKey: "fixture-not-a-secret", baseUrl: "http://127.0.0.1:9",
                models: [{ id: "metadata", name: "Private inspection fixture", reasoning: false, input: ["text", "image"],
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 64 }],
                streamSimple: () => { record("provider"); throw new Error("Fixture provider must not run"); }
            });
            pi.on("session_start", (_event, ctx) => record("snapshot", {
                session: ctx.sessionManager.getSessionId(), tree: ctx.sessionManager.getTree(), leafId: ctx.sessionManager.getLeafId(),
                entries: ctx.sessionManager.getEntries()
            }));
            pi.on("session_shutdown", () => record("shutdown"));
            pi.on("agent_start", () => record("run"));
            pi.on("input", () => { record("input"); return { action: "handled" }; });
            pi.on("message_end", (event) => { if (event.message.role === "user") record("user"); });
        }
        """
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("isolated-pi")
        let profile = root.appendingPathComponent("deny-network.sb")
        try "(version 1) (allow default) (deny network*)\n".write(to: profile, atomically: true, encoding: .utf8)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let launcher = """
        #!/bin/sh
        exec /usr/bin/sandbox-exec -f \(quoted(profile.path)) /usr/bin/env -i \\
          HOME=\(quoted(home.path)) PATH=\(quoted(path)) TMPDIR=\(quoted(root.path)) \\
          PI_CODING_AGENT_DIR=\(quoted(agent.path)) PI_OFFLINE=1 PI_TELEMETRY=0 \\
          \(quoted(pi.path)) --offline --no-extensions --extension \(quoted(fixture.path)) \\
          --no-mcp --no-context-files --no-tools --no-skills --no-prompt-templates \\
          --no-approve --provider \(provider) --model metadata "$@"
        """
        try launcher.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let (data, entries) = try seed(project: project)
        let input = root.appendingPathComponent("source.jsonl")
        try data.write(to: input)
        _ = try SessionImport(data: data)
        return Fixture(root: root, wrapper: wrapper, source: input, data: data, entries: entries, telemetry: telemetry,
                       agentSettings: settings, initialSettings: settingsBytes)
    }

    private static func send(_ action: SessionAction, to host: HostCoordinator, line: Int = #line) async throws -> AppResult {
        let state = await host.state()
        let value = await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: action), device: UUID())
        if case .failure(let fault) = value { throw CheckFailure.rejected(fault, line) }
        return value
    }
    private static func tree(_ host: HostCoordinator) async throws -> SessionTreeInspection {
        var nodes: [SessionTreeNode] = [], cursor: UUID?, leaf: String?, count = 0
        repeat {
            guard case .sessionTree(let page) = try await send(.sessionTree(cursor: cursor), to: host) else { throw CheckFailure.assertion(#line) }
            try require(page.items.count <= 100)
            if count == 0 { leaf = page.leafID } else { try require(page.leafID == leaf) }
            nodes += page.items.map(\.node); cursor = page.next; count += 1
            try require(count <= 100 && (try AppPacket(AppResult.sessionTree(page)).encode()).count < 1_024 * 1_024)
        } while cursor != nil
        try require(count == max(1, (nodes.count + 99) / 100))
        return SessionTreeInspection(nodes: nodes, leafID: leaf)
    }
    private static func sameMessages(_ lhs: [TranscriptMessage], _ rhs: [TranscriptMessage]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.role == $1.role && $0.text == $1.text && $0.thinking == $1.thinking && $0.isError == $1.isError
        }
    }
    private static func noUsage(_ host: HostCoordinator) async throws {
        guard case .statistics(let usage) = try await send(.statistics, to: host) else { throw CheckFailure.assertion(#line) }
        try usage.validate(); try require(usage.tokens.total == 0 && usage.cost == 0)
    }

    private static func exercise(_ fixture: Fixture) async throws -> Restored {
        let host = try HostCoordinator(support: fixture.root.appendingPathComponent("support"), executable: fixture.wrapper)
        do {
            _ = try await send(.importSession(data: fixture.data), to: host)
            let imported = await host.state()
            guard let importedID = imported.selected else { throw CheckFailure.assertion(#line) }
            try require(imported.piVersion == "1.3.0" && !imported.working && imported.sessions.count == 1)
            let mapped = try await tree(host)
            try require(mapped.nodes.count == fixture.entries.count && mapped.leafID == "active-leaf")
            let byID = Dictionary(uniqueKeysWithValues: mapped.nodes.map { ($0.id, $0) })
            try require(byID["root"]?.label == "Root checkpoint" && byID["root"]?.labelTimestamp == labelTimestamp)
            try require(byID["abandoned"]?.label == "Side checkpoint" && byID["abandoned"]?.parentID == "answer")
            try require(byID["abandoned"]?.canFork == true && byID["abandoned"]?.truncated == true)
            try require(byID["whitespace"]?.canFork == true && byID["whitespace"]?.text == whitespace)
            try require(byID["image-only"]?.canFork == false && byID["empty-text"]?.canFork == false)
            let expectedForks = Set(fixture.entries.compactMap { raw -> String? in
                guard raw["type"]?.string == "message", raw["message"]?["role"]?.string == "user",
                      let id = raw["id"]?.string, !["image-only", "empty-text"].contains(id) else { return nil }
                return id
            })
            try require(Set(mapped.nodes.filter(\.canFork).map(\.id)) == expectedForks)
            let snapshot = try records(fixture.telemetry).last { $0["type"]?.string == "snapshot" && $0["leafId"]?.string == "active-leaf" }
            guard let snapshot else { throw CheckFailure.assertion(#line) }
            let options = expectedForks.sorted().map { id -> SessionForkOption in
                let text = id == "abandoned" ? abandonedText : (id == "whitespace" ? whitespace : byID[id]!.text)
                return SessionForkOption(entryID: id, text: DisplayLimit.text(text, bytes: 512), truncated: text.utf8.count > 512)
            }
            try require(try SessionInspectionMapper.tree(snapshot, forks: options) == mapped)
            guard case .history(let entries) = try await send(.history, to: host) else { throw CheckFailure.assertion(#line) }
            try require(Set(entries.map(\.id)) == Set(mapped.nodes.map(\.id)) && entries.allSatisfy { !$0.canFork })
            var cursor: UUID?, historyIDs = Set<String>(), previews: [String: UUID] = [:]
            repeat {
                guard case .historyPage(let page) = try await send(.historyPage(cursor: cursor), to: host) else { throw CheckFailure.assertion(#line) }
                try require(page.items.count <= 100 && page.items.allSatisfy { !$0.canFork })
                for item in page.items { try require(historyIDs.insert(item.id).inserted); previews[item.id] = item.preview }
                cursor = page.next
            } while cursor != nil
            try require(historyIDs == Set(mapped.nodes.map(\.id)))
            guard let textToken = previews["abandoned"], let imageToken = previews["image-only"],
                  case .preview(let full) = try await send(.historyEntry(id: textToken), to: host),
                  case .preview(let image) = try await send(.historyEntry(id: imageToken), to: host) else { throw CheckFailure.assertion(#line) }
            // Full file previews retain their block separators; fork text uses core's separator-free extraction.
            try require(full.text == "Abandoned branch. \n" + String(abandonedText.dropFirst("Abandoned branch. ".count)) && !full.truncated)
            guard let imageID = image.images?.first?.id else { throw CheckFailure.assertion(#line) }
            guard case .image(let original) = try await send(.outputImage(id: imageID), to: host) else { throw CheckFailure.assertion(#line) }
            try require(original.data == png && original.mimeType == "image/png")
            for id in ["image-only", "empty-text", "missing"] {
                let state = await host.state()
                try require(await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: .fork(entry: id)), device: UUID()) == .failure(.invalidRequest))
            }
            try await noUsage(host)
            guard case .sessionTree(let first) = try await send(.sessionTree(cursor: nil), to: host),
                  let treeText = first.items.first(where: { $0.id == "abandoned" })?.preview,
                  let treeImage = first.items.first(where: { $0.id == "image-only" })?.preview,
                  case .preview(let fullFromTree) = try await send(.historyEntry(id: treeText), to: host),
                  case .preview(let imageFromTree) = try await send(.historyEntry(id: treeImage), to: host) else { throw CheckFailure.assertion(#line) }
            try require(fullFromTree == full && imageFromTree.images?.first?.id == imageID)
            _ = try await send(.fork(entry: "abandoned"), to: host)
            let forked = await host.state()
            guard let forkedID = forked.selected else { throw CheckFailure.assertion(#line) }
            try require(forkedID != importedID && forked.sessions.count == 2 && forked.draft == abandonedText)
            try require(!forked.working && forked.messages.contains { $0.role == "assistant" && $0.text == "Seeded assistant; no inference." })
            try require(forked.messages.allSatisfy { !$0.text.contains("Side branch") && !$0.text.contains("Active branch") && !$0.text.contains("Abandoned branch") })
            let branch = try await tree(host)
            try require(!branch.nodes.contains { ["abandoned", "active-leaf", "whitespace", "image-only"].contains($0.id) })
            try require(branch.nodes.first { $0.id == "root" }?.labelTimestamp == labelTimestamp)
            try require(branch.nodes.first { $0.id == "root" }?.label == "Root checkpoint")
            let stale = await host.handle(AppRequest(epoch: host.epoch, session: forkedID, action: .sessionTree(cursor: first.next)), device: UUID())
            try require(stale == .failure(.expired))
            _ = try await send(.closeSession, to: host)
            _ = try await send(.resumeSession(id: forkedID), to: host)
            let reopened = await host.state()
            try require(reopened.selected == forkedID && reopened.draft == nil && sameMessages(reopened.messages, forked.messages))
            let restoredTree = try await tree(host)
            try require(restoredTree == branch)
            try await noUsage(host)
            let result = Restored(session: forkedID, catalog: reopened.sessions, tree: restoredTree, messages: reopened.messages)
            await host.shutdown()
            return result
        } catch { await host.shutdown(); throw error }
    }

    private static func restore(_ fixture: Fixture, expected: Restored) async throws {
        var candidate: HostCoordinator?
        for _ in 0..<200 {
            do { candidate = try HostCoordinator(support: fixture.root.appendingPathComponent("support"), executable: fixture.wrapper); break }
            catch RemoteFault.conflict { try await Task.sleep(for: .milliseconds(25)) }
        }
        guard let host = candidate else { throw CheckFailure.assertion(#line) }
        do {
            let idle = await host.state()
            try require(idle.selected == nil && idle.sessions == expected.catalog)
            _ = try await send(.resumeSession(id: expected.session), to: host)
            let reopened = await host.state()
            try require(reopened.selected == expected.session && sameMessages(reopened.messages, expected.messages) && reopened.draft == nil)
            try require(try await tree(host) == expected.tree)
            try await noUsage(host)
            await host.shutdown()
        } catch { await host.shutdown(); throw error }
    }

    private static func childrenStopped(_ telemetry: URL) async throws {
        let pids = Set(try records(telemetry).compactMap { value -> pid_t? in
            guard case .number(let pid) = value["pid"], pid > 0, pid <= Double(Int32.max) else { return nil }
            return pid_t(pid)
        })
        try require(!pids.isEmpty)
        for _ in 0..<200 {
            if pids.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailure.assertion(#line)
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(FileManager.default.isExecutableFile(atPath: pi.path) && FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"))
        let realAgent = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        let realSettings = realAgent.appendingPathComponent("settings.json")
        let before = try optionalData(realSettings)
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("pi-remote-worker-inspection-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fixture: Fixture
        do { fixture = try makeFixture(pi: pi, root: root) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        do {
            let expected = try await exercise(fixture)
            try await restore(fixture, expected: expected)
            let events = try records(fixture.telemetry)
            try require(!events.contains { ["provider", "run", "input", "user"].contains($0["type"]?.string ?? "") })
            try require(try Data(contentsOf: fixture.source) == fixture.data)
            try require(try Data(contentsOf: fixture.agentSettings) == fixture.initialSettings)
            try require(try optionalData(realSettings) == before)
            try await childrenStopped(fixture.telemetry)
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path))
        } catch {
            // Host scopes shut down their own child before returning an error. Do not
            // remove the fixture until every recorded child is confirmed stopped.
            try await childrenStopped(fixture.telemetry)
            try require(try optionalData(realSettings) == before)
            try FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
