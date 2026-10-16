import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import PiRemoteClient
import PiRemoteCore

/// In-memory UI fixtures only. This target is not a product app and opens no sockets.
actor FixtureConnection: PhoneConnection {
    static let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let imageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let home = UUID(), project = UUID(), nested = UUID(), root = UUID(), file = UUID()
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
        state.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true)
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
        if phase == "images" {
            state.messages = [TranscriptMessage(role: "tool", text: "Read image\n[Image]", images: [OutputImageReference(id: Self.imageID), OutputImageReference(id: UUID(), fault: .tooLarge)])]
        }
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
        case .lastAssistant: return .preview(FilePreview(name: "Last assistant text", text: "Native copy fixture", truncated: false))
        case .runtimeSettings:
            guard let runtime = snapshot.runtime else { throw RemoteFault.unavailable }
            return .runtimeSettings(runtime)
        case .queueMode(let kind, let mode):
            guard !snapshot.working, var runtime = snapshot.runtime else { throw RemoteFault.busy }
            if kind == .steering { runtime.steeringMode = mode } else { runtime.followUpMode = mode }
            snapshot.runtime = runtime
        case .autoCompaction(let enabled):
            guard !snapshot.working, var runtime = snapshot.runtime else { throw RemoteFault.busy }
            runtime.autoCompactionEnabled = enabled; snapshot.runtime = runtime
        case .closeSession:
            guard !snapshot.working else { throw RemoteFault.busy }
            snapshot.selected = nil; snapshot.messages = []; snapshot.runtime = nil
        case .outputImage(let id):
            guard id == Self.imageID else { throw RemoteFault.expired }
            guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RemoteFault.unavailable }
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let data = NSMutableData()
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw RemoteFault.unavailable }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RemoteFault.unavailable }
            return .image(ImageAttachment(data: data as Data, mimeType: "image/png"))
        case .statistics:
            let json = #"{"userMessages":3,"assistantMessages":3,"toolCalls":1,"toolResults":1,"totalMessages":8,"tokens":{"input":1000,"output":200,"cacheRead":500,"cacheWrite":0,"total":1700},"cost":0.0025,"contextUsage":{"tokens":1700,"contextWindow":200000,"percent":0.85}}"#
            return .statistics(try JSONDecoder().decode(SessionStatistics.self, from: Data(json.utf8)))
        case .directories(let id, _):
            let id = id ?? home
            switch id {
            case root: return .directories(DirectoryPage(id: root, path: "/", parent: nil, items: [DirectoryItem(id: home, name: "fixture home", isDirectory: true)], next: nil))
            case home: return .directories(DirectoryPage(id: home, path: "/Users/fixture", parent: root, items: [DirectoryItem(id: project, name: "project", isDirectory: true)], next: nil))
            case project: return .directories(DirectoryPage(id: project, path: "/Users/fixture/project", parent: home, items: [DirectoryItem(id: nested, name: "nested", isDirectory: true), DirectoryItem(id: file, name: "fixture.swift", isDirectory: false)], next: nil))
            case nested: return .directories(DirectoryPage(id: nested, path: "/Users/fixture/project/nested", parent: project, items: [], next: nil))
            default: throw RemoteFault.staleDirectory
            }
        case .preview(let id):
            guard id == file else { throw RemoteFault.staleDirectory }
            return .preview(FilePreview(name: "fixture.swift", text: "let attached = 42", truncated: false))
        case .createSession(let directory):
            guard !snapshot.working else { throw RemoteFault.busy }
            let path = directory == nested ? "/Users/fixture/project/nested" : "/Users/fixture/project"
            let session = SessionInfo(id: UUID(), title: "New fixture session", directory: path)
            snapshot.sessions.append(session); snapshot.selected = session.id; snapshot.messages = []; snapshot.phase = "idle"
            snapshot.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true)
        case .resumeSession(let id):
            snapshot.selected = id
            snapshot.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true)
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
