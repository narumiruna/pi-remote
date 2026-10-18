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

@Test func directoryParentNavigationStopsAtRoot() async throws {
    let registry = DirectoryRegistry()
    var page = try await registry.list(id: nil, cursor: nil)
    for _ in 0..<32 {
        guard let parent = page.parent else { break }
        page = try await registry.list(id: parent, cursor: nil)
    }
    #expect(page.path == "/")
    #expect(page.parent == nil)
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

private func waitForHost(_ host: HostCoordinator, _ matches: (HostSnapshot) -> Bool) async throws {
    for _ in 0..<200 {
        if matches(await host.state()) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RemoteFault.unavailable
}

@Test(.timeLimit(.minutes(1))) func hostEventOverflowKeepsChildControlUntilExplicitStopAndNeverReplaysWork() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root), directories: DirectoryRegistry(), rpcEventCapacity: 1)
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        func send(_ action: SessionAction) async -> AppResult {
            await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
        }
        #expect(await send(.createSession(directory: directory)) == .ok)
        let session = try #require(await host.state().selected)
        let folder = support.appendingPathComponent("pi-sessions/" + session.uuidString)
        let pid = try #require(Int32(String(contentsOf: folder.appendingPathComponent("rpc-pid"), encoding: .utf8)))
        #expect(await send(.command(name: "metadata", arguments: "flood")) == .ok)
        try await waitForHost(host) { $0.phase == "recovering" && $0.notices.contains(where: { $0.contains("history was refreshed") }) }
        #expect(kill(pid, 0) == 0)
        guard case .statistics = await send(.statistics) else { Issue.record("Child commands must survive event loss"); await host.shutdown(); return }
        #expect(await send(.cycleModel) == .failure(.busy))
        #expect(await send(.stop) == .ok)
        #expect(await host.state().phase == "interrupted")
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(await host.state().sessions.first(where: { $0.id == session })?.interrupted == true)
        #expect(await send(.resumeSession(id: session)) == .ok)
        #expect(await host.state().phase == "idle")
        #expect(try String(contentsOf: folder.appendingPathComponent("flood-runs"), encoding: .utf8) == "F")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("accepted").path))
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func manualCompactionFailureSettlesAndAutomaticCompletionRefreshesHistory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        func send(_ action: SessionAction) async -> AppResult {
            await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
        }
        #expect(await send(.createSession(directory: directory)) == .ok)
        #expect(await send(.compact(instructions: "")) == .failure(.invalidRequest))
        try await waitForHost(host) { !$0.working && $0.messages.contains(where: { $0.isError && $0.text == "Private compaction failure" }) }
        #expect(await send(.cycleModel) == .ok)
        #expect(await send(.command(name: "metadata", arguments: "auto-compact")) == .ok)
        try await waitForHost(host) { !$0.working && $0.messages.contains(where: { $0.text == "Compacted fixture" }) }
        #expect(await host.state().phase == "idle")
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func automaticHistoryRefreshRetriesASupersededRunOnlyOnce() async throws {
    for mode in ["once", "always", "custom"] {
        let root = try temporaryDirectory()
        let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root))
        do {
            let device = UUID(), directory = try await host.directories.register(root)
            func send(_ action: SessionAction) async -> AppResult {
                await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
            }
            #expect(await send(.createSession(directory: directory)) == .ok)
            let session = try #require(await host.state().selected)
            #expect(await send(.command(name: "metadata", arguments: "refresh-race-" + mode)) == .ok)
            let count = root.appendingPathComponent("support/pi-sessions/" + session.uuidString + "/refresh-reads")
            for _ in 0..<200 {
                if (try? Data(contentsOf: count).count) == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try Data(contentsOf: count).count == 2)
            if mode != "always" {
                let text = mode == "custom" ? "Visible custom message" : "Current refreshed history"
                try await waitForHost(host) { $0.messages.contains { $0.text == text } }
                #expect(await host.state().messages.filter { $0.text == text }.count == 1)
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(try Data(contentsOf: count).count == 2)
            #expect(await host.state().phase == "idle")
            await host.shutdown()
            try FileManager.default.removeItem(at: root)
        } catch { await host.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

@Test(.timeLimit(.minutes(1))) func explicitQueuesRejectCommandsAndCannotStartARunAfterSettlement() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root, hold: true))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        func send(_ action: SessionAction) async -> AppResult {
            await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
        }
        #expect(await send(.createSession(directory: directory)) == .ok)
        let session = try #require(await host.state().selected)
        #expect(await send(.prompt(text: "Synthetic active run", delivery: .prompt, image: nil)) == .ok)
        try await waitForHost(host) { $0.phase == "working" }
        #expect(await send(.prompt(text: "/ask", delivery: .steer, image: nil)) == .failure(.invalidRequest))
        #expect(await host.state().dialogs.isEmpty)
        let command = Task { await send(.command(name: "ask", arguments: "")) }
        try await waitForHost(host) { !$0.dialogs.isEmpty }
        let dialog = try #require(await host.state().dialogs.first)
        #expect(await send(.answer(dialog: dialog.id, value: nil, confirmed: nil, cancelled: true)) == .ok)
        #expect(await command.value == .ok)
        #expect(await send(.prompt(text: "consume", delivery: .followUp, image: nil)) == .ok)
        #expect(await host.state().pendingMessages == 0)
        #expect(await send(.prompt(text: "race", delivery: .steer, image: nil)) == .ok)
        try await waitForHost(host) { $0.phase == "queued" && $0.pendingMessages == 1 }
        #expect(await host.state().sessions.first(where: { $0.id == session })?.interrupted == true)
        let folder = support.appendingPathComponent("pi-sessions/" + session.uuidString)
        #expect(try Data(contentsOf: folder.appendingPathComponent("accepted")).count == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("queue-wire"), encoding: .utf8) == "steer\nfollow_up\nsteer\n")
        #expect(await send(.stop) == .ok)
        try await waitForHost(host) { $0.phase == "idle" && $0.pendingMessages == 0 }
        #expect(try Data(contentsOf: folder.appendingPathComponent("accepted")).count == 1)
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func sessionNamesUseCoreReadBackAndHandleClearingEvents() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        func send(_ action: SessionAction) async -> AppResult {
            await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
        }
        #expect(await send(.createSession(directory: directory)) == .ok)
        let session = try #require(await host.state().selected)
        #expect(await send(.rename(name: "  Normalized fixture  ")) == .ok)
        #expect(await host.state().sessions.first(where: { $0.id == session })?.title == "Normalized fixture")
        #expect(await send(.closeSession) == .ok)
        #expect(await send(.resumeSession(id: session)) == .ok)
        #expect(await host.state().sessions.first(where: { $0.id == session })?.title == "Normalized fixture")
        #expect(await send(.command(name: "metadata", arguments: "clear-name")) == .ok)
        try await waitForHost(host) { $0.sessions.first(where: { $0.id == session })?.title == root.lastPathComponent }
        #expect(await send(.command(name: "metadata", arguments: "thinking")) == .ok)
        try await waitForHost(host) { $0.thinking == "low" }
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func standardStatusAndWidgetKeysHaveIndependentReplacementAndClearing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        func send(_ action: SessionAction) async -> AppResult {
            await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
        }
        #expect(await send(.createSession(directory: directory)) == .ok)
        #expect(await send(.command(name: "metadata", arguments: "status")) == .ok)
        try await waitForHost(host) { $0.notices.contains("Status fixture") && $0.notices.contains("Widget fixture") }
        #expect(await send(.command(name: "metadata", arguments: "clear-status")) == .ok)
        try await waitForHost(host) { !$0.notices.contains("Status fixture") && $0.notices.contains("Widget fixture") }
        #expect(await send(.command(name: "metadata", arguments: "clear-widget")) == .ok)
        try await waitForHost(host) { $0.notices.isEmpty }
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func extensionFailuresAndUnknownUIRequestsDoNotExposePathsOrApproveDialogs() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        func send(_ action: SessionAction) async -> AppResult {
            await host.handle(AppRequest(epoch: host.epoch, session: await host.state().selected, action: action), device: device)
        }
        #expect(await send(.createSession(directory: directory)) == .ok)
        #expect(await send(.command(name: "metadata", arguments: "extension-error")) == .ok)
        try await waitForHost(host) { $0.error == .unsupportedFeature }
        var state = await host.state()
        #expect(state.messages.isEmpty && state.dialogs.isEmpty && state.phase == "idle")
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("private-extension-error"))
        #expect(await send(.command(name: "metadata", arguments: "unknown-ui")) == .ok)
        // The following correlated query is a barrier after the finite unknown event.
        guard case .statistics = await send(.statistics) else { Issue.record("Missing state barrier"); await host.shutdown(); return }
        state = await host.state()
        #expect(state.messages.isEmpty && state.dialogs.isEmpty && state.notices.isEmpty)
        #expect(state.phase == "idle")
        let session = try #require(state.selected)
        let answers = root.appendingPathComponent("support/pi-sessions/" + session.uuidString + "/answers")
        #expect(!FileManager.default.fileExists(atPath: answers.path))
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func coreCyclingAndRetryControlsAreDeduplicatedAndProcessScoped() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = try #require(await host.state().selected)
        #expect(await host.state().runtime?.acknowledgedAutoRetry == nil)
        for action in [SessionAction.cycleModel, .cycleThinking, .autoRetry(enabled: false), .autoRetry(enabled: true), .abortRetry] {
            let request = AppRequest(epoch: host.epoch, session: session, action: action)
            #expect(await host.handle(request, device: device) == .ok)
            #expect(await host.handle(request, device: device) == .ok)
        }
        #expect(await host.state().thinking == "low")
        #expect(await host.state().model == "test/fixture")
        #expect(await host.state().runtime?.acknowledgedAutoRetry == true)
        let refreshed = await host.handle(AppRequest(epoch: host.epoch, session: session, action: .runtimeSettings), device: device)
        guard case .runtimeSettings(let value) = refreshed else { Issue.record("Missing runtime settings"); await host.shutdown(); return }
        #expect(value.acknowledgedAutoRetry == true)
        #expect(try String(contentsOf: support.appendingPathComponent("pi-sessions/" + session.uuidString + "/core-controls"), encoding: .utf8) == "MTDEA")
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: UUID(), action: .autoRetry(enabled: false)), device: device) == .failure(.conflict))
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .closeSession), device: device) == .ok)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .resumeSession(id: session)), device: device) == .ok)
        #expect(await host.state().runtime?.acknowledgedAutoRetry == nil)
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func rejectedRetrySetterCannotInventAnAcknowledgement() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let source = try String(contentsOf: executable, encoding: .utf8)
    let marker = "set_auto_retry) case"
    let start = try #require(source.range(of: marker)?.lowerBound)
    let end = try #require(source[start...].firstIndex(of: "\n"))
    let line = String(source[start..<end])
    let replacement = "set_auto_retry) printf '{\"id\":\"%s\",\"type\":\"response\",\"command\":\"set_auto_retry\",\"success\":false,\"error\":\"Rejected fixture setting\"}\\n' \"$id\" ;;"
    try source.replacingOccurrences(of: line, with: replacement).write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = try #require(await host.state().selected)
        let request = AppRequest(epoch: host.epoch, session: session, action: .autoRetry(enabled: true))
        #expect(await host.handle(request, device: device) == .failure(.invalidRequest))
        #expect(await host.handle(request, device: device) == .failure(.invalidRequest))
        #expect(await host.state().runtime?.acknowledgedAutoRetry == nil)
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func retryCancellationBypassesPendingMutationsButDoesNotAnswerDialogs() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root, hold: true))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = try #require(await host.state().selected)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .prompt(text: "Synthetic work", delivery: .prompt, image: nil)), device: device) == .ok)
        for action in [SessionAction.cycleModel, .cycleThinking, .autoRetry(enabled: true)] {
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: action), device: device) == .failure(.busy))
        }
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .abortRetry), device: device) == .ok)
        for _ in 0..<100 { if await !host.state().working { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await !host.state().working)
        let command = Task { await host.handle(AppRequest(epoch: host.epoch, session: session, action: .command(name: "ask", arguments: "")), device: device) }
        for _ in 0..<100 { if await !host.state().dialogs.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        let dialog = try #require(await host.state().dialogs.first)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .abortRetry), device: device) == .ok)
        #expect(await host.state().dialogs.first?.id == dialog.id)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .answer(dialog: dialog.id, value: nil, confirmed: nil, cancelled: true)), device: device) == .ok)
        #expect(await command.value == .ok)
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

func fakePi(at root: URL, hold: Bool = false, image: Data? = nil) throws -> URL {
    let url = root.appendingPathComponent("fake-pi")
    let script = #"""
#!/bin/sh
if [ "${1:-}" = --version ]; then printf '1.3.0\n'; exit 0; fi
folder=''; session=''; file=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-dir) folder=$2; shift 2 ;;
        --session-id) session=$2; shift 2 ;;
        --session) file=$2; session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -); shift 2 ;;
        *) shift ;;
    esac
done
if [ -z "$file" ]; then
    file="$folder/$session.jsonl"
    printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
fi
/bin/pwd -P > "$folder/observed-cwd"
printf '%s' "$$" > "$folder/rpc-pid"
messages='[]'
historyRace=none
streaming=false
thinking=off
steering=one-at-a-time
followup=one-at-a-time
compaction=true
queueCount=0
queuedSteering='[]'
queuedFollow='[]'
namejson=null
namefile="$folder/$session-name.json"
if [ -f "$namefile" ]; then namejson=$(/usr/bin/head -c 4096 "$namefile"); fi
reply() { printf '{"id":"%s","type":"response","command":"%s","success":true,"data":%s}\n' "$id" "$command" "$1"; }
while IFS= read -r line; do
    id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    command=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    case "$command" in
        get_state) reply "{\"model\":{\"id\":\"fixture\",\"provider\":\"test\"},\"thinkingLevel\":\"$thinking\",\"steeringMode\":\"$steering\",\"followUpMode\":\"$followup\",\"autoCompactionEnabled\":$compaction,\"isStreaming\":$streaming,\"isCompacting\":false,\"pendingMessageCount\":$queueCount,\"sessionName\":$namejson,\"sessionId\":\"$session\",\"sessionFile\":\"$file\"}" ;;
        new_session)
            session=$(/usr/bin/uuidgen); file="$folder/$session.jsonl"; messages='[]'; namejson=null
            parent=$(printf '%s' "$line" | /usr/bin/plutil -extract parentSession raw -o - - 2>/dev/null) || parent=''
            if [ -n "$parent" ]; then ancestry=",\"parentSession\":\"$parent\""; else ancestry=''; fi
            printf '{"type":"session","version":3,"id":"%s","cwd":"%s"%s}\n' "$session" "$PWD" "$ancestry" > "$file"
            namefile="$folder/$session-name.json"
            reply '{"cancelled":false}' ;;
        switch_session)
            file=$(printf '%s' "$line" | /usr/bin/plutil -extract sessionPath raw -o - -)
            session=$(/usr/bin/head -1 "$file" | /usr/bin/plutil -extract id raw -o - -)
            folder=$(/usr/bin/dirname "$file"); messages='[]'; namejson=null
            namefile="$folder/$session-name.json"
            if [ -f "$namefile" ]; then namejson=$(/usr/bin/head -c 4096 "$namefile"); fi
            reply '{"cancelled":false}' ;;
        get_available_models) reply '{"models":[{"id":"fixture","provider":"test","name":"Fixture"}]}' ;;
        get_available_thinking_levels) reply '{"levels":["off","low"]}' ;;
        get_commands) reply '{"commands":[{"name":"ask","description":"Fixture dialog","source":"extension"},{"name":"metadata","description":"Fixture metadata","source":"extension"}]}' ;;
        get_messages)
            if [ "$historyRace" = once ] || [ "$historyRace" = always ] || [ "$historyRace" = custom ]; then
                printf R >> "$folder/refresh-reads"
                customRace=false
                if [ "$historyRace" = custom ]; then
                    customRace=true
                    printf '{"type":"message_start","message":{"role":"custom","display":true,"content":"Visible custom message"}}\n{"type":"message_end","message":{"role":"custom","display":true,"content":"Visible custom message"}}\n'
                else
                    printf '{"type":"agent_start"}\n{"type":"agent_settled"}\n'
                fi
                if [ "$historyRace" != always ]; then historyRace=done; fi
                /bin/sleep 0.1
                reply '{"messages":[{"role":"compactionSummary","summary":"Superseded history"}]}'
                if [ "$customRace" = true ]; then messages='[{"role":"custom","display":true,"content":"Visible custom message"}]'
                else messages='[{"role":"compactionSummary","summary":"Current refreshed history"}]'; fi
            else
                if [ "$historyRace" = done ]; then printf R >> "$folder/refresh-reads"; historyRace=none; fi
                reply "{\"messages\":$messages}"
            fi ;;
        export_html) output=$(printf '%s' "$line" | /usr/bin/plutil -extract outputPath raw -o - -); printf '<!doctype html><html>private fixture</html>' > "$output"; reply "{\"path\":\"$output\"}" ;;
        get_last_assistant_text) reply '{"text":"Fixture complete"}' ;;
        set_steering_mode) printf x >> "$folder/runtime-writes"; steering=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"mode":"\([^"]*\)".*/\1/p'); reply '{}' ;;
        set_follow_up_mode) printf x >> "$folder/runtime-writes"; followup=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"mode":"\([^"]*\)".*/\1/p'); reply '{}' ;;
        set_auto_compaction) printf x >> "$folder/runtime-writes"; case "$line" in *'"enabled":true'*) compaction=true ;; *) compaction=false ;; esac; reply '{}' ;;
        cycle_model) printf M >> "$folder/core-controls"; reply 'null' ;;
        cycle_thinking_level) printf T >> "$folder/core-controls"; thinking=low; reply '{"level":"low"}' ;;
        set_auto_retry) case "$line" in *'"enabled":true'*) printf E >> "$folder/core-controls" ;; *) printf D >> "$folder/core-controls" ;; esac; reply '{}' ;;
        abort_retry) printf A >> "$folder/core-controls"; reply '{}'; if [ "$streaming" = true ]; then streaming=false; printf '{"type":"agent_settled"}\n'; fi ;;
        get_session_stats) reply '{"userMessages":1,"assistantMessages":1,"toolCalls":0,"toolResults":0,"totalMessages":2,"tokens":{"input":10,"output":20,"cacheRead":0,"cacheWrite":0,"total":30},"cost":0.01,"contextUsage":{"tokens":30,"contextWindow":200000,"percent":0.015},"sessionFile":"private-fixture-path"}' ;;
        get_entries) entries=$(/usr/bin/tail -n +2 "$file" | /usr/bin/awk 'NF { if (seen++) printf ","; printf "%s", $0 }'); if [ -z "$entries" ]; then reply '{"entries":[],"leafId":null}'; else leaf=$(/usr/bin/tail -1 "$file" | /usr/bin/plutil -extract id raw -o - -); reply "{\"entries\":[$entries],\"leafId\":\"$leaf\"}"; fi ;;
        set_thinking_level) thinking=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"level":"\([^"]*\)".*/\1/p'); reply '{}' ;;
        compact) printf '{"type":"compaction_start","reason":"manual"}\n{"type":"compaction_end","reason":"manual","aborted":false,"errorMessage":"Private compaction failure"}\n'; printf '{"id":"%s","type":"response","command":"compact","success":false,"error":"Private compaction failure"}\n' "$id" ;;
        set_session_name)
            namejson=$(printf '%s' "$line" | /usr/bin/grep -o '"name":"\([^"\\]\|\\.\)*"' | /usr/bin/cut -c 8- | /usr/bin/sed 's/^"[[:space:]]*/"/; s/[[:space:]]*"$/"/')
            printf '%s' "$namejson" > "$namefile"
            reply '{}'
            printf '{"type":"session_info_changed","name":%s}\n' "$namejson" ;;
        steer|follow_up)
            printf '%s\n' "$command" >> "$folder/queue-wire"
            case "$line" in
                *'/ask'*|*'/metadata'*) printf '{"id":"%s","type":"response","command":"%s","success":false,"error":"Extension commands cannot be queued"}\n' "$id" "$command"; continue ;;
                *'consume'*) reply '{"disposition":"handled"}'; continue ;;
                *'race'*) streaming=false; printf '{"type":"agent_settled"}\n' ;;
            esac
            if [ "$command" = steer ]; then queuedSteering='["fixture"]'; else queuedFollow='["fixture"]'; fi
            queueCount=$((queueCount + 1))
            printf '{"type":"queue_update","steering":%s,"followUp":%s}\n' "$queuedSteering" "$queuedFollow"
            reply '{"disposition":"queued"}' ;;
        clear_queue) queueCount=0; queuedSteering='[]'; queuedFollow='[]'; printf '{"type":"queue_update","steering":[],"followUp":[]}\n'; reply '{}' ;;
        prompt)
            case "$line" in
                *'/metadata extension-error'*) printf '{"type":"extension_error","extensionPath":"/private-extension-error/fixture.js","event":"command","error":"private-extension-error details"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata unknown-ui'*) printf '{"type":"extension_ui_request","id":"unknown","method":"future-interactive-method"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata flood'*) reply '{"disposition":"handled"}'; printf F >> "$folder/flood-runs"; i=0; while [ "$i" -lt 100 ]; do printf '{"type":"extension_ui_request","id":"burst","method":"notify","message":"Bounded event fixture"}\n'; i=$((i + 1)); done; /bin/sleep 0.1 ;;
                *'/metadata refresh-race-'*) case "$line" in *'refresh-race-always'*) historyRace=always ;; *'refresh-race-custom'*) historyRace=custom ;; *) historyRace=once ;; esac; printf '{"type":"compaction_start","reason":"threshold"}\n{"type":"compaction_end","reason":"threshold","result":{"summary":"Refresh race"},"willRetry":true,"aborted":false}\n{"type":"agent_settled"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata auto-compact'*) messages='[{"role":"compactionSummary","summary":"Compacted fixture"}]'; printf '{"type":"compaction_start","reason":"threshold"}\n{"type":"compaction_end","reason":"threshold","result":{"summary":"Compacted fixture"},"willRetry":true,"aborted":false}\n{"type":"agent_settled"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata clear-name'*) namejson=null; printf null > "$namefile"; printf '{"type":"session_info_changed"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata clear-status'*) printf '{"type":"extension_ui_request","id":"clear-status","method":"setStatus","statusKey":"shared"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata clear-widget'*) printf '{"type":"extension_ui_request","id":"clear-widget","method":"setWidget","widgetKey":"shared"}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata status'*) printf '{"type":"extension_ui_request","id":"status","method":"setStatus","statusKey":"shared","statusText":"Status fixture"}\n{"type":"extension_ui_request","id":"widget","method":"setWidget","widgetKey":"shared","widgetLines":["Widget fixture"]}\n'; reply '{"disposition":"handled"}' ;;
                *'/metadata thinking'*) thinking=low; printf '{"type":"thinking_level_changed","level":"low"}\n'; reply '{"disposition":"handled"}' ;;
                *'/ask'*) pending=$id; printf '{"type":"extension_ui_request","id":"question-1","method":"confirm","title":"Fixture confirmation"}\n' ;;
                *)
                    printf x >> "$folder/accepted"
                    reply '{"disposition":"started"}'
                    printf '{"type":"agent_start"}\n{"type":"message_start","message":{"role":"assistant"}}\n{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"partial"}}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Fixture complete"}]}}\n{"type":"agent_end"}\n{"type":"agent_settled"}\n'
                    ;;
            esac ;;
        extension_ui_response)
            printf A >> "$folder/answers"
            printf '{"id":"%s","type":"response","command":"prompt","success":true,"data":{"disposition":"handled"}}\n' "$pending" ;;
        abort) streaming=false; printf '{"type":"agent_settled"}\n'; reply '{}' ;;
        *) reply '{}' ;;
    esac
done
"""#
    var contents = hold ? script
        .replacingOccurrences(of: "reply '{\"disposition\":\"started\"}'", with: "streaming=true; reply '{\"disposition\":\"started\"}'")
        .replacingOccurrences(of: "\\n{\"type\":\"agent_settled\"}", with: "") : script
    if let image {
        let output = #"printf '{"type":"tool_execution_start","toolCallId":"image-tool","toolName":"read"}\n{"type":"tool_execution_end","toolCallId":"image-tool","toolName":"read","result":{"content":[{"type":"image","mimeType":"image/png","data":""# + image.base64EncodedString() + #""}]}}\n'"#
        contents = contents.replacingOccurrences(of: "                    printf '{\"type\":\"agent_start\"}\\n", with: "                    printf '{\"type\":\"agent_start\"}\\n'\n                    " + output + "\n                    printf '")
    }
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

@Test(.timeLimit(.minutes(1)), arguments: ["rejected", "authentication", "async-authentication", "crash-before", "crash-after"])
func promptFailuresPreserveRecoveryAndNeverRedispatch(mode: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    var script = try String(contentsOf: executable, encoding: .utf8)
    let disposition = "reply '{\"disposition\":\"started\"}'"
    switch mode {
    case "rejected", "authentication":
        let reason = mode == "authentication" ? "No API key found" : "Invalid fixture request"
        script = script.replacingOccurrences(of: disposition, with: "printf '{\"id\":\"%s\",\"type\":\"response\",\"command\":\"prompt\",\"success\":false,\"error\":\"" + reason + "\"}\\n' \"$id\"; continue")
    case "async-authentication":
        script = script.replacingOccurrences(of: "\"text\":\"Fixture complete\"", with: "\"text\":\"\"")
            .replacingOccurrences(of: "\"role\":\"assistant\",\"content\"", with: "\"role\":\"assistant\",\"stopReason\":\"error\",\"errorMessage\":\"No API key found\",\"content\"")
    case "crash-before":
        script = script.replacingOccurrences(of: disposition, with: "exit 1")
    default:
        script = script.replacingOccurrences(of: disposition, with: disposition + "; printf '{\"type\":\"agent_start\"}\\n'; exit 1")
    }
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: executable)
    do {
        let directory = try await host.directories.register(root)
        let device = UUID()
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let selected = try #require(await host.state().selected)
        let request = AppRequest(epoch: host.epoch, session: selected, action: .prompt(text: "Failure fixture", delivery: .prompt, image: nil))
        let expected: AppResult
        switch mode {
        case "authentication": expected = .failure(.providerAuthenticationRequired)
        case "rejected": expected = .failure(.invalidRequest)
        case "crash-before": expected = .failure(.unknownOutcome)
        default: expected = .ok
        }
        #expect(await host.handle(request, device: device) == expected)
        for _ in 0..<200 {
            let state = await host.state()
            if mode.hasPrefix("crash") ? state.phase == "interrupted" : state.phase == "idle" && (mode != "async-authentication" || state.error != nil) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await host.handle(request, device: device) == expected)
        let state = await host.state()
        let interrupted = mode.hasPrefix("crash")
        #expect(state.phase == (interrupted ? "interrupted" : "idle"))
        #expect(state.sessions.first?.interrupted == interrupted)
        if mode == "async-authentication" { #expect(state.error == .providerAuthenticationRequired) }
        let folder = support.appendingPathComponent("pi-sessions/" + selected.uuidString)
        #expect(try Data(contentsOf: folder.appendingPathComponent("accepted")).count == 1)
        if mode == "rejected" || mode == "authentication" {
            // An empty rejected session may have no on-disk Pi history. It must
            // remain resumable rather than acquire a false populated-file gate.
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
                try FileManager.default.removeItem(at: file)
            }
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .resumeSession(id: selected)), device: device) == .ok)
            #expect(try Data(contentsOf: folder.appendingPathComponent("accepted")).count == 1)
        }
        await host.shutdown()
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: support.appendingPathComponent("sessions.json")))
        #expect(saved.array?.first?["info"]?["interrupted"]?.bool == interrupted)
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["{}", "{\"userMessages\":-1,\"assistantMessages\":0,\"toolCalls\":0,\"toolResults\":0,\"totalMessages\":0,\"tokens\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0},\"cost\":0}"])
func invalidPiStatisticsFailClosed(payload: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let script = try String(contentsOf: executable, encoding: .utf8)
    let changed = script.replacingOccurrences(of: "        get_session_stats) reply '", with: "        get_session_stats) reply '" + payload + "'; continue ;;\n        unused_statistics) reply '")
    try changed.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        let directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: UUID()) == .ok)
        let request = AppRequest(epoch: host.epoch, session: await host.state().selected, action: .statistics)
        #expect(await host.handle(request, device: UUID()) == .failure(.incompatiblePi))
        #expect(await host.state().phase == "idle")
        await host.shutdown()
    } catch { await host.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1))) func outputImagesAreAvailableFromHistoryAndCannotCrossSessions() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try outputImagePNG(seed: 50)
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root, image: data))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = try #require(await host.state().selected)
        let raw: JSONValue = .object(["type": .string("message"), "id": .string("history-image"), "parentId": .null,
            "message": .object(["role": .string("toolResult"), "content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(data.base64EncodedString())])])])])
        let file = support.appendingPathComponent("pi-sessions/" + session.uuidString + "/" + session.uuidString + ".jsonl")
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd(); try writer.write(contentsOf: JSONEncoder().encode(raw) + Data([10])); try writer.close()
        let page = await host.handle(AppRequest(epoch: host.epoch, session: session, action: .historyPage(cursor: nil)), device: device)
        guard case .historyPage(let entries) = page, let previewID = entries.items.first?.preview else { throw RemoteFault.invalidRequest }
        let result = await host.handle(AppRequest(epoch: host.epoch, session: session, action: .historyEntry(id: previewID)), device: device)
        guard case .preview(let preview) = result else { throw RemoteFault.invalidRequest }
        let reference = try #require(preview.images?.first)
        #expect(preview.text == "[Image]" && reference.fault == nil)
        let request = AppRequest(epoch: host.epoch, session: session, action: .outputImage(id: reference.id))
        #expect(await host.handle(request, device: device) == .image(ImageAttachment(data: data, mimeType: "image/png")))
        #expect(!String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains(data.base64EncodedString()))
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .createSession(directory: directory)), device: device) == .ok)
        #expect(await host.handle(request, device: device) == .failure(.conflict))
        let current = await host.state().selected
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: current, action: .outputImage(id: reference.id)), device: device) == .failure(.expired))
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: current, action: .historyEntry(id: previewID)), device: device) == .failure(.expired))
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1))) func runtimeSettingsAreSerializedAndClosePreservesTheCatalog() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root, hold: true))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let initial = await host.state(), session = try #require(await host.state().selected)
        #expect(initial.runtime == RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true))
        let queue = AppRequest(epoch: host.epoch, session: session, action: .queueMode(kind: .steering, mode: .all))
        #expect(await host.handle(queue, device: device) == .ok)
        #expect(await host.handle(queue, device: device) == .ok)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .queueMode(kind: .followUp, mode: .all)), device: device) == .ok)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .autoCompaction(enabled: false)), device: device) == .ok)
        let settings = RuntimeSettings(steeringMode: .all, followUpMode: .all, autoCompactionEnabled: false)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .runtimeSettings), device: device) == .runtimeSettings(settings))
        let writes = support.appendingPathComponent("pi-sessions/" + session.uuidString + "/runtime-writes")
        #expect(try Data(contentsOf: writes).count == 3)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .prompt(text: "Hold fixture", delivery: .prompt, image: nil)), device: device) == .ok)
        for _ in 0..<100 {
            if await host.state().working { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let close = AppRequest(epoch: host.epoch, session: session, action: .closeSession)
        #expect(await host.handle(close, device: device) == .failure(.busy))
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .autoCompaction(enabled: true)), device: device) == .failure(.busy))
        #expect(try Data(contentsOf: writes).count == 3)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .stop), device: device) == .ok)
        let idleClose = AppRequest(epoch: host.epoch, session: session, action: .closeSession)
        #expect(await host.handle(idleClose, device: device) == .ok)
        let closed = await host.state()
        #expect(closed.selected == nil && closed.phase == "idle" && closed.messages.isEmpty && closed.runtime == nil)
        #expect(closed.sessions.count == 1 && closed.sessions.first?.id == session)
        #expect(await host.handle(idleClose, device: device) == .failure(.conflict))
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .resumeSession(id: session)), device: device) == .ok)
        #expect(await host.state().selected == session)
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["steering", "follow-up", "compaction"])
func runtimeSettingsRejectUnconfirmedChangesWithoutRedispatch(mode: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let command = mode == "steering" ? "set_steering_mode" : mode == "follow-up" ? "set_follow_up_mode" : "set_auto_compaction"
    let script = try String(contentsOf: executable, encoding: .utf8)
    let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("        " + command + ")") })
    let replacement = "        " + command + ") printf x >> \"$folder/runtime-writes\"; reply '{}' ;;"
    try script.replacingOccurrences(of: line, with: replacement).write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: executable)
    do {
        let directory = try await host.directories.register(root), device = UUID()
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let initial = await host.state(), session = try #require(await host.state().selected)
        let action: SessionAction = mode == "compaction" ? .autoCompaction(enabled: false) : .queueMode(kind: mode == "steering" ? .steering : .followUp, mode: .all)
        let request = AppRequest(epoch: host.epoch, session: session, action: action)
        #expect(await host.handle(request, device: device) == .failure(.conflict))
        #expect(await host.handle(request, device: device) == .failure(.conflict))
        #expect(await host.state().runtime == initial.runtime)
        #expect(try Data(contentsOf: support.appendingPathComponent("pi-sessions/" + session.uuidString + "/runtime-writes")).count == 1)
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["none", "omitted", "invalid", "large"])
func lastAssistantTextHasExplicitEmptyInvalidAndTruncatedResults(mode: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root)
    let value: JSONValue = mode == "none" ? .null : mode == "invalid" ? .number(4) : .string(String(repeating: "é", count: 140_000))
    let payload = String(decoding: try JSONEncoder().encode(JSONValue.object(mode == "omitted" ? [:] : ["text": value])), as: UTF8.self)
    let script = try String(contentsOf: executable, encoding: .utf8).replacingOccurrences(of: "get_last_assistant_text) reply '{\"text\":\"Fixture complete\"}'", with: "get_last_assistant_text) reply '" + payload + "'")
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        let directory = try await host.directories.register(root), device = UUID()
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = await host.state().selected
        let result = await host.handle(AppRequest(epoch: host.epoch, session: session, action: .lastAssistant), device: device)
        if mode == "invalid" { #expect(result == .failure(.incompatiblePi)) }
        else {
            guard case .preview(let preview) = result else { throw RemoteFault.invalidRequest }
            #expect(preview.truncated == (mode == "large"))
            #expect(preview.text.utf8.count == (mode == "large" ? 256 * 1_024 : 0))
            #expect(try AppPacket(result).encode().count < 4 * 1_024 * 1_024)
        }
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "wrong-path", "missing", "large", "symlink", "busy"])
func sessionExportIsBoundedPrivateAndSessionScoped(mode: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root, hold: true)
    let support = root.appendingPathComponent("support")
    let exportScript = #"""
        export_html)
            output=$(printf '%s' "$line" | /usr/bin/plutil -extract outputPath raw -o - -)
            printf '<!doctype html><html>private fixture</html>' > "$output"
            reply "{\"path\":\"$output\"}" ;;
"""#
    var body = exportScript
    if mode == "wrong-path" { body = body.replacingOccurrences(of: "$output\\\"}", with: "/private/wrong.html\\\"}") }
    if mode == "missing" { body = body.replacingOccurrences(of: "            reply", with: "            /bin/rm \"$output\"\n            reply") }
    if mode == "large" { body = body.replacingOccurrences(of: "            reply", with: "            /usr/sbin/mkfile 3m \"$output\"\n            reply") }
    if mode == "symlink" { body = body.replacingOccurrences(of: "            reply", with: "            /bin/rm \"$output\"; /bin/ln -s /etc/hosts \"$output\"\n            reply") }
    let original = try String(contentsOf: executable, encoding: .utf8)
    let exportLine = try #require(original.components(separatedBy: "\n").first { $0.hasPrefix("        export_html)") })
    let script = original.replacingOccurrences(of: exportLine, with: body)
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let host = try HostCoordinator(support: support, executable: executable)
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = try #require(await host.state().selected)
        let request = AppRequest(epoch: host.epoch, session: session, action: .exportSession)
        if mode == "busy" {
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .prompt(text: "Hold fixture", delivery: .prompt, image: nil)), device: device) == .ok)
        }
        let result = await host.handle(request, device: device)
        switch mode {
        case "valid":
            #expect(result == .exportSession(SessionExport(data: Data("<!doctype html><html>private fixture</html>".utf8))))
            let decoded = try AppPacket<AppResult>.decode(AppPacket(result).encode()).payload
            #expect(decoded == result)
        case "wrong-path": #expect(result == .failure(.incompatiblePi))
        case "missing", "symlink": #expect(result == .failure(.permissionDenied))
        case "large": #expect(result == .failure(.tooLarge))
        default: #expect(result == .failure(.busy))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).allSatisfy { !$0.hasPrefix("export-") })
        var stale = request; stale.session = UUID()
        #expect(await host.handle(stale, device: device) == .failure(.conflict))
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["valid", "no-final-lf", "leading-blank", "legacy-v1", "legacy-v2", "duplicate-json", "malformed", "missing-directory", "denied-directory", "busy", "stale"])
func sessionImportCopiesOnlyValidatedHistoryAndNeverSendsAPrompt(mode: String) async throws {
    let root = try temporaryDirectory()
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
        try? FileManager.default.removeItem(at: root)
    }
    let sourceID = UUID().uuidString
    let header: JSONValue = .object(["type": .string("session"), "version": .number(mode == "legacy-v1" ? 1 : mode == "legacy-v2" ? 2 : 3), "id": .string(sourceID), "cwd": .string(mode == "missing-directory" ? project.appendingPathComponent("missing").path : project.path)])
    let entry: JSONValue = .object(["type": .string("message"), "id": .string("user-1"), "parentId": .null,
                                    "message": .object(["role": .string("user"), "content": .string("Saved private fixture")])])
    var data = try JSONEncoder().encode(header); data.append(10)
    data.append(try JSONEncoder().encode(entry)); data.append(10)
    if mode == "malformed" { data = Data("broken".utf8) }
    if mode == "duplicate-json" {
        data = try JSONEncoder().encode(header); data.append(10)
        data.append(Data(#"{"type":"message","id":"user-1","parentId":null,"parentId":"user-1","message":{"role":"user","content":"Ambiguous tree fixture"}}"#.utf8))
        data.append(10)
    }
    if mode == "no-final-lf" { data.removeLast() }
    var normalized = data
    if normalized.last != 10 { normalized.append(10) }
    if mode == "leading-blank" { data = Data("\n \t\r\n".utf8) + data }
    let source = root.appendingPathComponent("source.jsonl")
    try data.write(to: source)
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root, hold: true))
    do {
        let device = UUID(), directory = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let before = await host.state()
        if mode == "denied-directory" { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: project.path) }
        if mode == "busy" {
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: before.selected, action: .prompt(text: "Hold", delivery: .prompt, image: nil)), device: device) == .ok)
        }
        let request = AppRequest(epoch: host.epoch, session: mode == "stale" ? UUID() : before.selected, action: .importSession(data: data))
        let result = await host.handle(request, device: device)
        if mode == "valid" || mode == "no-final-lf" || mode == "leading-blank" || mode.hasPrefix("legacy-") {
            #expect(result == .ok)
            #expect(await host.handle(request, device: device) == .ok)
            let state = await host.state(), selected = try #require(state.selected)
            #expect(selected != before.selected && state.sessions.count == 2)
            #expect(state.sessions.first(where: { $0.id == selected })?.directory == project.resolvingSymlinksInPath().path)
            #expect(state.sessions.first(where: { $0.id == selected })?.interrupted == true)
            let folder = support.appendingPathComponent("pi-sessions/" + selected.uuidString)
            let copy = folder.appendingPathComponent("imported.jsonl")
            #expect(try Data(contentsOf: copy) == normalized)
            guard case .exportSession(let archive) = await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .exportJSONL), device: device) else { throw RemoteFault.invalidRequest }
            let archiveInfo = try SessionImport(data: archive.data)
            #expect(archive.format == .jsonl && archiveInfo.piID == sourceID && archiveInfo.entryCount == 1)
            #expect(String(decoding: archive.data, as: UTF8.self).contains("Saved private fixture"))
            #expect((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("accepted").path))
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: selected, action: .closeSession), device: device) == .ok)
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .resumeSession(id: selected)), device: device) == .ok)
            #expect(try Data(contentsOf: copy) == normalized)
        } else {
            let fault: RemoteFault = ["malformed", "duplicate-json"].contains(mode) ? .invalidRequest : mode == "missing-directory" ? .staleDirectory : mode == "denied-directory" ? .permissionDenied : mode == "busy" ? .busy : .conflict
            #expect(result == .failure(fault))
            #expect(await host.state().selected == before.selected)
            #expect(await host.state().sessions.count == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("pi-sessions").path).count == 1)
        }
        #expect(try Data(contentsOf: source) == data)
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["different", "missing-source", "missing-header", "symlink", "stale-directory", "denied", "file", "unknown", "busy", "stale-session"])
func importDirectoryChoiceIsExplicitValidatedAndSourcePreserving(mode: String) async throws {
    let root = try temporaryDirectory()
    let target = root.appendingPathComponent("chosen-project")
    let old = root.appendingPathComponent("source-project")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    if mode != "missing-source" { try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false) }
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        try? FileManager.default.removeItem(at: root)
    }
    let piID = UUID().uuidString
    var header: [String: JSONValue] = ["type": .string("session"), "version": .number(3), "id": .string(piID)]
    if mode != "missing-header" { header["cwd"] = .string(old.path) }
    let entry: JSONValue = .object(["type": .string("message"), "id": .string("source-user"), "parentId": .null,
                                   "message": .object(["role": .string("user"), "content": .string("Keep " + old.path + "/source.swift")])])
    var data = try JSONEncoder().encode(JSONValue.object(header)); data.append(10)
    var messageBytes = try JSONEncoder().encode(entry); messageBytes.append(10); data.append(messageBytes)
    let source = root.appendingPathComponent("source.jsonl")
    try data.write(to: source)
    let support = root.appendingPathComponent("support")
    let host = try HostCoordinator(support: support, executable: fakePi(at: root, hold: true))
    do {
        let device = UUID(), starting = try await host.directories.register(root)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: starting)), device: device) == .ok)
        let before = await host.state()
        var chosen = target
        if mode == "symlink" {
            chosen = root.appendingPathComponent("chosen-alias")
            try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: target)
        }
        if mode == "file" { chosen = source }
        var directory = try await host.directories.register(chosen)
        if mode == "unknown" { directory = UUID() }
        if mode == "stale-directory" { try FileManager.default.removeItem(at: target) }
        if mode == "denied" { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path) }
        if mode == "busy" {
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: before.selected, action: .prompt(text: "Hold", delivery: .prompt, image: nil)), device: device) == .ok)
        }
        if ["missing-header", "missing-source"].contains(mode) {
            let normal = await host.handle(AppRequest(epoch: host.epoch, session: before.selected, action: .importSession(data: data)), device: device)
            #expect(normal == .failure(mode == "missing-header" ? .invalidRequest : .staleDirectory))
            #expect(await host.state().selected == before.selected)
        }
        let request = AppRequest(epoch: host.epoch, session: mode == "stale-session" ? UUID() : before.selected,
                                 action: .importSessionInDirectory(data: data, directory: directory))
        let result = await host.handle(request, device: device)
        if ["different", "missing-source", "missing-header", "symlink"].contains(mode) {
            #expect(result == .ok)
            #expect(await host.handle(request, device: device) == .ok)
            let state = await host.state(), selected = try #require(state.selected)
            #expect(selected != before.selected && state.sessions.count == 2)
            #expect(state.sessions.first(where: { $0.id == selected })?.directory == target.resolvingSymlinksInPath().path)
            let folder = support.appendingPathComponent("pi-sessions/" + selected.uuidString)
            let copy = try Data(contentsOf: folder.appendingPathComponent("imported.jsonl"))
            let info = try SessionImport(data: copy)
            #expect(info.piID == piID && info.directory == target.resolvingSymlinksInPath().path)
            #expect(copy.suffix(messageBytes.count) == messageBytes)
            let observed = try String(contentsOf: folder.appendingPathComponent("observed-cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(try DirectoryRegistry.identify(URL(fileURLWithPath: observed)) == DirectoryRegistry.identify(target))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("accepted").path))
            var changed = request; changed.action = .importSessionInDirectory(data: data, directory: UUID())
            #expect(await host.handle(changed, device: device) == .failure(.conflict))
        } else {
            let fault: RemoteFault = mode == "denied" ? .permissionDenied : mode == "busy" ? .busy : mode == "stale-session" ? .conflict : .staleDirectory
            #expect(result == .failure(fault))
            let unchanged = await host.state()
            #expect(unchanged.selected == before.selected && unchanged.sessions.count == 1)
        }
        #expect(try Data(contentsOf: source) == data)
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["malformed", "unknown-leaf", "large", "busy", "empty"])
func jsonlExportRejectsInvalidLiveStateAndBoundsTheResponse(mode: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakePi(at: root, hold: true)
    if !["busy", "empty"].contains(mode) {
        let entry: JSONValue = .object(["type": .string("message"), "id": .string("root"), "parentId": .null,
            "message": .object(["role": .string("user"), "content": .string(mode == "large" ? String(repeating: "x", count: SessionExport.maximumBytes) : "Live fixture")])])
        let response: JSONValue = mode == "malformed" ? .object(["entries": .array([.object(["id": .string("bad")])]), "leafId": .string("bad")]) :
            .object(["entries": .array([entry]), "leafId": .string(mode == "unknown-leaf" ? "missing" : "root")])
        let payload = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let original = try String(contentsOf: executable, encoding: .utf8)
        let line = try #require(original.components(separatedBy: "\n").first { $0.hasPrefix("        get_entries)") })
        try original.replacingOccurrences(of: line, with: "        get_entries) reply '" + payload + "' ;;").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: executable)
    do {
        let directory = try await host.directories.register(root), device = UUID()
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory)), device: device) == .ok)
        let session = try #require(await host.state().selected)
        if mode == "busy" {
            #expect(await host.handle(AppRequest(epoch: host.epoch, session: session, action: .prompt(text: "Hold fixture", delivery: .prompt, image: nil)), device: device) == .ok)
        }
        let result = await host.handle(AppRequest(epoch: host.epoch, session: session, action: .exportJSONL), device: device)
        if mode == "empty" {
            guard case .exportSession(let archive) = result else { throw RemoteFault.invalidRequest }
            let review = try SessionImport(data: archive.data)
            #expect(archive.format == .jsonl && review.entryCount == 0)
        } else {
            let fault: RemoteFault = mode == "large" ? .tooLarge : mode == "busy" ? .busy : .incompatiblePi
            #expect(result == .failure(fault))
        }
        #expect(await host.state().selected == session)
        #expect(await host.handle(AppRequest(epoch: host.epoch, session: UUID(), action: .exportJSONL), device: device) == .failure(.conflict))
    } catch { await host.shutdown(); throw error }
    await host.shutdown()
}

@Test(.timeLimit(.minutes(1))) func missingPiReportsFailureWithoutStartingAChild() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: root.appendingPathComponent("missing-pi"))
    await host.inspectPi()
    #expect(await host.state().piVersion == "Unavailable")
    #expect(await host.state().error == .piLaunchFailed)
    let directory = try await host.directories.register(root)
    let request = AppRequest(epoch: host.epoch, session: nil, action: .createSession(directory: directory))
    #expect(await host.handle(request, device: UUID()) == .failure(.piLaunchFailed))
    #expect(await host.state().working == false)
    await host.shutdown()
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
        let statsRequest = AppRequest(epoch: host.epoch, session: state.selected, action: .statistics)
        guard case .statistics(let statistics) = await host.handle(statsRequest, device: device) else { throw RemoteFault.invalidRequest }
        #expect(statistics.tokens.total == 30 && statistics.cost == 0.01)
        #expect(!String(decoding: try AppPacket(AppResult.statistics(statistics)).encode(), as: UTF8.self).contains("private-fixture-path"))
        var staleStats = statsRequest; staleStats.session = UUID()
        #expect(await host.handle(staleStats, device: device) == .failure(.conflict))
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
        for action in [SessionAction.directories(id: nil, cursor: nil), .directoryAtPath(path: root.path)] {
            let unauthenticated = try PinnedChannel(url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate)
            _ = try await unauthenticated.receive()
            try await unauthenticated.send(AppPacket(ClientMessage.request(AppRequest(epoch: host.epoch, session: nil, action: action))).encode())
            let denied = try AppPacket<ServerMessage>.decode(await unauthenticated.receive()).payload
            guard case .denied = denied else { throw RemoteFault.invalidRequest }
            unauthenticated.close()
        }
        let grant = try await server.openPairing()
        let code = PairingCode(host: host.hostID, name: "Fixture Mac", url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate, grant: grant, expires: Date().addingTimeInterval(120))
        let updates = await server.pairingUpdates()
        let pairing = Task { try await client.pair(code: code, device: UUID(), name: "Fixture phone") }
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
        try await client.connect(mac)
        _ = try await client.request(.prompt(text: "Continue independently of device access", delivery: .prompt, image: nil))
        #expect(await host.state().working)
        try await server.revoke(mac.device)
        await #expect(throws: (any Error).self) { try await client.request(.snapshot) }
        await #expect(throws: (any Error).self) { try await client.connect(mac) }
        #expect(await host.state().working)
        let localStop = AppRequest(epoch: host.epoch, session: await host.state().selected, action: .stop)
        #expect(await host.handle(localStop, device: UUID()) == .ok)
        #expect(await !host.state().working)
    } catch { await client.disconnect(); await server.stop(); await host.shutdown(); throw error }
    await client.disconnect(); await server.stop(); await host.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ListenAddress.all().map(\.address))
func selectedInterfaceSupportsAuthenticatedControlAndReconnect(address: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemorySecrets()
    let image = try outputImagePNG(seed: 100)
    let host = try HostCoordinator(support: root.appendingPathComponent("support"), executable: fakePi(at: root, hold: true, image: image))
    let registry = try DeviceRegistry(secrets: store, metadata: root.appendingPathComponent("devices.json"))
    let identity = try await ServerIdentity.load(secrets: store, support: root)
    let server = AppServer(coordinator: host, registry: registry)
    let client = RemoteClient(secrets: store)
    do {
        #expect(identity.addresses.contains(address))
        let port = try await server.start(identity: identity, address: address, port: 0)
        // A listener selected for another interface must not also accept loopback traffic.
        if !address.hasPrefix("127.") {
            let other = try PinnedChannel(url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate)
            await #expect(throws: (any Error).self) { try await other.receive(timeout: 2) }
            other.close()
        }
        let grant = try await server.openPairing()
        let code = PairingCode(host: host.hostID, name: "Local fixture", url: URL(string: "wss://\(address):\(port)/")!, certificate: identity.certificate, grant: grant, expires: Date().addingTimeInterval(120))
        let updates = await server.pairingUpdates()
        let approval = Task {
            for await candidate in updates {
                if let candidate { try await server.approve(candidate.id); return }
            }
        }
        defer { approval.cancel() }
        let mac = try await RemoteClient.pair(code: code, device: UUID(), name: "Local client", secrets: store)
        try await approval.value
        try await client.connect(mac)
        let folder = try await host.directories.register(root)
        _ = try await client.request(.createSession(directory: folder))
        guard case .runtimeSettings(let initialRuntime) = try await client.request(.runtimeSettings) else { throw RemoteFault.invalidRequest }
        #expect(initialRuntime.autoCompactionEnabled)
        _ = try await client.request(.queueMode(kind: .steering, mode: .all))
        guard case .runtimeSettings(let changedRuntime) = try await client.request(.runtimeSettings) else { throw RemoteFault.invalidRequest }
        #expect(changedRuntime.steeringMode == .all)
        #expect(try await client.request(.lastAssistant) == .preview(FilePreview(name: "Last assistant text", text: "Fixture complete", truncated: false)))
        #expect(try await client.request(.exportSession) == .exportSession(SessionExport(data: Data("<!doctype html><html>private fixture</html>".utf8))))
        _ = try await client.request(.prompt(text: "Interface fixture", delivery: .prompt, image: nil))
        for _ in 0..<100 {
            if await host.state().messages.contains(where: { $0.images?.isEmpty == false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await host.state()
        let reference = try #require(before.messages.compactMap(\.images).flatMap { $0 }.first)
        #expect(try await client.request(.outputImage(id: reference.id)) == .image(ImageAttachment(data: image, mimeType: "image/png")))
        await #expect(throws: RemoteFault.expired) { try await client.request(.outputImage(id: UUID())) }
        var wrongImageScope = before.context; wrongImageScope.session = UUID()
        await #expect(throws: RemoteFault.conflict) { try await client.request(.outputImage(id: reference.id), context: wrongImageScope) }
        #expect(before.working)
        await #expect(throws: RemoteFault.busy) { try await client.request(.exportSession) }
        await client.disconnect()
        #expect(await host.state().working)
        try await client.connect(mac)
        guard case .snapshot(let restored) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
        #expect(restored.selected == before.selected && restored.working)
        let accepted = root.appendingPathComponent("support/pi-sessions/" + restored.selected!.uuidString + "/accepted")
        #expect(try Data(contentsOf: accepted).count == 1)
        // Simulate an unavailable host without suspending the laptop or Pi.
        await server.stop()
        await #expect(throws: (any Error).self) { try await client.request(.snapshot) }
        await #expect(throws: (any Error).self) { try await client.connect(mac) }
        #expect(await host.state().working)
        #expect(try Data(contentsOf: accepted).count == 1)
        #expect(try await server.start(identity: identity, address: address, port: port) == port)
        try await client.connect(mac)
        guard case .snapshot(let recovered) = try await client.request(.snapshot) else { throw RemoteFault.invalidRequest }
        #expect(recovered.selected == before.selected && recovered.working)
        #expect(try await client.request(.outputImage(id: reference.id)) == .image(ImageAttachment(data: image, mimeType: "image/png")))
        #expect(try Data(contentsOf: accepted).count == 1)
        _ = try await client.request(.stop)
        #expect(await !host.state().working)
        let importHeader: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string(UUID().uuidString), "cwd": .string(root.path)])
        let importEntry: JSONValue = .object(["type": .string("message"), "id": .string("network-user"), "parentId": .null,
                                            "message": .object(["role": .string("user"), "content": .string("Network import fixture")])])
        var importData = try JSONEncoder().encode(importHeader); importData.append(10)
        importData.append(try JSONEncoder().encode(importEntry)); importData.append(10)
        _ = try await client.request(.importSession(data: importData))
        let imported = await host.state(), importedID = try #require(imported.selected)
        #expect(importedID != recovered.selected && imported.sessions.count == 2)
        let importFolder = root.appendingPathComponent("support/pi-sessions/" + importedID.uuidString)
        #expect(try Data(contentsOf: importFolder.appendingPathComponent("imported.jsonl")) == importData)
        guard case .exportSession(let archive) = try await client.request(.exportJSONL) else { throw RemoteFault.invalidRequest }
        let archiveReview = try SessionImport(data: archive.data)
        #expect(archive.format == .jsonl && archiveReview.entryCount == 1)
        #expect(String(decoding: archive.data, as: UTF8.self).contains("Network import fixture"))
        #expect(!FileManager.default.fileExists(atPath: importFolder.appendingPathComponent("accepted").path))
        let chosen = root.appendingPathComponent("transport-import")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        let chosenID = try await host.directories.register(chosen)
        _ = try await client.request(.importSessionInDirectory(data: importData, directory: chosenID))
        let relocated = await host.state(), relocatedID = try #require(relocated.selected)
        #expect(relocatedID != importedID && relocated.sessions.count == 3)
        let relocatedFolder = root.appendingPathComponent("support/pi-sessions/" + relocatedID.uuidString)
        let relocatedData = try Data(contentsOf: relocatedFolder.appendingPathComponent("imported.jsonl"))
        #expect(try SessionImport(data: relocatedData).directory == DirectoryRegistry.identify(chosen).url.path)
        let observed = try String(contentsOf: relocatedFolder.appendingPathComponent("observed-cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try DirectoryRegistry.identify(URL(fileURLWithPath: observed)) == DirectoryRegistry.identify(chosen))
        #expect(!FileManager.default.fileExists(atPath: relocatedFolder.appendingPathComponent("accepted").path))
        try await server.revoke(mac.device)
        await #expect(throws: (any Error).self) { try await client.request(.importSessionInDirectory(data: importData, directory: chosenID)) }
        await #expect(throws: (any Error).self) { try await client.request(.importSession(data: importData)) }
        await #expect(throws: (any Error).self) { try await client.request(.exportSession) }
        await #expect(throws: (any Error).self) { try await client.request(.outputImage(id: reference.id)) }
        await #expect(throws: (any Error).self) { try await client.request(.snapshot) }
        await #expect(throws: (any Error).self) { try await client.connect(mac) }
    } catch { await client.disconnect(); await server.stop(); await host.shutdown(); throw error }
    await client.disconnect(); await server.stop(); await host.shutdown()
}

@Test(.timeLimit(.minutes(1))) func productionClientCancellationClosesPendingReceive() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = try await ServerIdentity.load(secrets: MemorySecrets(), support: root)
    let listener = try SecureListener(identity: identity)
    do {
        let port = try await listener.start(address: "127.0.0.1", port: 0) { _ in }
        let client = try PinnedChannel(url: URL(string: "wss://127.0.0.1:\(port)/")!, certificate: identity.certificate)
        defer { client.close() }
        let pending = Task { try await client.receive(timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        pending.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(ContinuousClock.now - start < .seconds(2))
    } catch { await listener.stop(); throw error }
    await listener.stop()
    await listener.stop()
}

@Test(arguments: ["0.0.0.0", "8.8.8.8", "169.254.1.1", "100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1", "::1", "localhost"])
func unintendedListenerAddressesAreRejected(address: String) {
    #expect(!ListenAddress.allowed(address))
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
    let pidFile = root.appendingPathComponent("descendant-pid")
    let launched = ContinuousClock.now
    var descendant: pid_t?
    defer {
        if let descendant, launched.duration(to: .now) < .seconds(10) { kill(descendant, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }
    let script = root.appendingPathComponent("hold-pipe")
    let quoted = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try "#!/bin/sh\n/bin/sleep 10 &\nprintf '%s\\n' \"$!\" > \(quoted)\nwait\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let operation = Task { try await LocalCommand.run(script.path, [], directory: root) }
    do {
        for _ in 0..<500 {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                descendant = pid; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(descendant)
        #expect(kill(pid, 0) == 0)
        // Require at least four seconds of pipe-holder lifetime after cancellation.
        // Measure cancellation, not launch or cooperative-executor scheduling delay.
        try #require(launched.duration(to: .now) < .seconds(6))
        let cancelled = ContinuousClock.now
        operation.cancel()
        await #expect(throws: RemoteFault.cancelled) { try await operation.value }
        #expect(cancelled.duration(to: .now) < .seconds(3))
    } catch {
        operation.cancel()
        _ = try? await operation.value
        throw error
    }
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
        .snapshot, .synchronize(epoch: epoch, after: 4), .directories(id: id, cursor: UUID()), .directoryAtPath(path: "~/project"),
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
