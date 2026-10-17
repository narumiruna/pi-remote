import AppKit
import Foundation
import PiRemoteClient
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity
import XCTest

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@MainActor final class CompanionTests: XCTestCase {
    private func waitUntil(_ condition: () async -> Bool, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("State did not arrive", line: line)
        throw RemoteFault.unavailable
    }

    func testSlashCatalogKeepsNativeNamesAndDiscoveredDetails() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = UUID()
        state.commands = [
            .init(name: "resume", detail: "Collision", source: "extension"),
            .init(name: "Review", detail: "Actual detail", source: "extension"),
            .init(name: "Review", detail: "Duplicate", source: "prompt"),
            .init(name: "", detail: "Empty", source: "extension"),
            .init(name: "bad name", detail: "Invalid", source: "extension"),
            .init(name: "Users/file", detail: "Path", source: "extension")
        ]
        let options = MacSlashCommands.options(in: state)
        XCTAssertEqual(options.map(\.name), ["resume", "tree", "history", "Review"])
        XCTAssertEqual(options.first?.native, .resume)
        XCTAssertEqual(options.last?.detail, "Actual detail")
        XCTAssertEqual(MacSlashCommands.matching(in: state, query: "RE").map(\.name), ["resume", "Review"])
        XCTAssertEqual(MacSlashCommands.submission("/Review  exact\narguments ", in: state), .command(name: "Review", arguments: " exact\narguments "))
        guard case .invalid = MacSlashCommands.submission("/review", in: state) else { return XCTFail("Dispatch must use the exact discovered name") }
    }

    func testSlashCompletionUsesUTF16AndOnlyTheLeadingToken() throws {
        let text = " \t/😀x argument"
        let end = (" \t/😀x" as NSString).length
        let completion = try XCTUnwrap(MacSlashCommands.completion(in: text, selection: NSRange(location: end, length: 0)))
        XCTAssertEqual(completion.query, "😀x")
        XCTAssertEqual(completion.tokenRange, NSRange(location: 2, length: 4))
        XCTAssertNotNil(MacSlashCommands.completion(in: "/", selection: NSRange(location: 1, length: 0)))
        XCTAssertNil(MacSlashCommands.completion(in: text, selection: NSRange(location: 4, length: 0)), "Reject a caret inside a surrogate pair")
        XCTAssertNil(MacSlashCommands.completion(in: text, selection: NSRange(location: end + 1, length: 0)))
        XCTAssertNil(MacSlashCommands.completion(in: text, selection: NSRange(location: end - 1, length: 1)))
        XCTAssertNil(MacSlashCommands.completion(in: text, selection: NSRange(location: NSNotFound, length: 0)))
        XCTAssertNil(MacSlashCommands.completion(in: text, selection: NSRange(location: -1, length: 0)))
        XCTAssertNil(MacSlashCommands.completion(in: text, selection: NSRange(location: Int.max, length: Int.max)))
        for value in ["Read /tree", "```\n/tree\n```", "/Users/foo", "//server/share"] {
            XCTAssertNil(MacSlashCommands.completion(in: value, selection: NSRange(location: (value as NSString).length, length: 0)))
            XCTAssertEqual(MacSlashCommands.submission(value, in: HostSnapshot(host: UUID(), epoch: UUID())), .prompt)
        }
        var pathState = HostSnapshot(host: UUID(), epoch: UUID()); pathState.selected = UUID()
        XCTAssertEqual(MacSlashCommands.submission("/tmp contains the output; inspect it", in: pathState), .prompt)
        pathState.commands = [.init(name: "tmp", detail: "Known command wins", source: "extension")]
        XCTAssertEqual(MacSlashCommands.submission("/tmp argument", in: pathState), .command(name: "tmp", arguments: "argument"))
        let option = MacSlashOption(name: "history", detail: "", native: .history)
        let replaced = MacSlashCommands.completing(option, in: text, completion: completion)
        XCTAssertEqual(replaced.text, " \t/history argument")
        XCTAssertEqual(replaced.selection, NSRange(location: 11, length: 0))
        let partial = try XCTUnwrap(MacSlashCommands.completion(in: "/hi", selection: NSRange(location: 3, length: 0)))
        let inserted = MacSlashCommands.completing(option, in: "/hi", completion: partial)
        XCTAssertEqual(inserted.text, "/history ")
        XCTAssertEqual(inserted.selection, NSRange(location: 9, length: 0))
        let invalid = MacSlashCommands.completing(option, in: "changed", completion: partial)
        XCTAssertEqual(invalid.text, "changed")
    }

    func testSlashAvailabilityAndArgumentLimits() throws {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.selected = UUID()
        state.commands = [.init(name: "ask", detail: "", source: "extension"), .init(name: "template", detail: "", source: "prompt")]
        func enabled(_ name: String) throws -> Bool {
            try XCTUnwrap(MacSlashCommands.options(in: state).first { $0.name == name }).isEnabled(in: state)
        }
        state.phase = "streaming"
        XCTAssertTrue(try enabled("resume"))
        XCTAssertFalse(try enabled("tree"))
        XCTAssertFalse(try enabled("history"))
        XCTAssertTrue(try enabled("ask"))
        XCTAssertFalse(try enabled("template"))
        for phase in ["starting", "stopping", "recovering"] {
            state.phase = phase
            XCTAssertFalse(try enabled("resume"))
            XCTAssertFalse(try enabled("ask"))
        }
        state.phase = "waiting"
        state.dialogs = [ExtensionDialog(id: "question", method: "confirm", title: "Question", message: "Proceed?", options: [], text: "", expires: nil)]
        XCTAssertFalse(try enabled("resume"), "Navigation must not replace an unanswered request")
        state.dialogs = []
        state.phase = "idle"
        XCTAssertEqual(MacSlashCommands.submission("/resume", in: state), .native(.resume))
        for input in ["/resume id", "/tree branch", "/history page", "/unknown", "/ask " + String(repeating: "é", count: 8_193)] {
            guard case .invalid(let error) = MacSlashCommands.submission(input, in: state) else { XCTFail("Expected invalid command"); continue }
            XCTAssertFalse(error.isEmpty)
        }
        let maximum = String(repeating: "é", count: 8_192)
        XCTAssertEqual(MacSlashCommands.submission("/ask " + maximum, in: state), .command(name: "ask", arguments: maximum))
        state.capabilities = []
        XCTAssertFalse(try enabled("resume"))
        XCTAssertFalse(try enabled("tree"))
        XCTAssertFalse(try enabled("history"))
        state.selected = nil
        XCTAssertFalse(try enabled("ask"))
    }

    func testNativeSlashRoutingPreservesInvalidDraftsAndDoesNotExecuteCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PiRemote.SlashTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CompanionModel(support: root, secrets: MemorySecrets(), defaults: defaults)
        model.state.selected = UUID()
        for native in MacNativeSlashCommand.allCases {
            model.text = "/" + native.rawValue
            model.send(context: model.state.context)
            XCTAssertEqual(model.panel, native.rawValue)
            XCTAssertEqual(model.text, "")
            XCTAssertFalse(model.sending)
            XCTAssertFalse(model.needsActionReview)
        }
        model.panel = nil
        model.text = "/tr"
        let completion = try XCTUnwrap(MacSlashCommands.completion(in: model.text, selection: NSRange(location: 3, length: 0)))
        let option = try XCTUnwrap(MacSlashCommands.options(in: model.state).first { $0.name == "tree" })
        model.text = MacSlashCommands.completing(option, in: model.text, completion: completion).text
        XCTAssertNil(model.panel, "Completion changes text only")
        model.state.phase = "streaming"
        model.send()
        XCTAssertEqual(model.text, "/tree ")
        XCTAssertNotNil(model.composerError)
        XCTAssertNil(model.panel)
        model.text = "/resume"
        XCTAssertNil(model.composerError)
        model.send()
        XCTAssertEqual(model.panel, "resume", "Browsing is allowed while busy")
        XCTAssertEqual(model.text, "")
        model.panel = nil
        model.sending = true
        model.text = "/resume"
        model.send()
        XCTAssertNil(model.panel, "A pending request keeps the existing Send guard")
        XCTAssertEqual(model.text, "/resume")
        model.sending = false
        model.text = "/unknown"
        model.send()
        XCTAssertNotNil(model.composerError)
        XCTAssertEqual(model.text, "/unknown")
        model.state.epoch = UUID()
        XCTAssertNil(model.composerError)
        model.text = "  \n"
        model.send()
        XCTAssertFalse(model.sending)
        await model.shutdown()
    }

    func testClipboardUsesANamedBoardAndRejectsInvalidTextBeforeWriting() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try LocalClipboard.copy("Private synthetic copy fixture", to: board)
        XCTAssertEqual(board.string(forType: .string), "Private synthetic copy fixture")
        XCTAssertThrowsError(try LocalClipboard.copy("", to: board))
        XCTAssertEqual(board.string(forType: .string), "Private synthetic copy fixture")
        XCTAssertThrowsError(try LocalClipboard.copy(String(repeating: "x", count: 256 * 1_024 + 1), to: board))
        XCTAssertEqual(board.string(forType: .string), "Private synthetic copy fixture")
    }

    func testCleanConnectionSetupUsesModelApprovalPersistenceAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("version-only-pi")
        try "#!/bin/sh\nprintf '1.3.0\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "PiRemote.SetupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(executable.path, forKey: "piExecutable")
        let store = MemorySecrets()
        let support = root.appendingPathComponent("support")
        let model = CompanionModel(support: support, secrets: store, defaults: defaults)
        let client = RemoteClient(secrets: store)
        model.address = "127.0.0.1"
        model.observe()
        do {
            XCTAssertNil(model.startupError)
            XCTAssertTrue(model.devices.isEmpty)
            model.startNetwork()
            try await waitUntil { model.listening && !model.starting }
            XCTAssertEqual(model.state.piVersion, "1.3.0")
            model.openPairing()
            try await waitUntil { !model.code.isEmpty }
            let code = try PairingCode.decode(model.code)
            XCTAssertEqual(code.url.host, "127.0.0.1")
            XCTAssertEqual(code.url.port, 7443)
            let device = UUID()
            let pairing = Task { try await client.pair(code: code, device: device, name: "Setup fixture") }
            try await waitUntil { model.pending != nil }
            XCTAssertEqual(model.pending?.device.id, device)
            XCTAssertTrue(model.devices.isEmpty, "A request is not local approval")
            model.approve(try XCTUnwrap(model.pending?.id))
            let mac = try await pairing.value
            try await waitUntil { model.devices.contains { $0.id == device } && model.code.isEmpty }
            try await client.connect(mac)
            guard case .snapshot(let state) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
            XCTAssertEqual(state.host, code.host)
            XCTAssertTrue(state.sessions.isEmpty)
            let persisted = try DeviceRegistry(secrets: store, metadata: support.appendingPathComponent("devices.json"))
            let savedDevices = await persisted.list()
            XCTAssertEqual(savedDevices.map(\.id), [device])
            model.stopNetwork()
            try await waitUntil { !model.listening }
            do { _ = try await client.request(.snapshot); XCTFail("Stopped listener must close access") }
            catch {}
            model.startNetwork()
            try await waitUntil { model.listening && !model.starting }
            try await client.connect(mac)
            model.revoke(device)
            try await waitUntil { model.devices.isEmpty }
            do { _ = try await client.request(.snapshot); XCTFail("Revoked device must lose access") }
            catch {}
            let revoked = try DeviceRegistry(secrets: store, metadata: support.appendingPathComponent("devices.json"))
            let remaining = await revoked.list()
            XCTAssertTrue(remaining.isEmpty)
        } catch { await client.disconnect(); await model.shutdown(); throw error }
        await client.disconnect(); await model.shutdown()
    }

    func testLocalAndPairedControlsShareStateAndSerialization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-pi")
        let script = #"""
#!/bin/sh
if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
folder=''; session=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-dir) folder=$2; shift 2 ;;
        --session-id) session=$2; shift 2 ;;
        --session) file=$2; session=${file##*/}; session=${session%.jsonl}; shift 2 ;;
        *) shift ;;
    esac
done
file="$folder/$session.jsonl"
if [ ! -f "$file" ]; then printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"; fi
streaming=false
name=null
reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
while IFS= read -r line; do
    id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    command=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    case "$command" in
        get_state) reply "{\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0,\"sessionId\":\"$session\",\"sessionFile\":\"$file\",\"sessionName\":$name}" ;;
        # This fixture renames only to its UUID directory basename.
        set_session_name) name=$(printf '%s' "$line" | /usr/bin/plutil -extract name raw -o - -); name="\"$name\""; printf '{"type":"session_info","name":%s}\n' "$name" >> "$file"; reply '{}' ;;
        get_available_models) reply '{"models":[]}' ;;
        get_available_thinking_levels) reply '{"levels":["off","low"]}' ;;
        get_commands) reply '{"commands":[{"name":"ask","source":"extension"}]}' ;;
        get_messages) if [ -f "$file.messages" ]; then IFS= read -r history < "$file.messages"; reply "{\"messages\":$history}"; else reply '{"messages":[]}'; fi ;;
        switch_session) file=$(printf '%s' "$line" | /usr/bin/plutil -extract sessionPath raw -o - -); session=${file##*/}; session=${session%.jsonl}; streaming=false; name=null; reply '{"cancelled":false}' ;;
        new_session) session=$(/usr/bin/uuidgen); file="$folder/$session.jsonl"; streaming=false; name=null; printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"; reply '{"cancelled":false}' ;;
        prompt)
            case "$line" in
                *'/ask'*) pending=$id; printf '{"type":"extension_ui_request","id":"local-question","method":"confirm","title":"Test confirmation"}\n' ;;
                *) printf x >> "$folder/accepted"; printf '[{"role":"assistant","content":[{"type":"text","text":"Shared state"}]}]\n' > "$file.messages"; streaming=true; reply '{"disposition":"started"}'; printf '{"type":"agent_start"}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Shared state"}]}}\n' ;;
            esac ;;
        steer|follow_up) printf x >> "$folder/accepted"; reply '{"disposition":"queued"}' ;;
        extension_ui_response) printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"disposition":"handled"}}\n' "$pending" ;;
        abort) streaming=false; reply '{}'; printf '{"type":"agent_settled"}\n' ;;
        *) reply '{}' ;;
    esac
done
"""#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "PiRemote.MacTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(executable.path, forKey: "piExecutable")
        let store = MemorySecrets()
        let support = root.appendingPathComponent("support")
        let model = CompanionModel(support: support, secrets: store, defaults: defaults)
        XCTAssertNil(model.startupError)
        let host = try XCTUnwrap(model.coordinator)
        let registry = try DeviceRegistry(secrets: store, metadata: root.appendingPathComponent("test-devices.json"))
        let identity = try await ServerIdentity.load(secrets: store, support: support)
        let server = AppServer(coordinator: host, registry: registry)
        let client = RemoteClient(secrets: store)
        model.observe()
        do {
            // Adding a workspace is not session activation and must not start Pi.
            try await model.addWorkspace(path: root.path)
            let beforeSession = await host.state()
            XCTAssertTrue(beforeSession.sessions.isEmpty)
            // Local creation must work before any listener or phone connection.
            let directory = try await host.directories.register(root)
            try await host.setExecutable(root.appendingPathComponent("missing-pi"))
            do {
                _ = try await model.request(.createSession(directory: directory))
                XCTFail("A missing Pi executable must fail clearly")
            } catch { XCTAssertEqual(error as? RemoteFault, .piLaunchFailed) }
            XCTAssertEqual(model.fault, .piLaunchFailed)
            try await host.setExecutable(executable)
            _ = try await model.request(.createSession(directory: directory))
            try await waitUntil { model.state.selected != nil }
            let first = try XCTUnwrap(model.state.selected)
            XCTAssertNil(model.fault)
            XCTAssertFalse(model.listening)
            let initialSession = try XCTUnwrap(model.state.sessions.first { $0.id == first })
            let originalTitle = initialSession.title
            try await waitUntil { model.sessionDisplayMetadata[first] != nil }
            XCTAssertTrue(model.displayName(for: initialSession).hasPrefix("Session · "))
            _ = try await model.request(.rename(name: originalTitle))
            try await waitUntil {
                guard let session = model.state.sessions.first(where: { $0.id == first }) else { return false }
                return model.displayName(for: session) == originalTitle
            }
            XCTAssertEqual(model.state.sessions.first { $0.id == first }?.title, originalTitle,
                           "An explicit Pi name equal to the directory fallback still needs fresh display metadata")
            model.text = "Local before pairing"
            model.send(context: model.state.context)
            try await waitUntil { !model.sending && model.state.working && model.state.messages.last?.text == "Shared state" }
            model.stopWork()
            try await waitUntil { !model.state.working }
            XCTAssertFalse(model.listening)
            let serverWasRunning = await server.isRunning()
            XCTAssertFalse(serverWasRunning)
            let port = try await server.start(identity: identity, address: "127.0.0.1", port: 0)
            let grant = try await server.openPairing()
            let code = PairingCode(host: host.hostID, name: "Mac model fixture", url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate, grant: grant, expires: Date().addingTimeInterval(120))
            let updates = await server.pairingUpdates()
            let approval = Task {
                for await candidate in updates {
                    if let candidate { try await server.approve(candidate.id); return }
                }
            }
            defer { approval.cancel() }
            let connections = await server.connectionUpdates()
            var connected = Set<UUID>()
            let connectionWatch = Task { for await devices in connections { connected = devices } }
            defer { connectionWatch.cancel() }
            let phoneID = UUID()
            let mac = try await client.pair(code: code, device: phoneID, name: "Fixture phone")
            try await approval.value
            XCTAssertTrue(connected.isEmpty, "Pairing alone is not an authenticated connection")
            try await client.connect(mac)
            try await waitUntil { connected.contains(phoneID) }
            model.text = "Kept draft"
            try model.attachText(FilePreview(name: "fixture.swift", text: "let attached = 42", truncated: false), context: model.state.context)
            XCTAssertTrue(model.text.hasPrefix("Kept draft\n\nFile: fixture.swift"))
            let attached = model.text
            var wrongAttachmentScope = model.state.context; wrongAttachmentScope.session = UUID()
            XCTAssertThrowsError(try model.attachText(FilePreview(name: "stale", text: "stale", truncated: false), context: wrongAttachmentScope))
            XCTAssertEqual(model.text, attached)
            model.text = "Local prompt"
            model.send(context: model.state.context)
            try await waitUntil { !model.sending && model.state.working && model.state.messages.last?.text == "Shared state" }
            XCTAssertEqual(model.text, "")
            guard case .snapshot(let remote) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
            XCTAssertEqual(remote.selected, first)
            XCTAssertEqual(remote.messages, model.state.messages)
            XCTAssertTrue(remote.working)
            do {
                _ = try await client.request(.createSession(directory: directory))
                XCTFail("Working session must not switch")
            } catch { XCTAssertEqual(error as? RemoteFault, .busy) }
            _ = try await client.request(.prompt(text: "Remote steering", delivery: .steer, image: nil))
            model.delivery = .followUp; model.text = "Local follow-up"; model.send()
            try await waitUntil { !model.sending }
            let accepted = support.appendingPathComponent("pi-sessions/" + first.uuidString + "/accepted")
            XCTAssertEqual(try Data(contentsOf: accepted).count, 4)
            model.stopWork()
            try await waitUntil { !model.state.working }
            guard case .snapshot(let stopped) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
            XCTAssertFalse(stopped.working)
            XCTAssertEqual(stopped.selected, first)

            // A local extension command waits for its dialog response while a
            // remote mutation must observe the same coordinator's busy gate.
            model.text = "/ask"
            let staleCommandContext = SessionContext(host: model.state.host, epoch: UUID(), session: model.state.selected)
            model.send(context: staleCommandContext)
            XCTAssertEqual(model.text, "/ask")
            XCTAssertEqual(model.fault, .conflict)
            XCTAssertFalse(model.sending)
            model.send(context: model.state.context)
            try await waitUntil { model.state.dialogs.first != nil }
            XCTAssertTrue(model.sending)
            XCTAssertEqual(model.text, "/ask", "Keep the command draft until acknowledgement")
            do {
                _ = try await client.request(.thinking(level: "low"))
                XCTFail("Remote mutation must not bypass the local command")
            } catch { XCTAssertEqual(error as? RemoteFault, .busy) }
            let dialog = try XCTUnwrap(model.state.dialogs.first)
            _ = try await client.request(.answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false))
            try await waitUntil { model.state.dialogs.isEmpty && !model.sending }
            XCTAssertEqual(model.text, "", "Acknowledged commands use the normal draft-clearing path")
            XCTAssertNil(model.panel)
            let oldAction = model.scopedRequest(for: model.state)
            model.text = "Unsent first-session draft"
            _ = try await client.request(.createSession(directory: directory))
            try await waitUntil { model.state.selected != first }
            do {
                _ = try await oldAction(.stop)
                XCTFail("Stale local action must not target the new session")
            } catch { XCTAssertEqual(error as? RemoteFault, .conflict) }
            XCTAssertEqual(try Data(contentsOf: accepted).count, 4)
            let second = try XCTUnwrap(model.state.selected)
            model.text = "Unsent second-session draft"
            await model.openSession(first)
            try await waitUntil { model.state.selected == first && model.state.phase == "idle" && model.text == "Unsent first-session draft" }
            XCTAssertEqual(model.state.messages.last?.text, "Shared state")
            await model.openSession(second)
            try await waitUntil { model.state.selected == second && model.state.phase == "idle" && model.text == "Unsent second-session draft" }
            XCTAssertEqual(try Data(contentsOf: accepted).count, 4, "Restoration must not replay prompts")
            model.text = "Busy switching check"; model.send()
            try await waitUntil { !model.sending && model.state.working }
            let switched = await model.openSession(first)
            XCTAssertFalse(switched)
            XCTAssertEqual(model.destination, .session(first), "Sidebar selection is independent of execution")
            XCTAssertEqual(model.state.selected, second)
            XCTAssertTrue(model.state.working, "Selecting a saved session must not stop active work")
            XCTAssertEqual(model.fault, .busy)
            model.stopWork()
            try await waitUntil { !model.state.working }
            model.text = "Unsent second-session draft"
            try await server.revoke(phoneID)
            try await waitUntil { connected.isEmpty }
        } catch {
            await client.disconnect(); await server.stop(); await model.shutdown(); throw error
        }
        await client.disconnect(); await server.stop(); await model.shutdown()
        let savedDrafts = try JSONDecoder().decode([UUID: String].self, from: try XCTUnwrap(defaults.data(forKey: "sessionDrafts")))
        XCTAssertTrue(savedDrafts.values.contains("Unsent first-session draft"))
        XCTAssertTrue(savedDrafts.values.contains("Unsent second-session draft"))
        let restartedSupport = root.appendingPathComponent("restarted-support")
        try FileManager.default.copyItem(at: support, to: restartedSupport)
        // Keep the original host lease intact while restoring a private copy of its catalog.
        let catalog = restartedSupport.appendingPathComponent("sessions.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
        try Data(json.replacingOccurrences(of: support.path, with: restartedSupport.path).utf8).write(to: catalog)
        defaults.set(executable.path, forKey: "piExecutable")
        let restarted = CompanionModel(support: restartedSupport, secrets: store, defaults: defaults)
        restarted.observe()
        do {
            let savedID = try XCTUnwrap(savedDrafts.first { $0.value == "Unsent second-session draft" }?.key)
            try await waitUntil { restarted.state.sessions.contains { $0.id == savedID } }
            await restarted.openSession(savedID)
            XCTAssertNil(restarted.fault)
            try await waitUntil { restarted.state.selected == savedID && restarted.state.phase == "idle" }
            XCTAssertEqual(restarted.text, "Unsent second-session draft", "A new model must restore the unsent draft from disk")
        } catch { await restarted.shutdown(); throw error }
        await restarted.shutdown()
    }

    func testWorkspacePersistenceGroupingRemovalAndInvalidPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left/project"), right = root.appendingPathComponent("right/project")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let marker = left.appendingPathComponent("keep.jsonl")
        try Data("saved-file-fixture".utf8).write(to: marker)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: left)
        let suite = "PiRemote.WorkspaceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CompanionModel(support: root.appendingPathComponent("support"), secrets: MemorySecrets(), defaults: defaults)
        let leftPath = left.resolvingSymlinksInPath().path, rightPath = right.resolvingSymlinksInPath().path
        try await model.addWorkspace(path: left.path)
        try await model.addWorkspace(path: alias.path)
        try await model.addWorkspace(path: right.path)
        XCTAssertEqual(model.workspaces.count, 2, "Aliases merge, but equal folder names do not")
        let host = try XCTUnwrap(model.coordinator)
        let untouched = await host.state()
        XCTAssertTrue(untouched.sessions.isEmpty)
        XCTAssertNil(untouched.selected, "Adding a workspace must not activate Pi")
        let first = UUID(), second = UUID(), other = UUID()
        model.state.sessions = [SessionInfo(id: first, title: "First", directory: leftPath),
                                SessionInfo(id: second, title: "Second", directory: leftPath),
                                SessionInfo(id: other, title: "Other", directory: rightPath)]
        XCTAssertEqual(model.workspaces.first(where: { $0.id == leftPath })?.sessions.count, 2)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == rightPath })?.sessions.count, 1)
        model.setExpanded(leftPath, expanded: true)
        model.destination = .session(first); model.destination = .settings
        model.inspectorVisible = true
        let restored = CompanionModel(support: root.appendingPathComponent("restored-support"), secrets: MemorySecrets(), defaults: defaults)
        XCTAssertEqual(restored.destination, .session(first))
        XCTAssertTrue(restored.inspectorVisible)
        XCTAssertTrue(restored.expandedWorkspaces.contains(leftPath))
        await restored.shutdown()
        model.removeWorkspace(leftPath)
        XCTAssertFalse(model.workspaces.contains(where: { $0.id == leftPath }))
        XCTAssertEqual(model.state.sessions.count, 3)
        XCTAssertEqual(try Data(contentsOf: marker), Data("saved-file-fixture".utf8))
        do { try await model.addWorkspace(path: root.appendingPathComponent("missing").path); XCTFail("Missing folder must fail") }
        catch { XCTAssertEqual(error as? RemoteFault, .staleDirectory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        do { try await model.addWorkspace(path: denied.path); XCTFail("Inaccessible folder must fail") }
        catch { XCTAssertEqual(error as? RemoteFault, .permissionDenied) }
        await model.shutdown()
    }
}

final class SessionDisplayNameTests: XCTestCase {
    @MainActor func testCompleteLiveTranscriptSuppliesInstructionWithoutRenaming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.DisplayNameTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = CompanionModel(support: root, secrets: MemorySecrets(), defaults: defaults)
        let session = SessionInfo(id: UUID(), title: "workspace", directory: "/tmp/workspace")
        model.state.sessions = [session]; model.state.selected = session.id
        model.state.messages = [TranscriptMessage(role: "user", text: " \n "),
                                TranscriptMessage(role: "user", text: " Fix\n session restoration ")]
        XCTAssertEqual(model.displayName(for: session), "Fix session restoration")
        XCTAssertEqual(model.state.sessions.first?.title, "workspace")
        model.state.hasOlderMessages = true
        XCTAssertTrue(model.displayName(for: session).hasPrefix("Session · "), "A bounded transcript must not invent the first instruction")
        await model.shutdown()
    }

    func testNamingPrecedenceAndExplicitDirectoryName() {
        let id = UUID()
        var session = SessionInfo(id: id, title: "workspace", directory: "/tmp/workspace")
        let hints = SessionDisplayMetadata(name: "Pi name", firstInstruction: "First instruction")
        XCTAssertEqual(SessionDisplayName.full(session, metadata: hints), "Pi name")
        session.title = "  Explicit\n title "
        XCTAssertEqual(SessionDisplayName.full(session, metadata: hints), "Explicit title")
        session.title = "workspace"
        XCTAssertEqual(SessionDisplayName.full(session, metadata: SessionDisplayMetadata(name: "workspace", firstInstruction: "First instruction")), "workspace")
        XCTAssertEqual(SessionDisplayName.full(session, metadata: SessionDisplayMetadata(firstInstruction: "  Fix\n tests  ")), "Fix tests")
        XCTAssertEqual(SessionDisplayName.full(session, metadata: nil), "Session · " + id.uuidString.lowercased().prefix(8))
        session.title = " \n "
        XCTAssertEqual(SessionDisplayName.full(session, metadata: hints), "Pi name")
    }

    func testConciseNamesAndWorkspaceScopedCollisions() {
        let first = SessionInfo(id: UUID(uuidString: "12345678-0000-0000-0000-000000000001")!, title: "Same", directory: "/tmp/one")
        var second = SessionInfo(id: UUID(uuidString: "87654321-0000-0000-0000-000000000002")!, title: "Same", directory: "/tmp/one")
        XCTAssertEqual(SessionDisplayName.resolve(first, sessions: [first, second], metadata: [:]), "Same · 12345678")
        XCTAssertEqual(SessionDisplayName.resolve(second, sessions: [second, first], metadata: [:]), "Same · 87654321")
        second.directory = "/tmp/two"
        XCTAssertEqual(SessionDisplayName.resolve(first, sessions: [first, second], metadata: [:]), "Same")
        var long = first
        long.title = String(repeating: "界", count: 100)
        XCTAssertEqual(SessionDisplayName.resolve(long, sessions: [long], metadata: [:]).count, 70)
        XCTAssertEqual(SessionDisplayName.full(long, metadata: nil).count, 100)
    }

    func testGeneratedSuffixCannotCollideWithExplicitThirdTitle() {
        let first = SessionInfo(id: UUID(uuidString: "12345678-0000-0000-0000-000000000001")!, title: "Same", directory: "/tmp/one")
        let second = SessionInfo(id: UUID(uuidString: "87654321-0000-0000-0000-000000000002")!, title: "Same", directory: first.directory)
        let third = SessionInfo(id: UUID(), title: "Same · 12345678", directory: first.directory)
        let sessions = [first, second, third]
        let labels = SessionDisplayName.labels(sessions: sessions, metadata: [:])
        XCTAssertEqual(Set(labels.values).count, 3)
        XCTAssertEqual(labels, SessionDisplayName.labels(sessions: Array(sessions.reversed()), metadata: [:]))
        XCTAssertTrue(labels.values.allSatisfy { $0.count <= 70 })
        XCTAssertEqual(Set(labels.keys), Set(sessions.map(\.id)))
    }

    func testTruncationCollisionsAndStablePrefixCollisions() {
        let first = SessionInfo(id: UUID(uuidString: "12345678-1000-0000-0000-000000000001")!, title: String(repeating: "a", count: 80), directory: "/tmp/one")
        var second = SessionInfo(id: UUID(uuidString: "12345678-2000-0000-0000-000000000002")!, title: first.title + "b", directory: first.directory)
        let left = SessionDisplayName.resolve(first, sessions: [first, second], metadata: [:])
        let right = SessionDisplayName.resolve(second, sessions: [first, second], metadata: [:])
        XCTAssertNotEqual(left, right)
        XCTAssertLessThanOrEqual(left.count, 70)
        XCTAssertLessThanOrEqual(right.count, 70)
        second.title = "Unique"
        XCTAssertFalse(SessionDisplayName.resolve(first, sessions: [first, second], metadata: [:]).contains(" · "))
    }
}
