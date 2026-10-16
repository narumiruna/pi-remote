import Foundation
import PiRemoteClient
import PiRemoteCore

/// In-memory UI fixtures only. This target is not a product app and opens no sockets.
actor FixtureConnection: PhoneConnection {
    static let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let home = UUID(), project = UUID(), nested = UUID(), root = UUID()
    private var snapshot: HostSnapshot
    private let unavailable: Bool
    private let streaming: Bool
    private var streamTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<ClientUpdate>.Continuation] = [:]

    init(phase: String) {
        unavailable = phase == "disconnected"
        streaming = phase == "streaming"
        var state = HostSnapshot(host: Self.host, epoch: UUID())
        let session = UUID()
        state.selected = session
        state.sessions = [SessionInfo(id: session, title: "Fixture session", directory: "/Users/fixture/project")]
        state.phase = phase == "working" || phase == "streaming" ? "working" : "idle"
        state.piVersion = "UI fixture"
        state.models = [ModelOption(provider: "fixture", model: "one", name: "Fixture One"), ModelOption(provider: "fixture", model: "two", name: "Fixture Two")]
        state.model = state.models[0].id
        state.thinkingLevels = ["off", "low", "high"]; state.thinking = "low"
        state.commands = [CommandOption(name: "fixture-dialog", detail: "Open an editor dialog", source: "extension")]
        state.messages = [
            TranscriptMessage(role: "user", text: "Review the fixture change."),
            TranscriptMessage(role: "assistant", text: "## Result\n\nA **native** response.\n\n```swift\nlet fixture = 42\n```", thinking: "Fixture thinking", streaming: state.working),
            TranscriptMessage(role: "tool", text: phase == "error" ? "Read file\nPermission denied for the fixture file." : "Read file\nFixture output", isError: phase == "error")
        ]
        if phase == "error" { state.error = .permissionDenied }
        if phase == "large" {
            let text = String(repeating: "A bounded transcript paragraph. ", count: 60)
            state.messages = (0..<99).map { TranscriptMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Record \($0).\n\n" + text) }
            state.messages.append(TranscriptMessage(role: "tool", text: "Bounded transcript complete"))
        }
        snapshot = state
    }

    func pair(code: PairingCode, device: UUID, name: String) throws -> SavedMac { throw RemoteFault.unsupportedFeature }
    func updates() -> AsyncStream<ClientUpdate> {
        let id = UUID(), pair = AsyncStream<ClientUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation
        if unavailable { pair.continuation.yield(.disconnected(.unavailable)) }
        else { pair.continuation.yield(.state(snapshot)) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return pair.stream
    }
    private func remove(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() { snapshot.sequence += 1; for observer in observers.values { observer.yield(.state(snapshot)) } }
    func connect(_ mac: SavedMac) throws {
        guard !unavailable else { throw RemoteFault.unavailable }
        publish()
        if streaming && streamTask == nil {
            streamTask = Task { [weak self] in
                for index in 1...30 {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    await self?.appendStream(index)
                }
            }
        }
    }
    private func appendStream(_ index: Int) {
        guard snapshot.working, snapshot.messages.indices.contains(1) else { return }
        snapshot.messages[1].text += "\n\nStreaming fixture output \(index)."
        publish()
    }
    func disconnect(fault: RemoteFault) { for observer in observers.values { observer.yield(.disconnected(fault)) } }
    func forget(_ mac: SavedMac) { disconnect(fault: .unauthorized) }

    func request(_ action: SessionAction, context: SessionContext) throws -> AppResult {
        guard context == snapshot.context else { throw RemoteFault.conflict }
        if action.mutates { snapshot.error = nil }
        defer { if action.mutates { publish() } }
        switch action {
        case .snapshot: return .snapshot(snapshot)
        case .directories(let id, _):
            let id = id ?? home
            switch id {
            case root: return .directories(DirectoryPage(id: root, path: "/", parent: nil, items: [DirectoryItem(id: home, name: "fixture home", isDirectory: true)], next: nil))
            case home: return .directories(DirectoryPage(id: home, path: "/Users/fixture", parent: root, items: [DirectoryItem(id: project, name: "project", isDirectory: true)], next: nil))
            case project: return .directories(DirectoryPage(id: project, path: "/Users/fixture/project", parent: home, items: [DirectoryItem(id: nested, name: "nested", isDirectory: true)], next: nil))
            case nested: return .directories(DirectoryPage(id: nested, path: "/Users/fixture/project/nested", parent: project, items: [], next: nil))
            default: throw RemoteFault.staleDirectory
            }
        case .createSession(let directory):
            guard !snapshot.working else { throw RemoteFault.busy }
            let path = directory == nested ? "/Users/fixture/project/nested" : "/Users/fixture/project"
            let session = SessionInfo(id: UUID(), title: "New fixture session", directory: path)
            snapshot.sessions.append(session); snapshot.selected = session.id; snapshot.messages = []; snapshot.phase = "idle"
        case .resumeSession(let id): snapshot.selected = id
        case .prompt(let text, _, _):
            snapshot.messages.append(TranscriptMessage(role: "user", text: text)); snapshot.phase = "working"
        case .stop:
            snapshot.phase = "idle"; snapshot.dialogs = []
            for index in snapshot.messages.indices { snapshot.messages[index].streaming = false }
        case .model(let provider, let id): snapshot.model = provider + "/" + id
        case .thinking(let level): snapshot.thinking = level
        case .rename(let name):
            if let index = snapshot.sessions.firstIndex(where: { $0.id == snapshot.selected }) { snapshot.sessions[index].title = name }
        case .compact: snapshot.notices = ["Compaction fixture completed."]
        case .command:
            snapshot.dialogs = [ExtensionDialog(id: "fixture-editor", method: "editor", title: "Fixture editor", message: "Review this text before submitting it.", options: [], text: "Fixture editor text", expires: nil)]
        case .answer: snapshot.dialogs = []
        case .diff: return .preview(FilePreview(name: "Working tree diff", text: "+ let fixture = 42", truncated: false))
        case .historyPage: return .historyPage(HistoryPage(items: [], next: nil))
        default: throw RemoteFault.unsupportedFeature
        }
        return .ok
    }
}
