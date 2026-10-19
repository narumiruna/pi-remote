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
    private static let sessionJSONL = #"""
{"type":"session","version":3,"id":"native-import-fixture","cwd":"/Users/fixture/project"}
{"type":"message","id":"user-1","parentId":null,"message":{"role":"user","content":"Imported native fixture"}}
{"type":"session_info","id":"name","parentId":"user-1","name":"Imported fixture"}
"""# + "\n"
    private let home = UUID(), project = UUID(), nested = UUID(), root = UUID(), file = UUID()
    private var snapshot: HostSnapshot
    private let unavailable: Bool
    private let streaming: Bool
    private var failRecoveryAnswer: Bool
    private let inspection = ProcessInfo.processInfo.arguments.contains("inspection")
    private let inspectionNext = UUID(), inspectionTextPreview = UUID(), inspectionImagePreview = UUID()
    private var inspectionOrigin: UUID?
    private var streamTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<ClientUpdate>.Continuation] = [:]

    init(phase: String) {
        unavailable = phase == "disconnected"
        streaming = phase == "streaming"
        failRecoveryAnswer = phase == "dialog-recovery"
        var state = HostSnapshot(host: Self.host, epoch: UUID())
        let session = UUID()
        state.selected = session
        state.sessions = [SessionInfo(id: session, title: "Fixture session", directory: "/Users/fixture/project")]
        if phase.hasPrefix("spaces") {
            state.sessions += [
                SessionInfo(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                            title: "Fixture session", directory: "/Users/fixture/project", interrupted: true),
                SessionInfo(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            title: "Other directory session", directory: "/Users/fixture/other/project")
            ]
        }
        if phase == "spaces-empty" { state.sessions = []; state.selected = nil }
        state.phase = phase == "working" || phase == "streaming" || phase == "spaces-working" ? "working" : "idle"
        if phase == "retrying" { state.phase = "retrying" }
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
        if phase == "crashed" {
            state.phase = "interrupted"; state.error = .unknownOutcome
            state.sessions[0].interrupted = true
            state.capabilities = ["sessions", "prompt", "stop", "close-session"]
        }
        if phase == "dialog-recovery" {
            let cached = (0..<12).map { TranscriptMessage(role: "assistant", text: "Cached record \($0). " + String(repeating: "Read this saved text offline. ", count: 16)) }
            state.messages = cached + state.messages
            state.phase = "waiting"
            state.dialogs = [ExtensionDialog(id: "recovery", method: "confirm", title: "Recovery request", message: "The fixture disconnects when the first answer is sent.", options: [], text: "", expires: nil)]
        }
        if phase.hasPrefix("extension-notices") {
            let warning = phase == "extension-notices-long"
                ? "MCP servers need attention:\n" + String(repeating: "Server configuration needs attention.\n", count: 30) + "Run /mcp to fix."
                : "Fixture warning"
            var notices: [ExtensionNotice] = phase == "extension-notices-empty" ? [] : [
                ExtensionNotice(id: "info", text: "Fixture information"),
                ExtensionNotice(id: "warning", text: warning, severity: .warning),
                ExtensionNotice(id: "error", text: "Fixture error", severity: .error)
            ]
            if phase == "extension-notices-recovery" {
                notices.append(ExtensionNotice(id: "recovery", text: "Use Stop, then reopen the saved session.", severity: .warning))
            }
            state.notices = ["Fixture recovery diagnostic", "Fixture status", "Fixture above widget", "Fixture below widget"] + notices.map(\.text)
            state.extensionDisplay = ExtensionDisplayState(
                statuses: [ExtensionStatus(id: "status", text: "Fixture status")],
                widgets: [ExtensionWidget(id: "above", text: "Fixture above widget", placement: .aboveEditor),
                          ExtensionWidget(id: "below", text: "Fixture below widget", placement: .belowEditor)],
                notices: notices)
        }
        if ["tool-details", "tool-details-error", "compact-working"].contains(phase) {
            let call: JSONValue = .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string("Before the tool call.")]),
                .object(["type": .string("toolCall"), "name": .string("bash"), "arguments": .object([
                    "command": .string(String(repeating: "echo fixture; ", count: 100))
                ])]),
                .object(["type": .string("text"), "text": .string("After the tool call.")])
            ])])
            state.messages = [TranscriptReducer.message(call)!,
                              TranscriptMessage(role: "tool", text: "bash\nFixture tool output.", isError: phase == "tool-details-error"),
                              TranscriptMessage(role: "assistant", text: "read {\"path\":\"ordinary prose\"}")]
        }
        if phase == "tool-edit" {
            let call: JSONValue = .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string("I will update the Spaces list.")]),
                .object(["type": .string("toolCall"), "name": .string("edit"), "arguments": .object([
                    "edits": .array([.object(["newText": .string("struct SpaceListView: View {\\n" + String(repeating: "    let state: HostSnapshot\\n", count: 50) + "}")])]),
                    "path": .string("Apps/Shared/SessionViews.swift")
                ])]),
                .object(["type": .string("text"), "text": .string("The explanation stays visible.")])
            ])])
            state.messages = [TranscriptReducer.message(call)!]
            state.messages[0].streaming = true
            state.phase = "working"
        }
        if phase == "compact-working" {
            state.phase = "working"
            state.extensionDisplay = ExtensionDisplayState(notices: [
                ExtensionNotice(id: "warning", text: "Fixture warning", severity: .warning)
            ])
        }
        if phase == "images" {
            state.messages = [TranscriptMessage(role: "tool", text: "Read image\n[Image]", images: [OutputImageReference(id: Self.imageID), OutputImageReference(id: UUID(), fault: .tooLarge)])]
        }
        if phase == "large" {
            let text = String(repeating: "A bounded transcript paragraph. ", count: 60)
            state.messages = (0..<99).map { TranscriptMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Record \($0).\n\n" + text) }
            state.messages.append(TranscriptMessage(role: "tool", text: "Bounded transcript complete"))
        }
        if ["import", "legacy-import", "import-missing-directory"].contains(phase) {
            do {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                var source = Self.sessionJSONL
                if phase == "legacy-import" { source = source.replacingOccurrences(of: "\"version\":3", with: "\"version\":1") }
                if phase == "import-missing-directory" { source = source.replacingOccurrences(of: ",\"cwd\":\"/Users/fixture/project\"", with: "") }
                try Data(source.utf8).write(to: documents.appendingPathComponent("Import fixture.jsonl"))
            } catch { state.error = .storageFailure }
        }
        snapshot = state
        if inspection { inspectionOrigin = state.selected }
    }

    private func directoryPath(_ id: UUID) throws -> String {
        switch id {
        case root: return "/"
        case home: return "/Users/fixture"
        case project: return "/Users/fixture/project"
        case nested: return "/Users/fixture/project/nested"
        default: throw RemoteFault.staleDirectory
        }
    }
    private func inspectionPage(_ cursor: UUID?) throws -> SessionTreePage {
        guard inspection else { throw RemoteFault.unsupportedFeature }
        guard snapshot.selected == inspectionOrigin else { throw RemoteFault.expired }
        guard !snapshot.working else { throw RemoteFault.busy }
        func node(_ id: String, parent: String?, text: String, canFork: Bool, label: String? = nil,
                  timestamp: String? = nil, truncated: Bool = false, preview: UUID? = nil) -> SessionTreeItem {
            SessionTreeItem(node: SessionTreeNode(id: id, parentID: parent, kind: "message", label: label,
                labelTimestamp: timestamp, text: text, truncated: truncated, canFork: canFork), preview: preview)
        }
        if cursor == nil {
            return SessionTreePage(items: [
                node("root", parent: nil, text: "Shared root", canFork: false, label: "Root checkpoint", timestamp: "2024-12-03T14:30:00.125Z"),
                node("abandoned", parent: "root", text: "Abandoned branch preview", canFork: true, truncated: true, preview: inspectionTextPreview),
                node("image-only", parent: "root", text: "[Image]", canFork: false, preview: inspectionImagePreview),
                node("active-leaf", parent: "root", text: "Active assistant response", canFork: false)
            ], leafID: "active-leaf", next: inspectionNext)
        }
        guard cursor == inspectionNext else { throw RemoteFault.expired }
        return SessionTreePage(items: [
            node("whitespace", parent: "root", text: " \n\t", canFork: true),
            node("empty-text", parent: "root", text: "", canFork: false)
        ], leafID: "active-leaf", next: nil)
    }

    private func importCopy(_ data: Data, directory: String? = nil) throws {
        guard !snapshot.working else { throw RemoteFault.busy }
        let value = try SessionImport(data: SessionImport.preparedCopy(of: data, directory: directory))
        guard let path = value.directory else { throw RemoteFault.invalidRequest }
        let session = SessionInfo(id: UUID(), title: value.title, directory: path, interrupted: true)
        snapshot.sessions.append(session); snapshot.selected = session.id
        snapshot.messages = [TranscriptMessage(role: "user", text: "Imported native fixture")]; snapshot.phase = "idle"
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
        if case .answer = action, failRecoveryAnswer {
            failRecoveryAnswer = false
            disconnect(fault: .unavailable)
            throw RemoteFault.unavailable
        }
        if action.mutates {
            if snapshot.error == .unknownOutcome {
                guard case .stop = action else { throw RemoteFault.busy }
            } else { snapshot.error = nil }
        }
        defer { if action.mutates { publish() } }
        switch action {
        case .snapshot: return .snapshot(snapshot)
        case .releaseNotes(let offset, let revision):
            let first = "# Release fixture\nNative page one 🦉"
            let second = "Native page two — final notes"
            let current = String(repeating: "a", count: 64)
            guard revision == nil || revision == current else { throw RemoteFault.expired }
            guard offset == 0 || offset == first.utf8.count else { throw RemoteFault.invalidRequest }
            return .releaseNotes(ReleaseNotesPage(version: "1.3.0", revision: current, offset: offset,
                totalBytes: first.utf8.count + second.utf8.count, text: offset == 0 ? first : second,
                next: offset == 0 ? first.utf8.count : nil))
        case .exportJSONL:
            guard !snapshot.working else { throw RemoteFault.busy }
            return .exportSession(SessionExport(data: Data(Self.sessionJSONL.utf8), format: .jsonl))
        case .exportSession:
            guard !snapshot.working else { throw RemoteFault.busy }
            return .exportSession(SessionExport(data: Data("<!doctype html><html>Private export fixture</html>".utf8)))
        case .lastAssistant: return .preview(FilePreview(name: "Last assistant text", text: "Native copy fixture", truncated: false))
        case .cycleModel:
            guard !snapshot.working else { throw RemoteFault.busy }
            snapshot.model = snapshot.model == snapshot.models[0].id ? snapshot.models[1].id : snapshot.models[0].id
        case .cycleThinking:
            guard !snapshot.working else { throw RemoteFault.busy }
            snapshot.thinking = snapshot.thinking == "low" ? "high" : "low"
        case .autoRetry(let enabled):
            guard !snapshot.working else { throw RemoteFault.busy }
            snapshot.runtime?.acknowledgedAutoRetry = enabled
        case .abortRetry: snapshot.phase = "idle"
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
            guard !snapshot.working, snapshot.error != .unknownOutcome else { throw RemoteFault.busy }
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
        case .directoryAtPath(let path):
            let id: UUID
            switch path {
            case "~", "~/", "/Users/fixture": id = home
            case "/": id = root
            case "~/project", "/Users/fixture/project": id = project
            case "~/project/nested", "/Users/fixture/project/nested": id = nested
            default: throw RemoteFault.staleDirectory
            }
            return try request(.directories(id: id, cursor: nil), context: context)
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
        case .newSession(let parent):
            guard !snapshot.working, let current = snapshot.sessions.first(where: { $0.id == snapshot.selected }) else { throw RemoteFault.busy }
            let session = SessionInfo(id: UUID(), title: parent ? "New child fixture" : "New empty fixture", directory: current.directory)
            snapshot.sessions.append(session); snapshot.selected = session.id
            snapshot.messages = []; snapshot.dialogs = []; snapshot.notices = []; snapshot.draft = nil; snapshot.draftID = nil
            snapshot.phase = "idle"
        case .createSession(let directory):
            guard !snapshot.working else { throw RemoteFault.busy }
            let path = directory == nested ? "/Users/fixture/project/nested" : "/Users/fixture/project"
            let session = SessionInfo(id: UUID(), title: "New fixture session", directory: path)
            snapshot.sessions.append(session); snapshot.selected = session.id; snapshot.messages = []; snapshot.phase = "idle"
            snapshot.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true)
        case .importSession(let data): try importCopy(data)
        case .importSessionInDirectory(let data, let id): try importCopy(data, directory: directoryPath(id))
        case .resumeSession(let id):
            guard !snapshot.working, snapshot.error != .unknownOutcome else { throw RemoteFault.busy }
            snapshot.selected = id; snapshot.phase = "idle"
            snapshot.runtime = RuntimeSettings(steeringMode: .oneAtATime, followUpMode: .oneAtATime, autoCompactionEnabled: true)
        case .prompt(let text, _, _):
            snapshot.messages.append(TranscriptMessage(role: "user", text: text)); snapshot.phase = "working"
        case .stop:
            let crashRecovery = snapshot.phase == "interrupted" && snapshot.error == .unknownOutcome
            snapshot.phase = crashRecovery ? "interrupted" : "idle"
            snapshot.dialogs = []; snapshot.error = nil
            for index in snapshot.messages.indices { snapshot.messages[index].streaming = false }
        case .model(let provider, let id): snapshot.model = provider + "/" + id
        case .thinking(let level): snapshot.thinking = level
        case .rename(let name):
            if let index = snapshot.sessions.firstIndex(where: { $0.id == snapshot.selected }) { snapshot.sessions[index].title = name }
        case .compact(let instructions):
            guard !snapshot.working, instructions.utf8.count <= 16_384 else { throw RemoteFault.invalidRequest }
            snapshot.notices = ["Compaction fixture completed."]
            if !instructions.isEmpty { snapshot.notices.append("Summary instructions: " + instructions) }
        case .command:
            snapshot.dialogs = [ExtensionDialog(id: "fixture-editor", method: "editor", title: "Fixture editor", message: "Review this text before submitting it.", options: [], text: "Fixture editor text", expires: nil)]
        case .answer: snapshot.dialogs = []
        case .diff: return .preview(FilePreview(name: "Working tree diff", text: "+ let fixture = 42", truncated: false))
        case .sessionTree(let cursor): return .sessionTree(try inspectionPage(cursor))
        case .historyEntry(let id):
            guard inspection else { throw RemoteFault.unsupportedFeature }
            guard snapshot.selected == inspectionOrigin else { throw RemoteFault.expired }
            if id == inspectionTextPreview {
                return .preview(FilePreview(name: "Abandoned entry", text: "Abandoned branch full entry. Exact full preview beyond abbreviated tree text.", truncated: false))
            }
            guard id == inspectionImagePreview else { throw RemoteFault.expired }
            return .preview(FilePreview(name: "Image-only entry", text: "[Image]", truncated: false, images: [OutputImageReference(id: Self.imageID)]))
        case .fork(let entry):
            guard inspection else { throw RemoteFault.unsupportedFeature }
            guard snapshot.selected == inspectionOrigin, !snapshot.working else { throw RemoteFault.conflict }
            guard ["abandoned", "whitespace"].contains(entry) else { throw RemoteFault.invalidRequest }
            let branch = SessionInfo(id: UUID(), title: "Inspection fork", directory: "/Users/fixture/project")
            snapshot.sessions.append(branch); snapshot.selected = branch.id
            snapshot.messages = [TranscriptMessage(role: "user", text: "Shared root")]
            snapshot.draft = entry == "abandoned" ? "Abandoned branch draft; not sent." : " \n\t"
            snapshot.draftID = UUID()
        case .historyPage: return .historyPage(HistoryPage(items: [], next: nil))
        default: throw RemoteFault.unsupportedFeature
        }
        return .ok
    }
}
