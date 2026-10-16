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
        do { try await run(); print("PASS: native host directory, model, thinking, dialogs, Stop and idle restoration checks.") }
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
            _ = try await send(.resumeSession(id: selected!))
            try require(await host.state().runtime == originalRuntime)
            await host.shutdown()
            try require((try? Data(contentsOf: globalSettings)) == settingsBefore)
        } catch { await host.shutdown(); throw error }
    }
}
