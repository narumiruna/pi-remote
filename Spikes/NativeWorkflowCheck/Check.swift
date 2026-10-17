import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case assertion(Int), arguments, rejected(RemoteFault, Int) }
private func require(_ condition: Bool, line: Int = #line) throws { if !condition { throw CheckFailure.assertion(line) } }
private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Real Pi metadata and supported extension dialogs only: no inference prompt or provider request.
@main struct NativeWorkflowCheck {
    static func main() async {
        do { try await run(); print("PASS: native host directory, model, thinking, dialogs, Stop, legacy import, HTML/JSONL export and restoration checks.") }
        catch {
            if let failure = error as? CheckFailure { print("FAIL: \(failure)") }
            else { print("FAIL: native workflow check could not complete.") }
            exit(1)
        }
    }
    private static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        let demo = URL(fileURLWithPath: CommandLine.arguments[2])
        try require(FileManager.default.isExecutableFile(atPath: pi.path) && FileManager.default.fileExists(atPath: demo.path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-remote-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let globalSettings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")
        let settingsBefore = try? Data(contentsOf: globalSettings)
        let folder = root.appendingPathComponent("project/nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wrapper = root.appendingPathComponent("isolated-pi")
        let cwd = root.appendingPathComponent("observed-cwd")
        let dialogs = root.appendingPathComponent("dialogs.js")
        let extensionSource = """
        export default function (pi) {
            pi.registerCommand("fixture-select", { handler: async (_args, ctx) => {
                const result = await ctx.ui.select("Fixture selection", ["First", "Second"]);
                ctx.ui.notify(result === "Second" ? "Selection verified" : "Selection cancelled", "info");
            }});
            pi.registerCommand("fixture-confirm", { handler: async (_args, ctx) => {
                const result = await ctx.ui.confirm("Fixture confirmation", "Confirm fixture");
                ctx.ui.notify(result ? "Confirmation verified" : "Confirmation cancelled", "info");
            }});
            pi.registerCommand("fixture-expire", { handler: async (_args, ctx) => {
                await ctx.ui.input("Fixture expiry", "", { timeout: 150 });
            }});
        }
        """
        try extensionSource.write(to: dialogs, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        export PI_CODING_AGENT_DIR=\(quoted(root.appendingPathComponent("agent").path))
        export PI_OFFLINE=1
        export PI_TELEMETRY=0
        export OPENAI_API_KEY=pi-remote-fixture-not-a-real-key
        if [ "${1:-}" != --version ]; then /bin/pwd > \(quoted(cwd.path)); fi
        exec \(quoted(pi.path)) --offline --no-extensions --no-mcp --no-skills --no-prompt-templates --no-context-files --no-tools --extension \(quoted(demo.path)) --extension \(quoted(dialogs.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: wrapper)
        do {
            let directory = try await host.directories.register(folder)
            let device = UUID()
            func send(_ action: SessionAction, line: Int = #line) async throws -> AppResult {
                let state = await host.state()
                let result = await host.handle(AppRequest(epoch: state.epoch, session: state.selected, action: action), device: device)
                if case .failure(let fault) = result { throw CheckFailure.rejected(fault, line) }
                return result
            }
            _ = try await send(.createSession(directory: directory))
            let initial = await host.state()
            let selected = initial.selected
            try require(selected != nil && initial.sessions.first?.directory == folder.resolvingSymlinksInPath().path)
            guard case .statistics(let usage) = try await send(.statistics) else { throw CheckFailure.assertion(#line) }
            try usage.validate()
            try require(usage.userMessages == 0 && usage.tokens.total == 0 && usage.cost == 0)
            guard case .preview(let emptyText) = try await send(.lastAssistant) else { throw CheckFailure.assertion(#line) }
            try require(emptyText.text.isEmpty && !emptyText.truncated)
            guard let originalRuntime = initial.runtime else { throw CheckFailure.assertion(#line) }
            let steering: QueueMode = originalRuntime.steeringMode == .all ? .oneAtATime : .all
            let followUp: QueueMode = originalRuntime.followUpMode == .all ? .oneAtATime : .all
            _ = try await send(.queueMode(kind: .steering, mode: steering))
            _ = try await send(.queueMode(kind: .followUp, mode: followUp))
            _ = try await send(.autoCompaction(enabled: !originalRuntime.autoCompactionEnabled))
            guard case .runtimeSettings(let changed) = try await send(.runtimeSettings) else { throw CheckFailure.assertion(#line) }
            try require(changed == RuntimeSettings(steeringMode: steering, followUpMode: followUp, autoCompactionEnabled: !originalRuntime.autoCompactionEnabled))
            _ = try await send(.queueMode(kind: .steering, mode: originalRuntime.steeringMode))
            _ = try await send(.queueMode(kind: .followUp, mode: originalRuntime.followUpMode))
            _ = try await send(.autoCompaction(enabled: originalRuntime.autoCompactionEnabled))
            try require(try DirectoryRegistry.identify(URL(fileURLWithPath: String(contentsOf: cwd, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))) == DirectoryRegistry.identify(folder))
            guard let model = initial.models.first(where: { $0.provider == "openai" && $0.model.hasPrefix("gpt-5") }) ?? initial.models.first(where: { $0.provider == "openai" }) else { throw CheckFailure.assertion(#line) }
            _ = try await send(.model(provider: model.provider, id: model.model))
            let configured = await host.state()
            guard let level = configured.thinkingLevels.last else { throw CheckFailure.assertion(#line) }
            _ = try await send(.thinking(level: level))
            try require(await host.state().thinking == level)
            _ = try await send(.rename(name: "Native workflow fixture"))
            try require(await host.state().sessions.first?.title == "Native workflow fixture")
            for (name, method) in [("rpc-input", "input"), ("rpc-editor", "editor"), ("fixture-select", "select"), ("fixture-confirm", "confirm")] {
                try require(await host.state().commands.contains { $0.name == name })
                let command = Task { try await send(.command(name: name, arguments: "")) }
                var dialog: ExtensionDialog?
                for _ in 0..<200 {
                    dialog = await host.state().dialogs.first
                    if dialog != nil { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard let dialog, dialog.method == method else { throw CheckFailure.assertion(#line) }
                if method == "select" { try require(dialog.options == ["First", "Second"]) }
                _ = try await send(.answer(dialog: dialog.id, value: method == "select" ? "Second" : "Fixture response", confirmed: method == "confirm" ? true : nil, cancelled: false))
                _ = try await command.value
            }
            try require(await host.state().notices.contains("Selection verified"))
            try require(await host.state().notices.contains("Confirmation verified"))
            let expiringCommand = Task { try await send(.command(name: "fixture-expire", arguments: "")) }
            var expiringDialog: ExtensionDialog?
            for _ in 0..<200 {
                expiringDialog = await host.state().dialogs.first
                if expiringDialog != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let expiringDialog, expiringDialog.expires != nil else { throw CheckFailure.assertion(#line) }
            _ = try await expiringCommand.value
            try await Task.sleep(for: .milliseconds(200))
            let expiredState = await host.state()
            try require(expiredState.dialogs.isEmpty && expiredState.phase == "idle")
            let expiredResult = await host.handle(AppRequest(epoch: host.epoch, session: expiredState.selected,
                action: .answer(dialog: expiringDialog.id, value: "Late", confirmed: nil, cancelled: false)), device: device)
            try require(expiredResult == .failure(.expired))
            _ = try await send(.command(name: "rpc-prefill", arguments: ""))
            for _ in 0..<100 {
                if await host.state().draftID != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try require(await host.state().draft == "This text was set by the rpc-demo extension.")
            _ = try await send(.stop)
            try require(await host.state().phase == "idle")
            _ = try await send(.createSession(directory: directory))
            let blank = await host.state()
            try require(blank.draft == nil && blank.draftID == nil)
            _ = try await send(.resumeSession(id: selected!))
            try require(await host.state().selected == selected)
            try require(try DirectoryRegistry.identify(URL(fileURLWithPath: String(contentsOf: cwd, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))) == DirectoryRegistry.identify(folder))
            if case .historyPage(let page) = try await send(.historyPage(cursor: nil)) { try require(page.items.isEmpty) }
            else { throw CheckFailure.assertion(#line) }
            let catalog = await host.state().sessions
            _ = try await send(.closeSession)
            let closed = await host.state()
            try require(closed.selected == nil && closed.messages.isEmpty)
            try require(await host.state().sessions == catalog)
            // Import a private synthetic source through the actual host action. No inference.
            let piID = UUID().uuidString
            let file = root.appendingPathComponent("import-source.jsonl")
            let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(piID), "cwd": .string(folder.path), "timestamp": .string("2026-10-17T00:00:00.000Z")])
            let entry: JSONValue = .object(["type": .string("message"), "id": .string("fixture-user"), "parentId": .null,
                "timestamp": .string("2026-10-17T00:00:00.000Z"), "message": .object(["role": .string("user"), "content": .string("Private export fixture"), "timestamp": .number(1_792_195_200_000)])])
            var seeded = try JSONEncoder().encode(header); seeded.append(10)
            seeded.append(try JSONEncoder().encode(entry)); seeded.append(10)
            try seeded.write(to: file)
            _ = try await send(.importSession(data: seeded))
            let importedState = await host.state()
            guard let importedID = importedState.selected else { throw CheckFailure.assertion(#line) }
            try require(importedID != selected && importedState.sessions.count == catalog.count + 1)
            try require(importedState.messages.contains { $0.role == "user" && $0.text == "Private export fixture" })
            try require(importedState.sessions.first(where: { $0.id == importedID })?.interrupted == true)
            try require(try Data(contentsOf: file) == seeded)
            _ = try await send(.closeSession)
            _ = try await send(.resumeSession(id: importedID))
            try require(await host.state().messages.contains { $0.role == "user" && $0.text == "Private export fixture" })
            try require(await host.state().runtime == originalRuntime)
            let storedImport = root.appendingPathComponent("support/pi-sessions/" + importedID.uuidString + "/imported.jsonl")
            let savedHistory = try Data(contentsOf: storedImport)
            let originalRecords = try seeded.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            let savedRecords = try savedHistory.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            try require(originalRecords.allSatisfy { savedRecords.contains($0) })
            guard case .exportSession(let jsonl) = try await send(.exportJSONL) else { throw CheckFailure.assertion(#line) }
            try jsonl.validate()
            let branchRecords = try jsonl.data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            try require(jsonl.format == .jsonl && branchRecords.first?["id"]?.string == piID)
            try require(originalRecords.dropFirst().allSatisfy { branchRecords.contains($0) })
            try require(try Data(contentsOf: file) == seeded)
            guard case .exportSession(let exported) = try await send(.exportSession) else { throw CheckFailure.assertion(#line) }
            try exported.validate()
            let html = String(decoding: exported.data, as: UTF8.self)
            let prefix = "<script id=\"session-data\" type=\"application/json\">"
            guard let start = html.range(of: prefix)?.upperBound,
                  let end = html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound,
                  let data = Data(base64Encoded: String(html[start..<end])) else { throw CheckFailure.assertion(#line) }
            try require(html.lowercased().contains("<!doctype html>"))
            try require(String(decoding: data, as: UTF8.self).contains("Private export fixture"))
            try require(try AppPacket(AppResult.exportSession(exported)).encode().count < 4 * 1_024 * 1_024)
            try require(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("support").path).allSatisfy { !$0.hasPrefix("export-") })
            for version in [1, 2] {
                let timestamp = "2026-10-17T00:00:00.000Z"
                let legacyHeader: JSONValue = .object(["type": .string("session"), "version": .number(Double(version)),
                    "id": .string(UUID().uuidString), "cwd": .string(folder.path), "timestamp": .string(timestamp)])
                var user: [String: JSONValue] = ["type": .string("message"), "timestamp": .string(timestamp),
                    "message": .object(["role": .string("user"), "content": .string("Legacy import fixture \(version)"), "timestamp": .number(1_792_195_200_000)])]
                var hook: [String: JSONValue] = ["type": .string("message"), "timestamp": .string(timestamp),
                    "message": .object(["role": .string("hookMessage"), "customType": .string("legacy-fixture"), "display": .bool(true),
                        "content": .string("Legacy hook fixture \(version)"), "timestamp": .number(1_792_195_200_000)])]
                var compact: [String: JSONValue] = ["type": .string("compaction"), "timestamp": .string(timestamp),
                    "summary": .string("Legacy fixture summary"), "tokensBefore": .number(0)]
                if version == 1 { compact["firstKeptEntryIndex"] = .number(1) }
                else {
                    user["id"] = .string("legacy-user"); user["parentId"] = .null
                    hook["id"] = .string("legacy-hook"); hook["parentId"] = .string("legacy-user")
                    compact["id"] = .string("legacy-compact"); compact["parentId"] = .string("legacy-hook")
                    compact["firstKeptEntryId"] = .string("legacy-user")
                }
                let source = try [legacyHeader, .object(user), .object(hook), .object(compact)].reduce(into: Data()) { bytes, value in
                    bytes.append(try JSONEncoder().encode(value)); bytes.append(10)
                }
                let sourceFile = root.appendingPathComponent("legacy-\(version).jsonl")
                try source.write(to: sourceFile)
                try require(try SessionImport(data: source).version == version)
                _ = try await send(.importSession(data: source))
                let migrated = await host.state()
                try require(!migrated.working)
                try require(migrated.messages.contains { $0.role == "user" && $0.text == "Legacy import fixture \(version)" })
                try require(migrated.messages.contains { $0.role == "custom" && $0.text == "Legacy hook fixture \(version)" })
                guard case .exportSession(let archive) = try await send(.exportJSONL) else { throw CheckFailure.assertion(#line) }
                try require(try SessionImport(data: archive.data).version == 3)
                try require(try Data(contentsOf: sourceFile) == source)
            }
            let emptyHeader: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString),
                "cwd": .string(folder.path), "timestamp": .string("2026-10-17T00:00:00.000Z")])
            _ = try await send(.importSession(data: JSONEncoder().encode(emptyHeader)))
            let emptyImported = await host.state()
            try require(emptyImported.messages.isEmpty && !emptyImported.working)
            let chosenFolder = root.appendingPathComponent("project/chosen-import")
            try FileManager.default.createDirectory(at: chosenFolder, withIntermediateDirectories: false)
            let sourceHeader: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString),
                "timestamp": .string("2026-10-17T00:00:00.000Z")])
            let originalPathText = "Keep " + folder.path + "/source.swift"
            let sourceEntry: JSONValue = .object(["type": .string("message"), "id": .string("directory-user"), "parentId": .null,
                "timestamp": .string("2026-10-17T00:00:00.000Z"), "message": .object(["role": .string("user"), "content": .string(originalPathText), "timestamp": .number(1_792_195_200_000)])])
            var missingDirectory = try JSONEncoder().encode(sourceHeader); missingDirectory.append(10)
            missingDirectory.append(try JSONEncoder().encode(sourceEntry)); missingDirectory.append(10)
            let originalSource = root.appendingPathComponent("directory-source.jsonl")
            try missingDirectory.write(to: originalSource)
            let unbound = await host.handle(AppRequest(epoch: host.epoch, session: emptyImported.selected, action: .importSession(data: missingDirectory)), device: device)
            try require(unbound == .failure(.invalidRequest))
            try require(await host.state().selected == emptyImported.selected)
            let chosenID = try await host.directories.register(chosenFolder)
            _ = try await send(.importSessionInDirectory(data: missingDirectory, directory: chosenID))
            let relocated = await host.state()
            try require(relocated.selected != emptyImported.selected && !relocated.working)
            try require(relocated.messages.contains { $0.role == "user" && $0.text == originalPathText })
            let observed = try String(contentsOf: cwd, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try require(try DirectoryRegistry.identify(URL(fileURLWithPath: observed)) == DirectoryRegistry.identify(chosenFolder))
            guard case .exportSession(let relocatedArchive) = try await send(.exportJSONL) else { throw CheckFailure.assertion(#line) }
            try require(try SessionImport(data: relocatedArchive.data).directory == DirectoryRegistry.identify(chosenFolder).url.path)
            try require(try Data(contentsOf: originalSource) == missingDirectory)
            await host.shutdown()
            try require((try? Data(contentsOf: globalSettings)) == settingsBefore)
        } catch { await host.shutdown(); throw error }
    }
}
