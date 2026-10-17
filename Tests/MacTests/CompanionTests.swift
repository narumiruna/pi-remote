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
        *) shift ;;
    esac
done
file="$folder/$session.jsonl"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
streaming=false
reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
while IFS= read -r line; do
    id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    command=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    case "$command" in
        get_state) reply "{\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0,\"sessionId\":\"$session\",\"sessionFile\":\"$file\"}" ;;
        get_available_models) reply '{"models":[]}' ;;
        get_available_thinking_levels) reply '{"levels":["off","low"]}' ;;
        get_commands) reply '{"commands":[{"name":"ask","source":"extension"}]}' ;;
        get_messages) reply '{"messages":[]}' ;;
        new_session) session=$(/usr/bin/uuidgen); file="$folder/$session.jsonl"; streaming=false; printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"; reply '{"cancelled":false}' ;;
        prompt)
            case "$line" in
                *'/ask'*) pending=$id; printf '{"type":"extension_ui_request","id":"local-question","method":"confirm","title":"Test confirmation"}\n' ;;
                *) printf x >> "$folder/accepted"; streaming=true; reply '{"disposition":"started"}'; printf '{"type":"agent_start"}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Shared state"}]}}\n' ;;
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
            let mac = try await client.pair(code: code, device: UUID(), name: "Fixture phone")
            try await approval.value
            try await client.connect(mac)
            let directory = try await host.directories.register(root)
            _ = try await model.request(.createSession(directory: directory))
            try await waitUntil { model.state.selected != nil }
            let first = try XCTUnwrap(model.state.selected)
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
            XCTAssertEqual(try Data(contentsOf: accepted).count, 3)
            model.stopWork()
            try await waitUntil { !model.state.working }
            guard case .snapshot(let stopped) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
            XCTAssertFalse(stopped.working)
            XCTAssertEqual(stopped.selected, first)

            // A local extension command waits for its dialog response while a
            // remote mutation must observe the same coordinator's busy gate.
            let command = Task { try await model.request(.command(name: "ask", arguments: "")) }
            try await waitUntil { model.state.dialogs.first != nil }
            do {
                _ = try await client.request(.thinking(level: "low"))
                XCTFail("Remote mutation must not bypass the local command")
            } catch { XCTAssertEqual(error as? RemoteFault, .busy) }
            let dialog = try XCTUnwrap(model.state.dialogs.first)
            _ = try await client.request(.answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false))
            _ = try await command.value
            try await waitUntil { model.state.dialogs.isEmpty }
            XCTAssertNil(model.panel)
            let oldAction = model.scopedRequest(for: model.state)
            _ = try await client.request(.createSession(directory: directory))
            try await waitUntil { model.state.selected != first }
            do {
                _ = try await oldAction(.stop)
                XCTFail("Stale local action must not target the new session")
            } catch { XCTAssertEqual(error as? RemoteFault, .conflict) }
            XCTAssertEqual(try Data(contentsOf: accepted).count, 3)
        } catch {
            await client.disconnect(); await server.stop(); await model.shutdown(); throw error
        }
        await client.disconnect(); await server.stop(); await model.shutdown()
    }
}
