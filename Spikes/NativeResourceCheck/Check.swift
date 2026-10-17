import Darwin
import Foundation
import PiRemoteCore
import PiRemoteHost

private enum CheckFailure: Error { case arguments, assertion(Int), rejected(RemoteFault, Int) }
private func require(_ condition: Bool, line: Int = #line) throws { if !condition { throw CheckFailure.assertion(line) } }
private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func literal(_ text: String) throws -> String { String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }

/// Installed-Pi expansion through the native command path. No network provider is available.
@main struct NativeResourceCheck {
    static func main() async {
        do { try await run(); print("PASS: native resources, quoting/defaults, trust isolation, project precedence and local-package discovery without provider requests.") }
        catch {
            if let failure = error as? CheckFailure { print("FAIL: \(failure)") }
            else { print("FAIL: native resource check could not complete.") }
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
        let pi = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(FileManager.default.isExecutableFile(atPath: pi.path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-remote-resources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), project = root.appendingPathComponent("project")
        let agent = root.appendingPathComponent("agent")
        let skill = agent.appendingPathComponent("skills/native-resource/SKILL.md")
        let template = agent.appendingPathComponent("prompts/native-template.md")
        let fixture = agent.appendingPathComponent("extensions/fixture.js")
        for folder in [home, project, skill.deletingLastPathComponent(), template.deletingLastPathComponent(), fixture.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try """
        ---
        name: native-resource
        description: Verify native resource command expansion with a private fixture.
        ---
        Skill fixture payload. Resolve references relative to this skill directory.
        """.write(to: skill, atomically: true, encoding: .utf8)
        try """
        ---
        description: Verify native template quoting and defaults.
        ---
        Template fixture first=$1; all=$@; second=${2:-fallback}
        """.write(to: template, atomically: true, encoding: .utf8)
        let projectTemplate = project.appendingPathComponent(".pi/prompts/native-template.md")
        let projectSkill = project.appendingPathComponent(".pi/skills/native-resource/SKILL.md")
        let projectExtension = project.appendingPathComponent(".pi/extensions/marker.js")
        let package = root.appendingPathComponent("local-package")
        let packageTemplate = package.appendingPathComponent("templates/package-native.md")
        let projectLoaded = root.appendingPathComponent("project-loaded")
        for file in [projectTemplate, projectSkill, projectExtension, packageTemplate] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try "Project template first=$1".write(to: projectTemplate, atomically: true, encoding: .utf8)
        try """
        ---
        name: native-resource
        description: Project precedence fixture.
        ---
        Project skill fixture payload.
        """.write(to: projectSkill, atomically: true, encoding: .utf8)
        try "import { writeFileSync } from 'node:fs'; export default function () { writeFileSync(\(try literal(projectLoaded.path)), 'loaded'); }"
            .write(to: projectExtension, atomically: true, encoding: .utf8)
        try "Package template first=$1".write(to: packageTemplate, atomically: true, encoding: .utf8)
        try #"{"name":"native-local-fixture","pi":{"prompts":["templates/package-native.md"]}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "{\"packages\":[\(try literal(package.path))]}".write(to: project.appendingPathComponent(".pi/settings.json"), atomically: true, encoding: .utf8)
        let captured = root.appendingPathComponent("captured.jsonl")
        let providerCalled = root.appendingPathComponent("provider-called")
        let source = """
        import { appendFileSync } from "node:fs";
        export default function (pi) {
            pi.registerProvider("native-resource-fixture", {
                api: "native-resource-fixture",
                apiKey: "fixture-not-a-secret",
                baseUrl: "http://127.0.0.1:9",
                models: [{ id: "capture", name: "Resource capture fixture", reasoning: false,
                    input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                    contextWindow: 200000, maxTokens: 64 }],
                streamSimple: () => {
                    appendFileSync(\(try literal(providerCalled.path)), "unexpected", { mode: 0o600 });
                    throw new Error("Fixture provider must not run");
                }
            });
            pi.on("before_agent_start", (event, ctx) => {
                if (event.messageType !== "user") return;
                appendFileSync(\(try literal(captured.path)), JSON.stringify({ prompt: event.prompt }) + "\\n", { mode: 0o600 });
                ctx.abort();
            });
        }
        """
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("isolated-pi")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let launcher = """
        #!/bin/sh
        exec /usr/bin/env -i HOME=\(quoted(home.path)) PATH=\(quoted(path)) \\
          PI_CODING_AGENT_DIR=\(quoted(agent.path)) PI_OFFLINE=1 PI_TELEMETRY=0 \\
          \(quoted(pi.path)) --offline --no-mcp --no-context-files --no-tools \\
          --provider native-resource-fixture --model capture "$@"
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
            _ = try await send(.createSession(directory: directory))
            let initial = await host.state()
            try require(initial.commands.contains { $0.name == "native-template" })
            try require(initial.commands.contains { $0.name == "skill:native-resource" })
            try require(!initial.commands.contains { $0.name == "package-native" })
            try require(!FileManager.default.fileExists(atPath: projectLoaded.path))
            _ = try await send(.autoCompaction(enabled: false))
            let commands = [("native-template", "\"two words\" tail"), ("native-template", ""), ("skill:native-resource", "specific task")]
            for (index, command) in commands.enumerated() {
                _ = try await send(.command(name: command.0, arguments: command.1))
                var complete = false
                for _ in 0..<200 {
                    let records = (try? Data(contentsOf: captured).split(separator: 10).count) ?? 0
                    if records == index + 1, await !host.state().working { complete = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try require(complete)
                try require(!FileManager.default.fileExists(atPath: providerCalled.path))
            }
            let records = try Data(contentsOf: captured).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            let prompts = records.compactMap { $0["prompt"]?.string }
            try require(prompts.count == 3)
            try require(prompts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "Template fixture first=two words; all=two words tail; second=tail")
            try require(prompts[1].trimmingCharacters(in: .whitespacesAndNewlines) == "Template fixture first=; all=; second=fallback")
            try require(prompts[2].contains("<skill name=\"native-resource\" location=\"") && prompts[2].contains("SKILL.md"))
            try require(prompts[2].contains("Skill fixture payload.") && prompts[2].hasSuffix("specific task"))
            guard case .statistics(let usage) = try await send(.statistics) else { throw CheckFailure.assertion(#line) }
            try require(usage.tokens.total == 0 && usage.cost == 0)
            let state = await host.state()
            let rejected = await host.handle(AppRequest(epoch: state.epoch, session: state.selected,
                action: .command(name: "not-discovered", arguments: "")), device: device)
            try require(rejected == .failure(.unsupportedFeature))
            try require(try Data(contentsOf: captured).split(separator: 10).count == 3)
            _ = try await send(.closeSession)
            // The override applies only to this private fixture, never the user's projects or trust store.
            try launcher.replacingOccurrences(of: "--provider native-resource-fixture", with: "--approve --provider native-resource-fixture")
                .write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            _ = try await send(.createSession(directory: directory))
            let trusted = await host.state()
            try require(trusted.commands.contains { $0.name == "package-native" })
            try require(FileManager.default.fileExists(atPath: projectLoaded.path))
            let trustedCommands = [("native-template", "trusted"), ("skill:native-resource", "trusted task"), ("package-native", "package task")]
            for (index, command) in trustedCommands.enumerated() {
                _ = try await send(.command(name: command.0, arguments: command.1))
                var complete = false
                for _ in 0..<200 {
                    let count = (try? Data(contentsOf: captured).split(separator: 10).count) ?? 0
                    if count == index + 4, await !host.state().working { complete = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try require(complete)
                try require(!FileManager.default.fileExists(atPath: providerCalled.path))
            }
            let trustedRecords = try Data(contentsOf: captured).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
            let trustedPrompts = trustedRecords.compactMap { $0["prompt"]?.string }
            try require(trustedPrompts.count == 6)
            try require(trustedPrompts[3].trimmingCharacters(in: .whitespacesAndNewlines) == "Project template first=trusted")
            try require(trustedPrompts[4].contains(projectSkill.path) && trustedPrompts[4].contains("Project skill fixture payload.") && trustedPrompts[4].hasSuffix("trusted task"))
            try require(trustedPrompts[5].trimmingCharacters(in: .whitespacesAndNewlines) == "Package template first=package")
            guard case .statistics(let trustedUsage) = try await send(.statistics) else { throw CheckFailure.assertion(#line) }
            try require(trustedUsage.tokens.total == 0 && trustedUsage.cost == 0)
            try require(!FileManager.default.fileExists(atPath: agent.appendingPathComponent("trust.json").path))
            _ = try await send(.closeSession)
            try launcher.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            try FileManager.default.removeItem(at: projectLoaded)
            _ = try await send(.createSession(directory: directory))
            let untrustedAgain = await host.state()
            try require(!untrustedAgain.commands.contains { $0.name == "package-native" })
            try require(!FileManager.default.fileExists(atPath: projectLoaded.path))
            await host.shutdown()
            try require(!FileManager.default.fileExists(atPath: providerCalled.path))
        } catch { await host.shutdown(); throw error }
    }
}
