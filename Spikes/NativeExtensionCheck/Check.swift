import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case arguments, assertion(Int), rejected(RemoteFault) }
private func require(_ condition: Bool, line: Int = #line) throws { if !condition { throw CheckFailure.assertion(line) } }
private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private struct Manifest: Decodable {
    struct Resources: Decodable { var extensions: [String] }
    var version: String
    var pi: Resources
}

/// Loads the configured package inventory in an empty home. Menus are cancelled;
/// no provider request, account change, sync transfer or installed-setting write is permitted.
@main struct NativeExtensionCheck {
    static func main() async {
        do { try await run(); print("PASS: isolated installed-extension discovery and cancellable command checks.") }
        catch {
            if let failure = error as? CheckFailure { print("FAIL: \(failure)") }
            else { print("FAIL: isolated extension check could not complete.") }
            exit(1)
        }
    }
    private static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        let packages = URL(fileURLWithPath: CommandLine.arguments[2])
        let inventory = ["accounts", "btw", "caffeinate", "stamp", "sync", "file-context", "tool", "herdr", "usage", "progress", "starship", "inspect", "codex-compact", "notify"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-remote-extensions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var extensions: [URL] = []
        for name in inventory {
            let folder = packages.appendingPathComponent("pi-" + name)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("package.json")))
            for entry in manifest.pi.extensions { extensions.append(folder.appendingPathComponent(entry)) }
            print("PACKAGE: pi-\(name) \(manifest.version)")
        }
        let wrapper = root.appendingPathComponent("isolated-pi")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let flags = extensions.map { "--extension " + quoted($0.path) }.joined(separator: " ")
        let script = """
        #!/bin/sh
        exec /usr/bin/env -i HOME=\(quoted(root.path)) PATH=\(quoted(path)) TMPDIR=\(quoted(root.path)) PI_CODING_AGENT_DIR=\(quoted(root.appendingPathComponent("agent").path)) PI_TELEMETRY=0 \(quoted(pi.path)) --offline --no-extensions --no-mcp --no-context-files --no-skills --no-prompt-templates --no-tools --provider openai --model gpt-4o \(flags) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: wrapper)
        do {
            let directory = try await host.directories.register(root)
            let device = UUID()
            func send(_ action: SessionAction) async throws -> AppResult {
                let state = await host.state()
                let result = await host.handle(AppRequest(epoch: host.epoch, session: state.selected, action: action), device: device)
                if case .failure(let fault) = result { throw CheckFailure.rejected(fault) }
                return result
            }
            _ = try await send(.createSession(directory: directory))
            let initial = await host.state()
            try require(initial.error == nil)
            for command in initial.commands { print("COMMAND: \(command.name)") }
            let names = ["accounts", "btw", "caffeinate", "stamp", "sync", "file-context", "tool", "usage", "progress", "starship", "inspect", "codex-compact", "notify"]
            for name in names {
                try require(initial.commands.contains { $0.name == name })
                let before = await host.state()
                let task = Task { try await send(.command(name: name, arguments: "")) }
                let completed = Completion()
                let waiter = Task {
                    _ = await task.result
                    await completed.finish()
                }
                var methods: [String] = []
                for _ in 0..<400 {
                    if await completed.done { break }
                    let current = await host.state()
                    if let dialog = current.dialogs.first {
                        try require(["select", "confirm", "input", "editor"].contains(dialog.method))
                        methods.append(dialog.method)
                        _ = try await send(.answer(dialog: dialog.id, value: nil, confirmed: nil, cancelled: true))
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard await completed.done else { task.cancel(); waiter.cancel(); throw CheckFailure.assertion(#line) }
                _ = try await task.value
                let after = await host.state()
                try require(after.phase == "idle" && after.messages.isEmpty && after.dialogs.isEmpty)
                try require(after.selected == before.selected)
                let terminalOnly = ["btw": "requires interactive TUI", "file-context": "requires Pi's interactive TUI", "inspect": "requires TUI mode"]
                if let expected = terminalOnly[name] {
                    try require(methods.isEmpty && after.notices.contains { $0.contains(expected) })
                    print("GAP: \(name) rejects RPC with an explicit TUI requirement")
                } else {
                    print("CHECK: \(name) methods=\(methods.joined(separator: ",")) notices=\(after.notices.count) fault=\(String(describing: after.error))")
                }
            }
            await host.shutdown()
        } catch { await host.shutdown(); throw error }
    }
}

private actor Completion {
    private(set) var done = false
    func finish() { done = true }
}
