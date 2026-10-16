import Foundation
@testable import PiRemoteClient
import PiRemoteConnection
import PiRemoteCore
@testable import PiRemoteHost
import PiRemoteSecurity
import Testing

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var deletionFails = false
    func failDeletion() { lock.withLock { deletionFails = true } }
    func get(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func put(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func remove(_ account: String) throws {
        try lock.withLock {
            if deletionFails { throw RemoteFault.storageFailure }
            values.removeValue(forKey: account)
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

@Test func directoryIDsRejectReplacementAndUnknownPaths() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    let registry = DirectoryRegistry()
    let id = try await registry.register(child)
    #expect(try await registry.resolve(id).url == child.resolvingSymlinksInPath())
    try FileManager.default.removeItem(at: child)
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.resolve(id) }
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.resolve(id) }
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.resolve(UUID()) }
}

@Test func directoryPaginationAndSymlinkSelectionAreBounded() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<205 {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d\(index)"), withIntermediateDirectories: false)
    }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("d0"))
    let registry = DirectoryRegistry()
    let id = try await registry.register(root)
    var cursor: UUID?
    var count = 0
    repeat {
        let page = try await registry.list(id: id, cursor: cursor)
        #expect(page.items.count <= 100)
        count += page.items.count; cursor = page.next
    } while cursor != nil
    #expect(count == 206)
    let aliasID = try await registry.register(alias)
    #expect(try await registry.resolve(aliasID).url == root.appendingPathComponent("d0").resolvingSymlinksInPath())
}

@Test func approvalIsLocalAndCredentialsSurviveRegistryRestart() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemorySecrets()
    let path = root.appendingPathComponent("devices.json")
    let registry = try DeviceRegistry(secrets: store, metadata: path)
    let grant = try await registry.openWindow()
    let device = UUID(), connection = UUID()
    _ = try await registry.request(connection: connection, device: device, name: "Phone", grant: grant)
    let nonce = try PairingProof.randomSecret()
    #expect(try await !registry.verify(device: device, nonce: nonce, proof: Data()))
    await #expect(throws: RemoteFault.expired) { try await registry.approve(connection: UUID()) }
    let credential = try await registry.approve(connection: connection)
    let reopened = try DeviceRegistry(secrets: store, metadata: path)
    #expect(try await reopened.verify(device: device, nonce: nonce, proof: DeviceProof.create(secret: credential, device: device, nonce: nonce)))
    try await reopened.revoke(device)
    #expect(try await !reopened.verify(device: device, nonce: nonce, proof: DeviceProof.create(secret: credential, device: device, nonce: nonce)))
}

@Test func oldEpochUnknownOutcomeAndPayloadConflictsCannotRedispatch() throws {
    let epoch = UUID(), device = UUID()
    var journal = RequestJournal(epoch: epoch)
    let request = AppRequest(epoch: epoch, session: nil, action: .stop)
    #expect(try journal.begin(device: device, request: request) == .dispatch)
    let persisted = try JSONEncoder().encode(journal)
    journal = try JSONDecoder().decode(RequestJournal.self, from: persisted)
    #expect(try journal.begin(device: device, request: request) == .unknown)
    journal.finish(device: device, request: request, fault: nil)
    #expect(try journal.begin(device: device, request: request) == .completed(nil))
    var changed = request; changed.action = .clone
    #expect(throws: RemoteFault.conflict) { try journal.begin(device: device, request: changed) }
    var old = request; old.epoch = UUID()
    #expect(throws: RemoteFault.unknownOutcome) { try journal.begin(device: device, request: old) }
}

@Test func finalMessagesReplaceDeltasAndAgentEndIsNotIdle() {
    var state = TranscriptReducer()
    state.consume(.object(["type": .string("agent_start")]))
    state.consume(.object(["type": .string("message_start"), "message": .object(["role": .string("assistant")])]))
    state.consume(.object(["type": .string("message_update"), "assistantMessageEvent": .object(["type": .string("text_delta"), "delta": .string("partial")])]))
    state.consume(.object(["type": .string("agent_end")]))
    #expect(state.phase == "working")
    state.consume(.object(["type": .string("message_end"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("authoritative")])])])]))
    #expect(state.messages.count == 1)
    #expect(state.messages[0].text == "authoritative")
    state.consume(.object(["type": .string("agent_settled")]))
    #expect(state.phase == "idle")
}

private func fakePi(at root: URL, hold: Bool = false) throws -> URL {
    let url = root.appendingPathComponent("fake-pi")
    let script = #"""
#!/bin/sh
if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
folder=''; session=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-dir) folder=$2; shift 2 ;;
        --session-id) session=$2; shift 2 ;;
        --session) file=$2; session=$(/usr/bin/basename "$file" .jsonl); shift 2 ;;
        *) shift ;;
    esac
done
file="$folder/$session.jsonl"
printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
streaming=false
thinking=off
reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
while IFS= read -r line; do
    id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    command=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    case "$command" in
        get_state) reply "{\"model\":{\"id\":\"fixture\",\"provider\":\"test\"},\"thinkingLevel\":\"$thinking\",\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":0,\"sessionId\":\"$session\",\"sessionFile\":\"$file\"}" ;;
        get_available_models) reply '{"models":[{"id":"fixture","provider":"test","name":"Fixture"}]}' ;;
        get_available_thinking_levels) reply '{"levels":["off","low"]}' ;;
        get_commands) reply '{"commands":[{"name":"ask","description":"Fixture dialog","source":"extension"}]}' ;;
        get_messages) reply '{"messages":[]}' ;;
        get_entries) reply '{"entries":[],"leafId":null}' ;;
        set_thinking_level) thinking=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"level":"\([^"]*\)".*/\1/p'); reply '{}' ;;
        prompt)
            case "$line" in
                *'/ask'*) pending=$id; printf '{"type":"extension_ui_request","id":"question-1","method":"confirm","title":"Fixture confirmation"}\n' ;;
                *)
                    printf x >> "$folder/accepted"
                    reply '{"disposition":"started"}'
                    printf '{"type":"agent_start"}\n{"type":"message_start","message":{"role":"assistant"}}\n{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"partial"}}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Fixture complete"}]}}\n{"type":"agent_end"}\n{"type":"agent_settled"}\n'
                    ;;
            esac ;;
        extension_ui_response)
            printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"disposition":"handled"}}\n' "$pending" ;;
        abort) streaming=false; reply '{}' ;;
        *) reply '{}' ;;
    esac
done
"""#
    let contents = hold ? script
        .replacingOccurrences(of: "reply '{\"disposition\":\"started\"}'", with: "streaming=true; reply '{\"disposition\":\"started\"}'")
        .replacingOccurrences(of: "\\n{\"type\":\"agent_settled\"}", with: "") : script
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

@Test(.timeLimit(.minutes(1))) func nativeHostDispatchIsDeduplicatedAndUsesSelectedDirectory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let support = root.appendingPathComponent("support")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let host = try HostCoordinator(support: support, executable: executable)
    do {
        let alias = root.appendingPathComponent("selected-folder")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let id = try await host.directories.register(alias)
        let device = UUID()
        let initial = await host.state()
        let result = await host.handle(AppRequest(epoch: initial.epoch, session: nil, action: .createSession(directory: id)), device: device)
        #expect(result == .ok)
        let state = await host.state()
        #expect(state.sessions.first?.directory == project.path)
        #expect(state.piVersion == "1.3.0")
        let request = AppRequest(epoch: state.epoch, session: state.selected, action: .prompt(text: "Fixture task", delivery: .prompt, image: nil))
        #expect(await host.handle(request, device: device) == .ok)
        #expect(await host.handle(request, device: device) == .ok)
        for _ in 0..<50 {
            let current = await host.state()
            if current.messages.last?.text == "Fixture complete", current.phase == "idle" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await host.state().messages.last?.text == "Fixture complete")
        let accepted = support.appendingPathComponent("pi-sessions/" + state.selected!.uuidString + "/accepted")
        #expect(try Data(contentsOf: accepted).count == 1)
        let file = try #require(FileManager.default.contentsOfDirectory(at: accepted.deletingLastPathComponent(), includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(#"{"type":"message","id":"saved","parentId":null,"message":{"role":"user","content":"Saved fixture"}}"#.utf8) + Data([10]))
        try writer.close()
        let pageResult = await host.handle(AppRequest(epoch: state.epoch, session: state.selected, action: .historyPage(cursor: nil)), device: device)
        guard case .historyPage(let page) = pageResult else { throw RemoteFault.invalidRequest }
        #expect(page.items.first?.id == "saved")
        let previewID = try #require(page.items.first?.preview)
        #expect(await host.handle(AppRequest(epoch: state.epoch, session: state.selected, action: .historyEntry(id: previewID)), device: device) == .preview(FilePreview(name: "message", text: "Saved fixture", truncated: false)))
        let lease = AuthorizationLease(); lease.revoke()
        #expect(await host.handle(AppRequest(epoch: state.epoch, session: state.selected, action: .clone), device: device, authorization: lease) == .failure(.unauthorized))
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1))) func productionPairingRequiresApprovalAndDialogsDoNotBlockTheSocket() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemorySecrets()
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root, hold: true))
    let registry = try DeviceRegistry(secrets: store, metadata: root.appendingPathComponent("devices.json"))
    let identity = try await ServerIdentity.load(secrets: store, support: root)
    let server = AppServer(coordinator: host, registry: registry)
    let client = RemoteClient(secrets: store)
    do {
        let port = try await server.start(identity: identity, address: "127.0.0.1", port: 0)
        var changedCertificate = identity.certificate
        changedCertificate[changedCertificate.count - 1] ^= 1
        let wrongPin = try PinnedChannel(url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: changedCertificate)
        await #expect(throws: (any Error).self) { try await wrongPin.receive(timeout: 5) }
        #expect(wrongPin.didRejectIdentity)
        wrongPin.close()
        let wrongHostname = try PinnedChannel(url: URL(string: "wss://localhost:\(port)/")!, certificate: identity.certificate)
        await #expect(throws: (any Error).self) { try await wrongHostname.receive(timeout: 5) }
        #expect(wrongHostname.didRejectIdentity)
        wrongHostname.close()
        let unauthenticated = try PinnedChannel(url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate)
        _ = try await unauthenticated.receive()
        try await unauthenticated.send(AppPacket(ClientMessage.request(AppRequest(epoch: host.epoch, session: nil, action: .directories(id: nil, cursor: nil)))).encode())
        let denied = try AppPacket<ServerMessage>.decode(await unauthenticated.receive()).payload
        guard case .denied = denied else { throw RemoteFault.invalidRequest }
        unauthenticated.close()
        let grant = try await server.openPairing()
        let code = PairingCode(host: host.hostID, name: "Fixture Mac", url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate, grant: grant, expires: Date().addingTimeInterval(120))
        let updates = await server.pairingUpdates()
        let pairing = Task { try await RemoteClient.pair(code: code, device: UUID(), name: "Fixture phone", secrets: store) }
        var approved = false
        for await candidate in updates {
            if let candidate { try await server.approve(candidate.id); approved = true; break }
        }
        #expect(approved)
        let mac = try await pairing.value
        try await client.connect(mac)
        guard case .directories(let page) = try await client.request(.directories(id: nil, cursor: nil)) else {
            throw RemoteFault.invalidRequest
        }
        #expect(!page.path.isEmpty)
        let folder = try await host.directories.register(root)
        let originalContext = await host.state().context
        var wrongContext = originalContext; wrongContext.host = UUID()
        await #expect(throws: RemoteFault.conflict) { try await client.request(.createSession(directory: folder), context: wrongContext) }
        wrongContext = originalContext; wrongContext.epoch = UUID()
        await #expect(throws: RemoteFault.conflict) { try await client.request(.createSession(directory: folder), context: wrongContext) }
        #expect(await host.state().sessions.isEmpty)
        _ = try await client.request(.createSession(directory: folder))
        await #expect(throws: RemoteFault.conflict) { try await client.request(.rename(name: "Stale session"), context: originalContext) }
        let command = Task { try await client.request(.command(name: "ask", arguments: "")) }
        for _ in 0..<100 {
            if await host.state().dialogs.first != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let dialog = try #require(await host.state().dialogs.first)
        let localRequest = AppRequest(epoch: host.epoch, session: await host.state().selected, action: .thinking(level: "low"))
        #expect(await host.handle(localRequest, device: UUID()) == .failure(.busy))
        _ = try await client.request(.answer(dialog: dialog.id, value: nil, confirmed: false, cancelled: true))
        #expect(try await command.value == .ok)
        _ = try await client.request(.prompt(text: "Keep working", delivery: .prompt, image: nil))
        for _ in 0..<100 {
            if await host.state().messages.last?.text == "Fixture complete" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await host.state()
        await client.disconnect()
        #expect(await host.state().working)
        try await client.connect(mac)
        guard case .snapshot(let restored) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
        #expect(restored.selected == before.selected && restored.messages == before.messages && restored.working)
        let accepted = root.appendingPathComponent("support/pi-sessions/" + restored.selected!.uuidString + "/accepted")
        #expect(try Data(contentsOf: accepted).count == 1)
        _ = try await client.request(.stop)
        let settled = await host.state()
        var newest = settled; newest.sequence += 10
        newest.messages = [TranscriptMessage(role: "assistant", text: "Authoritative fixture")]
        #expect(await client.apply(newest))
        var stale = settled; stale.messages = [TranscriptMessage(role: "assistant", text: "Stale fixture")]
        #expect(await client.apply(stale))
        let updatesAfterStale = await client.updates()
        var iterator = updatesAfterStale.makeAsyncIterator()
        guard case .state(let retained) = await iterator.next() else { throw RemoteFault.invalidRequest }
        #expect(retained == newest)
        var wrongEpoch = newest; wrongEpoch.epoch = UUID()
        #expect(await !client.apply(wrongEpoch))
        await #expect(throws: RemoteFault.unavailable) { try await client.request(.snapshot) }
        try await client.connect(mac)
        var wrongHost = settled; wrongHost.host = UUID()
        #expect(await !client.apply(wrongHost))
        await #expect(throws: RemoteFault.unavailable) { try await client.request(.snapshot) }
        try await server.revoke(mac.device)
        await #expect(throws: (any Error).self) { try await client.connect(mac) }
    } catch { await client.disconnect(); await server.stop(); await host.shutdown(); throw error }
    await client.disconnect(); await server.stop(); await host.shutdown()
}

@Test func concurrentSubmissionResultsPreserveUncertainty() {
    var state = SubmissionState()
    let first = UUID(), second = UUID()
    state.begin(first); state.begin(second)
    state.finish(first, fault: nil)
    #expect(state.needsReview)
    state.finish(second, fault: .unknownOutcome)
    #expect(state.uncertain && state.needsReview)
    state.reviewed()
    #expect(!state.needsReview)
    state.begin(first); state.finish(first, fault: .storageFailure)
    #expect(state.uncertain)
}

@Test func displayBudgetsUseUTF8BytesNotGraphemeCount() throws {
    let text = "x" + String(repeating: "\u{0301}", count: 100_000)
    var reducer = TranscriptReducer()
    reducer.replaceHistory((0..<200).map { _ in .object(["role": .string("assistant"), "content": .string(text)]) })
    #expect(reducer.omitted)
    #expect(reducer.messages.reduce(0, { $0 + $1.text.utf8.count }) <= 256 * 1_024)
    var state = HostSnapshot(host: UUID(), epoch: UUID()); state.messages = reducer.messages
    #expect(try AppPacket(ServerMessage.state(state)).encode().count < 4 * 1_024 * 1_024)
}

@Test(.timeLimit(.minutes(1))) func workingSessionCannotSwitchAndStopConfirmsIdle() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root, hold: true))
    do {
        let directory = try await host.directories.register(root)
        let device = UUID()
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let selected = await host.state().selected
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .prompt(text: "Hold", delivery: .prompt, image: nil)), device: device) == .ok)
        let changed = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device)
        #expect(changed == .failure(.busy))
        #expect(await host.state().selected == selected)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .stop), device: device) == .ok)
        #expect(await host.state().phase == "idle")
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test func instanceLeasePreventsConcurrentSessionWriters() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root, executable: URL(fileURLWithPath: "/does-not-exist"))
    #expect(throws: RemoteFault.conflict) { try HostCoordinator(support: root, executable: URL(fileURLWithPath: "/does-not-exist")) }
    await host.shutdown()
}

@Test func unreadableAndLargeFilesFailOrTruncateWithoutEscapingIDs() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = DirectoryRegistry()
    let file = root.appendingPathComponent("large.txt")
    try String(repeating: "日本語", count: 100_000).write(to: file, atomically: true, encoding: .utf8)
    let fileID = try await registry.register(file)
    let preview = try await registry.preview(fileID)
    #expect(preview.truncated && preview.text.utf8.count <= 256 * 1_024)
    let directoryID = try await registry.register(root)
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.preview(directoryID) }
    try Data([0, 1, 2]).write(to: file)
    let binaryID = try await registry.register(file)
    await #expect(throws: RemoteFault.unsupportedFeature) { try await registry.preview(binaryID) }
}

@Test func inaccessibleFoldersAndBrokenLinksAreReported() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
    let registry = DirectoryRegistry()
    let id = try await registry.register(root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("missing"))
    let loop = root.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
    let page = try await registry.list(id: id, cursor: nil)
    #expect(page.items.first(where: { $0.name == "broken" })?.fault == .staleDirectory)
    #expect(page.items.first(where: { $0.name == "loop" })?.fault == .staleDirectory)
    await #expect(throws: RemoteFault.staleDirectory) { try await registry.register(loop) }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    await #expect(throws: RemoteFault.permissionDenied) { try await registry.list(id: id, cursor: nil) }
}

@Test func revokedDeviceStaysDeniedWhenSecretDeletionFails() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemorySecrets()
    let metadata = root.appendingPathComponent("devices.json")
    let registry = try DeviceRegistry(secrets: store, metadata: metadata)
    let device = UUID(), connection = UUID()
    let grant = try await registry.openWindow()
    _ = try await registry.request(connection: connection, device: device, name: "Phone", grant: grant)
    let credential = try await registry.approve(connection: connection)
    store.failDeletion()
    await #expect(throws: RemoteFault.storageFailure) { try await registry.revoke(device) }
    let nonce = try PairingProof.randomSecret()
    let proof = DeviceProof.create(secret: credential, device: device, nonce: nonce)
    #expect(try await !registry.verify(device: device, nonce: nonce, proof: proof))
    let reopened = try DeviceRegistry(secrets: store, metadata: metadata)
    #expect(try await !reopened.verify(device: device, nonce: nonce, proof: proof))
}

@Test func removedSelectionCannotLaunchPi() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root))
    let id = try await host.directories.register(project)
    try FileManager.default.removeItem(at: project)
    let result = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: id)), device: UUID())
    #expect(result == .failure(.staleDirectory))
    #expect(await host.state().sessions.isEmpty)
    await host.shutdown()
}

@Test(arguments: ["unknown", "file", "removed", "replaced", "unreadable", "unsearchable"])
func rejectedDirectorySelectionNeverLaunchesPi(reason: String) async throws {
    let root = try temporaryDirectory()
    let project = root.appendingPathComponent("project")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let executable = root.appendingPathComponent("must-not-start")
    let marker = root.appendingPathComponent("launched")
    try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        var id = try await host.directories.register(project)
        var fault = RemoteFault.staleDirectory
        switch reason {
        case "unknown": id = UUID()
        case "file":
            let file = root.appendingPathComponent("file")
            try Data().write(to: file); id = try await host.directories.register(file)
        case "removed": try FileManager.default.removeItem(at: project)
        case "replaced":
            try FileManager.default.moveItem(at: project, to: root.appendingPathComponent("original"))
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        default:
            try FileManager.default.setAttributes([.posixPermissions: reason == "unreadable" ? 0o100 : 0o400], ofItemAtPath: project.path)
            fault = .permissionDenied
        }
        let result = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: id)), device: UUID())
        #expect(result == .failure(fault))
        #expect(await host.state().sessions.isEmpty)
        #expect(await host.state().selected == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test func directoryRequestsCannotCarryTraversalPaths() throws {
    let id = UUID()
    for action in [SessionAction.createSession(directory: id), .directories(id: id, cursor: nil)] {
        let request = AppRequest(epoch: UUID(), session: nil, action: action)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let malformed = encoded.replacingOccurrences(of: id.uuidString, with: "../../outside")
        #expect(encoded != malformed)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AppRequest.self, from: Data(malformed.utf8)) }
    }
}

@Test(.timeLimit(.minutes(1))) func lostDirectoryPermissionsRejectResumeBeforeProcessReplacement() async throws {
    let root = try temporaryDirectory()
    let project = root.appendingPathComponent("project")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let executable = try fakePi(at: root)
    let marker = root.appendingPathComponent("launches")
    let script = try String(contentsOf: executable, encoding: .utf8)
    try script.replacingOccurrences(of: "folder=''; session=''", with: "printf x >> '\(marker.path)'\nfolder=''; session=''")
        .write(to: executable, atomically: true, encoding: .utf8)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        let id = try await host.directories.register(project)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: id)), device: UUID()) == .ok)
        let state = await host.state()
        let session = try #require(state.selected)
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: project.path)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .resumeSession(id: session)), device: UUID()) == .failure(.permissionDenied))
        #expect(try Data(contentsOf: marker).count == 1)
        #expect(await host.state().selected == session)
        #expect(await host.state().phase == "idle")
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["shutdown", "version"])
func directoryReplacementDuringActivationCannotStartRPC(phase: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let marker = root.appendingPathComponent("activation-paused")
    let gate = root.appendingPathComponent("delay-activation")
    let launches = root.appendingPathComponent("rpc-launches")
    let pause = "if [ -e '\(gate.path)' ]; then /usr/bin/touch '\(marker.path)'; /bin/sleep 0.3; fi"
    var script = try String(contentsOf: executable, encoding: .utf8)
    script = script.replacingOccurrences(of: "folder=''; session=''", with: "printf x >> '\(launches.path)'\nfolder=''; session=''")
    if phase == "shutdown" { script += "\n" + pause + "\n" }
    else { script = script.replacingOccurrences(of: "then printf '1.3.0", with: "then \(pause); printf '1.3.0") }
    try script.write(to: executable, atomically: true, encoding: .utf8)
    let target = root.appendingPathComponent("next-project")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        let first = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: first)), device: UUID()) == .ok)
        let next = try await host.directories.register(target)
        try Data().write(to: gate)
        let activation = Task {
            await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: next)), device: UUID())
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        await #expect(throws: RemoteFault.busy) { try await host.setExecutable(root.appendingPathComponent("different-pi")) }
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("moved-project"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(await activation.value == .failure(.staleDirectory))
        #expect(try Data(contentsOf: launches).count == 1)
        #expect(await host.state().phase == "unavailable")
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1))) func sessionRestartPreservesDirectoryAndRejectsChangedHeader() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let support = root.appendingPathComponent("support")
    func create() async throws -> SessionInfo {
        let host = try HostCoordinator(support: support, executable: executable)
        let directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: UUID()) == .ok)
        let session = try #require(await host.state().sessions.first)
        await host.shutdown()
        return session
    }
    let session = try await create()
    func resume() async throws {
        let host = try HostCoordinator(support: support, executable: executable)
        #expect(await host.state().selected == nil)
        let savedFile = support.appendingPathComponent("pi-sessions/" + session.id.uuidString + "/" + session.id.uuidString + ".jsonl")
        let firstLine = try #require(Data(contentsOf: savedFile).split(separator: 10).first)
        let header = try JSONDecoder().decode(JSONValue.self, from: Data(firstLine))
        #expect(header["id"]?.string == session.id.uuidString)
        let cwd = try #require(header["cwd"]?.string)
        let headerDirectory = try DirectoryRegistry.identify(URL(fileURLWithPath: cwd))
        let expectedDirectory = try DirectoryRegistry.identify(root)
        #expect(headerDirectory == expectedDirectory)
        let result = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .resumeSession(id: session.id)), device: UUID())
        #expect(result == .ok)
        #expect(await host.state().sessions.first?.directory == session.directory)
        await host.shutdown()
    }
    try await resume()
    let folder = support.appendingPathComponent("pi-sessions/" + session.id.uuidString)
    let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
    let alias = root.appendingPathComponent("same-directory-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let aliasIdentity = try DirectoryRegistry.identify(alias), originalIdentity = try DirectoryRegistry.identify(root)
    #expect(aliasIdentity == originalIdentity)
    let initialHeader = try String(contentsOf: file, encoding: .utf8)
    try initialHeader.replacingOccurrences(of: session.directory, with: alias.path).write(to: file, atomically: true, encoding: .utf8)
    try await resume()
    let header = try String(contentsOf: file, encoding: .utf8)
    try header.replacingOccurrences(of: session.directory, with: "/wrong-directory").write(to: file, atomically: true, encoding: .utf8)
    let host = try HostCoordinator(support: support, executable: executable)
    let result = await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .resumeSession(id: session.id)), device: UUID())
    #expect(result == .failure(.incompatiblePi))
    await host.shutdown()
}

@Test func replayIsContiguousAndExpiredOrChangedEpochUsesSnapshot() {
    var replay = StateReplay()
    var current = HostSnapshot(host: UUID(), epoch: UUID())
    for sequence in 1...40 { current.sequence = UInt64(sequence); replay.append(current) }
    let sync = replay.synchronize(current: current, epoch: current.epoch, after: 35)
    #expect(sync.snapshot == nil && sync.events.map(\.sequence) == [36, 37, 38, 39, 40])
    #expect(replay.synchronize(current: current, epoch: current.epoch, after: 1).snapshot == current)
    #expect(replay.synchronize(current: current, epoch: UUID(), after: 35).snapshot == current)
    #expect(replay.synchronize(current: current, epoch: current.epoch, after: 41).snapshot == current)
    current.sequence = 41
    current.draft = String(repeating: "x", count: 3 * 1_024 * 1_024)
    replay.append(current)
    #expect(replay.synchronize(current: current, epoch: current.epoch, after: 40).snapshot == current)
}

@Test(.timeLimit(.minutes(1))) func utilityCancellationDoesNotWaitForInheritedPipes() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("hold-pipe")
    try "#!/bin/sh\n/bin/sleep 4 &\nwait\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let start = ContinuousClock.now
    let operation = Task { try await LocalCommand.run(script.path, [], directory: root) }
    try await Task.sleep(for: .milliseconds(100))
    operation.cancel()
    await #expect(throws: RemoteFault.cancelled) { try await operation.value }
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test(.timeLimit(.minutes(1))) func oversizedDialogsCannotBeApprovedAndExpiredAnswersAreRejected() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let script = try String(contentsOf: executable, encoding: .utf8)
    try script.replacingOccurrences(of: "\"title\":\"Fixture confirmation\"", with: "\"title\":\"" + String(repeating: "x", count: 600) + "\",\"timeout\":1000")
        .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    let device = UUID(), directory = try await host.directories.register(root)
    #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
    let selected = await host.state().selected
    let command = Task { await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .command(name: "ask", arguments: "")), device: device) }
    for _ in 0..<100 {
        if await host.state().dialogs.first != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let dialog = try #require(await host.state().dialogs.first)
    #expect(dialog.method == "unavailable")
    #expect(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false)), device: device) == .failure(.tooLarge))
    try await Task.sleep(for: .milliseconds(1100))
    #expect(await host.state().dialogs.isEmpty)
    #expect(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .answer(dialog: dialog.id, value: nil, confirmed: true, cancelled: false)), device: device) == .failure(.expired))
    await host.shutdown()
    _ = await command.value
}

@Test func corruptPrivateMetadataFailsClosed() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing.json")
    #expect(try PrivateFiles.read(UUID.self, from: missing) == nil)
    let broken = root.appendingPathComponent("broken.json")
    try Data("not JSON".utf8).write(to: broken)
    #expect(throws: RemoteFault.storageFailure) { try PrivateFiles.read(UUID.self, from: broken) }
    let alias = root.appendingPathComponent("alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: broken)
    #expect(throws: RemoteFault.storageFailure) { try PrivateFiles.read(UUID.self, from: alias) }
}

@Test func protocolRoundTripsAndRejectsUnknownVersions() throws {
    let id = UUID(), epoch = UUID()
    let actions: [SessionAction] = [
        .snapshot, .synchronize(epoch: epoch, after: 4), .directories(id: id, cursor: UUID()),
        .preview(id: id), .createSession(directory: id), .resumeSession(id: id),
        .prompt(text: "Hello 日本語", delivery: .prompt, image: ImageAttachment(data: Data([1, 2]), mimeType: "image/png")),
        .prompt(text: "Steer", delivery: .steer, image: nil), .prompt(text: "Next", delivery: .followUp, image: nil),
        .stop, .model(provider: "test", id: "fixture"), .thinking(level: "low"), .compact(instructions: "Summarize"),
        .rename(name: "A session"), .history, .historyPage(cursor: id), .historyEntry(id: id), .fork(entry: "entry"), .clone, .command(name: "ask", arguments: "test"),
        .answer(dialog: "question", value: "one", confirmed: nil, cancelled: false), .diff
    ]
    for action in actions {
        let request = AppRequest(epoch: epoch, session: id, action: action)
        guard case .request(let decoded) = try AppPacket<ClientMessage>.decode(AppPacket(ClientMessage.request(request)).encode()).payload else {
            Issue.record("Wrong payload"); continue
        }
        #expect(decoded == request)
    }
    let state = HostSnapshot(host: id, epoch: epoch)
    let results: [AppResult] = [.ok, .failure(.unknownOutcome), .snapshot(state),
                                .synchronized(StateSync(events: [state])), .history([]), .historyPage(HistoryPage(items: [], next: id)),
                                .directories(DirectoryPage(id: id, path: "/", parent: nil, items: [], next: nil)),
                                .preview(FilePreview(name: "test", text: "content", truncated: true))]
    for result in results {
        let message = ServerMessage.reply(id: id, result: result, state: state)
        guard case .reply(let decodedID, let decoded, let decodedState) = try AppPacket<ServerMessage>.decode(AppPacket(message).encode()).payload else {
            Issue.record("Wrong reply"); continue
        }
        #expect(decodedID == id && decoded == result && decodedState == state)
    }
    #expect(throws: RemoteFault.unsupportedVersion) {
        try AppPacket<ClientMessage>.decode(AppPacket(ClientMessage.request(AppRequest(epoch: epoch, session: nil, action: .snapshot)), version: 2).encode())
    }
}
