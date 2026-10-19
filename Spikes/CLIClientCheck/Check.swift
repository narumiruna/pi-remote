import Darwin
import Foundation
import PiRemoteClient
import PiRemoteCore
import PiRemoteSecurity

private enum CheckFailure: Error { case assertion(Int), arguments }
private func require(_ condition: Bool, line: Int = #line) throws {
    if !condition { throw CheckFailure.assertion(line) }
}

/// This fixture-only store never writes device credentials to disk or Keychain.
private final class FixtureSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}

@main struct CLIClientCheck {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst() == ["--fixtures"] { try fixtures(); return }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--decode-server" {
                let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                let packets = try JSONDecoder().decode([AppPacket<ServerMessage>].self, from: input)
                try require(!packets.isEmpty && packets.allSatisfy { $0.version == 1 })
                print("PASS: Swift decoded server fixtures.")
                return
            }
            guard CommandLine.arguments.count == 2 else { throw CheckFailure.arguments }
            try await live(URL(fileURLWithPath: CommandLine.arguments[1]))
            print("PASS: production Swift client CLI acceptance.")
        } catch {
            // Never print packet contents, pairing material, provider errors or paths.
            if let failure = error as? CheckFailure { print("FAIL: CLI client check \(failure).") }
            else { print("FAIL: CLI client check could not complete.") }
            exit(1)
        }
    }

    private struct NamedClient: Encodable { var name: String; var packet: AppPacket<ClientMessage> }
    private struct NamedServer: Encodable { var name: String; var packet: AppPacket<ServerMessage> }
    private struct AuthenticationFixture: Encodable {
        var device: UUID
        var secret: Data
        var nonce: Data
        var proof: Data
    }
    private struct Fixtures: Encodable {
        var generatedBy = "CLIClientCheck --fixtures; Foundation JSONEncoder"
        var authentication: AuthenticationFixture
        var client: [NamedClient]
        var server: [NamedServer]
    }
    private static func fixtures() throws {
        let host = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let epoch = UUID(uuidString: "abcdef01-2345-6789-abcd-ef0123456789")!
        let device = UUID(uuidString: "11223344-5566-7788-99aa-bbccddeeff00")!
        let bytes = Data(0..<32)
        let proof = DeviceProof.create(secret: bytes, device: device, nonce: bytes)
        let actions: [(String, SessionAction)] = [
            ("snapshot", .snapshot), ("synchronize", .synchronize(epoch: epoch, after: 9_007_199_254_740_991)),
            ("synchronize-nil", .synchronize(epoch: nil, after: nil)),
            ("directories", .directories(id: host, cursor: device)), ("directories-nil", .directories(id: nil, cursor: nil)),
            ("directoryAtPath", .directoryAtPath(path: "~/src/project")), ("preview", .preview(id: host)),
            ("createSession", .createSession(directory: host)), ("newSession", .newSession(parent: true)),
            ("importSession", .importSession(data: bytes)), ("importSessionInDirectory", .importSessionInDirectory(data: bytes, directory: host)),
            ("resumeSession", .resumeSession(id: host)),
            ("prompt", .prompt(text: "Fixture instruction", delivery: .prompt, image: nil)),
            ("prompt-image", .prompt(text: "Fixture image", delivery: .steer, image: ImageAttachment(data: bytes, mimeType: "image/png"))),
            ("prompt-followUp", .prompt(text: "Fixture follow-up", delivery: .followUp, image: nil)),
            ("stop", .stop), ("recoverQueue", .recoverQueue(stop: true)),
            ("bash", .bash(command: "fixture only", excludeFromContext: false, confirmed: true)), ("abortBash", .abortBash(id: host)),
            ("model", .model(provider: "fixture", id: "model")), ("thinking", .thinking(level: "high")),
            ("cycleModel", .cycleModel), ("cycleThinking", .cycleThinking), ("compact", .compact(instructions: "Fixture summary")),
            ("rename", .rename(name: "Fixture")), ("history", .history), ("historyPage", .historyPage(cursor: device)),
            ("historyEntry", .historyEntry(id: host)), ("sessionTree", .sessionTree(cursor: nil)), ("fork", .fork(entry: "entry")),
            ("clone", .clone), ("command", .command(name: "fixture-select", arguments: "")),
            ("answer", .answer(dialog: "dialog", value: "Second", confirmed: nil, cancelled: false)),
            ("answer-confirm", .answer(dialog: "dialog", value: nil, confirmed: true, cancelled: false)),
            ("diff", .diff), ("statistics", .statistics), ("releaseNotes", .releaseNotes(offset: 0, revision: nil)),
            ("exportSession", .exportSession), ("exportJSONL", .exportJSONL), ("outputImage", .outputImage(id: host)),
            ("lastAssistant", .lastAssistant), ("runtimeSettings", .runtimeSettings),
            ("queueMode", .queueMode(kind: .followUp, mode: .oneAtATime)), ("autoCompaction", .autoCompaction(enabled: false)),
            ("autoRetry", .autoRetry(enabled: true)), ("abortRetry", .abortRetry), ("closeSession", .closeSession),
        ]
        var client = [NamedClient(name: "pair", packet: AppPacket(.pair(device: device, name: "Fixture phone", grant: bytes))),
                      NamedClient(name: "authenticate", packet: AppPacket(.authenticate(device: device, proof: proof)))]
        client += actions.map { NamedClient(name: $0.0, packet: AppPacket(.request(AppRequest(id: device, epoch: epoch, session: host, action: $0.1)))) }
        var state = HostSnapshot(host: host, epoch: epoch)
        state.sequence = 9_007_199_254_740_991
        state.sessions = [SessionInfo(id: host, title: "Fixture", directory: "/fixture/project", updated: Date(timeIntervalSinceReferenceDate: 123.5), interrupted: true)]
        state.selected = host
        state.messages = [TranscriptMessage(id: device, role: "assistant", text: "Fixture text", thinking: "Fixture thinking", images: [OutputImageReference(id: host)], tool: TranscriptTool(name: "read", target: "fixture.txt", status: .completed), toolCallRanges: [0..<7])]
        state.models = [ModelOption(provider: "fixture", model: "model", name: "Fixture model")]
        state.commands = [CommandOption(name: "fixture-select", detail: "Fixture dialog", source: "extension")]
        state.dialogs = [ExtensionDialog(id: "dialog", method: "select", title: "Fixture", message: "Choose", options: ["First", "Second"], text: "", expires: Date(timeIntervalSinceReferenceDate: 456.25))]
        state.extensionDisplay = ExtensionDisplayState(statuses: [ExtensionStatus(id: "status", text: "Fixture status")], widgets: [ExtensionWidget(id: "widget", text: "Fixture widget")], notices: [ExtensionNotice(id: "notice", text: "Fixture notice")])
        state.runtime = RuntimeSettings(steeringMode: .all, followUpMode: .oneAtATime, autoCompactionEnabled: true)
        let page = DirectoryPage(id: host, path: "/fixture/project", parent: device, items: [DirectoryItem(id: device, name: "nested", isDirectory: true)], next: nil)
        let messages: [(String, ServerMessage)] = [
            ("challenge", .challenge(nonce: bytes)), ("approvalRequired", .approvalRequired),
            ("paired", .paired(credential: bytes, host: host)), ("authenticated", .authenticated(host: host, epoch: epoch)),
            ("reply-ok", .reply(id: device, result: .ok, state: nil)),
            ("reply-snapshot", .reply(id: device, result: .snapshot(state), state: state)),
            ("reply-sync", .reply(id: device, result: .synchronized(StateSync(snapshot: state)), state: nil)),
            ("reply-directories", .reply(id: device, result: .directories(page), state: nil)),
            ("reply-failure", .reply(id: device, result: .failure(.unsupportedFeature), state: nil)),
            ("state", .state(state)), ("denied", .denied),
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output = Fixtures(authentication: AuthenticationFixture(device: device, secret: bytes, nonce: bytes, proof: proof),
                              client: client, server: messages.map { NamedServer(name: $0.0, packet: AppPacket($0.1)) })
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data([10]))
    }

    private struct Configuration: Decodable {
        var pairingCode: String
        var cwd: String
        var controlDirectory: String
        var outputFile: String
        var verificationFile: String?
        var device: UUID?
    }
    private struct DeviceControl: Encodable { var device: UUID }
    private struct EmptyControl: Encodable {}
    private struct Output: Encodable { var status = "pass" }

    private static func live(_ url: URL) async throws {
        guard let config = try PrivateFiles.read(Configuration.self, from: url) else { throw CheckFailure.arguments }
        let control = URL(fileURLWithPath: config.controlDirectory, isDirectory: true)
        let device = config.device ?? UUID()
        let code = try PairingCode.decode(config.pairingCode)
        let secrets = FixtureSecrets()
        let client = RemoteClient(secrets: secrets)
        // Only the fixture server reads these files. Production approval is unchanged.
        try PrivateFiles.write(DeviceControl(device: device), to: control.appendingPathComponent("approve.json"))
        let saved = try await client.pair(code: code, device: device, name: "CLI acceptance fixture")
        do {
            try await client.connect(saved)
            let initial = try await snapshot(client)
            try require(initial.selected == nil && initial.sessions.isEmpty)
            guard case .directories(let root) = try await client.request(.directories(id: nil, cursor: nil)) else { throw CheckFailure.assertion(#line) }
            try require(root.path == config.cwd)
            if let parent = root.parent {
                guard case .directories(let page) = try await client.request(.directories(id: parent, cursor: nil)) else { throw CheckFailure.assertion(#line) }
                try require(page.path != root.path)
            }
            guard case .directories(let opened) = try await client.request(.directoryAtPath(path: config.cwd)),
                  let nested = opened.items.first(where: { $0.isDirectory && $0.fault == nil }) else { throw CheckFailure.assertion(#line) }
            guard case .directories(let project) = try await client.request(.directories(id: nested.id, cursor: nil)) else { throw CheckFailure.assertion(#line) }
            _ = try await client.request(.createSession(directory: project.id))
            let loaded = try await snapshot(client)
            guard let selected = loaded.selected else { throw CheckFailure.assertion(#line) }
            try require(loaded.sessions.first(where: { $0.id == selected })?.directory == project.path)
            guard let model = loaded.models.first, let level = loaded.thinkingLevels.last else { throw CheckFailure.assertion(#line) }
            _ = try await client.request(.model(provider: model.provider, id: model.model))
            _ = try await client.request(.thinking(level: level))
            _ = try await client.request(.prompt(text: "CLI fixture: write acceptance.txt with CLI acceptance\n", delivery: .prompt, image: nil))
            // Accepted input must survive a connection loss without a resend.
            await client.disconnect()
            try await client.connect(saved)
            let completed = try await wait(client) { !$0.working && $0.messages.contains { $0.role == "assistant" && !$0.streaming } }
            try require(completed.messages.filter { $0.role == "user" }.count == 1)
            try require(completed.messages.contains { $0.thinking?.contains("Fixture thinking") == true })
            try require(completed.messages.contains { $0.tool?.name == "write" })
            let written = URL(fileURLWithPath: config.verificationFile ?? project.path + "/acceptance.txt")
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: written.path) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try require(try String(contentsOf: written, encoding: .utf8) == "CLI acceptance\n")
            try require(loaded.commands.contains(where: { $0.name == "fixture-select" }))
            do {
                let command = Task { try await client.request(.command(name: "fixture-select", arguments: "")) }
                let asking = try await wait(client) { !$0.dialogs.isEmpty }
                guard let dialog = asking.dialogs.first else { throw CheckFailure.assertion(#line) }
                _ = try await client.request(.answer(dialog: dialog.id, value: "Second", confirmed: nil, cancelled: false))
                _ = try await command.value
            }
            _ = try await client.request(.prompt(text: "CLI fixture: wait for Stop", delivery: .prompt, image: nil))
            _ = try await wait(client) { $0.working }
            _ = try await client.request(.prompt(text: "Fixture steering", delivery: .steer, image: nil))
            _ = try await client.request(.prompt(text: "Fixture follow-up", delivery: .followUp, image: nil))
            _ = try await client.request(.stop)
            let stopped = try await wait(client) { !$0.working }
            try require(stopped.pendingMessages == nil || stopped.pendingMessages == 0)
            do { _ = try await client.request(.clone); throw CheckFailure.assertion(#line) }
            catch RemoteFault.unsupportedFeature {}
            _ = try await client.request(.closeSession)
            _ = try await client.request(.resumeSession(id: selected))
            _ = try await client.request(.prompt(text: "CLI fixture: wait for Stop", delivery: .prompt, image: nil))
            _ = try await wait(client) { $0.working }
            let oldEpoch = try await snapshot(client).epoch
            try PrivateFiles.write(EmptyControl(), to: control.appendingPathComponent("restart.json"))
            try await waitFile(control.appendingPathComponent("restart.done"))
            await client.disconnect()
            try await client.connect(saved)
            let restarted = try await snapshot(client)
            try require(restarted.epoch != oldEpoch && restarted.selected == nil)
            try require(restarted.sessions.contains { $0.id == selected && $0.interrupted })
            _ = try await client.request(.resumeSession(id: selected))
            let resumed = try await snapshot(client)
            try require(resumed.selected == selected && !resumed.working)
            try require(resumed.messages.filter { $0.role == "user" && $0.text.contains("write acceptance.txt") }.count == 1)
            try PrivateFiles.write(DeviceControl(device: device), to: control.appendingPathComponent("revoke.json"))
            try await waitFile(control.appendingPathComponent("revoke.done"))
            do { _ = try await client.request(.snapshot); throw CheckFailure.assertion(#line) }
            catch is RemoteFault {}
            await client.disconnect()
            do { try await client.connect(saved); throw CheckFailure.assertion(#line) }
            catch RemoteFault.unauthorized {}
            try PrivateFiles.write(Output(), to: URL(fileURLWithPath: config.outputFile))
        } catch { await client.disconnect(); throw error }
        await client.disconnect()
    }
    private static func snapshot(_ client: RemoteClient) async throws -> HostSnapshot {
        guard case .snapshot(let state) = try await client.request(.snapshot) else { throw CheckFailure.assertion(#line) }
        return state
    }
    private static func wait(_ client: RemoteClient, until predicate: (HostSnapshot) -> Bool) async throws -> HostSnapshot {
        for _ in 0..<400 {
            let state = try await snapshot(client)
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailure.assertion(#line)
    }
    private static func waitFile(_ url: URL) async throws {
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailure.assertion(#line)
    }
}
