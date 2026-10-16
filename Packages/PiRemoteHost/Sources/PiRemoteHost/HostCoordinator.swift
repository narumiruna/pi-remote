import Darwin
import Foundation
import PiRPC
import PiRemoteCore
import PiRemoteSecurity

public actor HostCoordinator {
    private struct ManagedSession: Codable {
        var info: SessionInfo
        var directory: RegisteredPath
        var piID: String
        var folder: URL
        var file: URL?
        var hasHistory: Bool?
    }
    public nonisolated let hostID: UUID
    public nonisolated let epoch: UUID
    public let directories: DirectoryRegistry
    private let support: URL
    private let instanceLease: InstanceLease
    private var executable: URL
    private var sessions: [ManagedSession]
    private var snapshot: HostSnapshot
    private var reducer = TranscriptReducer()
    private var outputImages = OutputImages()
    private let history = SessionHistory()
    private var rpc: RPCProcess?
    private var observer: Task<Void, Never>?
    private var generation = UUID()
    private var runRevision: UInt64 = 0
    private var observers: [UUID: AsyncStream<HostSnapshot>.Continuation] = [:]
    private var journal: RequestJournal
    private var replay = StateReplay()
    private var mutations: Set<UUID> = []
    private var closing = false
    private var utility: Task<(Data, Bool), any Error>?
    private var dialogDeadlines: [String: TimeInterval] = [:]
    private var statuses: [String: String] = [:]
    private var notifications: [String] = []
    private var lastPublish = ContinuousClock.now
    private var scheduledPublish: Task<Void, Never>?

    public init(support: URL, executable: URL, directories: DirectoryRegistry = DirectoryRegistry()) throws {
        instanceLease = try InstanceLease(support: support)
        self.support = support; self.executable = executable; self.directories = directories
        hostID = try PrivateFiles.read(UUID.self, from: support.appendingPathComponent("host.json")) ?? UUID()
        try PrivateFiles.write(hostID, to: support.appendingPathComponent("host.json"))
        epoch = UUID()
        sessions = try PrivateFiles.read([ManagedSession].self, from: support.appendingPathComponent("sessions.json")) ?? []
        snapshot = HostSnapshot(host: hostID, epoch: epoch)
        snapshot.sessions = sessions.map(\.info).sorted { $0.updated > $1.updated }
        journal = RequestJournal(epoch: epoch)
        // Previous-epoch requests cannot be dispatched again, even after a crash during acceptance.
        try PrivateFiles.write(journal, to: support.appendingPathComponent("requests.json"))
    }

    public func state() -> HostSnapshot { snapshot }
    public func inspectPi() async {
        guard rpc == nil, !closing, mutations.isEmpty, utility == nil else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        do {
            let output = try await runUtility(executable.path, ["--version"], directory: support, limit: 256, environment: environment)
            snapshot.piVersion = String(decoding: output.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { snapshot.piVersion = "Unavailable"; snapshot.error = .unavailable }
        publish()
    }
    public func setExecutable(_ url: URL) throws {
        guard rpc == nil, mutations.isEmpty, utility == nil, !closing else { throw RemoteFault.busy }
        executable = url
    }

    public func updates() -> AsyncStream<HostSnapshot> {
        let id = UUID()
        let stream = AsyncStream<HostSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        stream.continuation.yield(snapshot)
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    public func handle(_ request: AppRequest, device: UUID, authorization: AuthorizationLease? = nil) async -> AppResult {
        guard !closing, authorization?.valid ?? true, !Task.isCancelled else { return .failure(.unauthorized) }
        guard request.epoch == epoch else { return .failure(.unknownOutcome) }
        guard !request.action.needsSession || (request.session != nil && request.session == snapshot.selected) else {
            return .failure(.conflict)
        }
        if request.action.mutates {
            do {
                switch try journal.begin(device: device, request: request) {
                case .completed(let fault): return fault.map(AppResult.failure) ?? .ok
                case .unknown: return .failure(.unknownOutcome)
                case .dispatch: try saveJournal()
                }
            } catch { return .failure(error as? RemoteFault ?? .storageFailure) }
        }
        do {
            guard authorization?.valid ?? true, !Task.isCancelled else { throw RemoteFault.unauthorized }
            let result = try await perform(request)
            if request.action.mutates {
                journal.finish(device: device, request: request, fault: nil)
                try saveJournal()
            }
            publish()
            return result
        } catch {
            let fault: RemoteFault
            if let value = error as? RemoteFault { fault = value }
            else if let value = error as? RPCFailure {
                switch value {
                case .unknownOutcome, .closed: fault = .unknownOutcome
                case .rejected: fault = .invalidRequest
                case .providerAuthenticationRequired: fault = .providerAuthenticationRequired
                default: fault = .unavailable
                }
            } else { fault = .unavailable }
            if request.action.mutates {
                journal.finish(device: device, request: request, fault: fault)
                do { try saveJournal() } catch { return .failure(.unknownOutcome) }
            }
            if snapshot.phase == "starting" && rpc == nil { snapshot.phase = "unavailable" }
            if snapshot.phase == "compacting", fault == .invalidRequest || fault == .providerAuthenticationRequired {
                snapshot.phase = reducer.phase
            }
            snapshot.error = fault; publish()
            return .failure(fault)
        }
    }

    private func perform(_ request: AppRequest) async throws -> AppResult {
        let action = request.action
        if action.mutates || action.needsSession {
            let priority: Bool
            switch action { case .stop, .answer: priority = true; default: priority = false }
            guard priority || mutations.isEmpty else { throw RemoteFault.busy }
            mutations.insert(request.id)
        }
        defer { mutations.remove(request.id) }
        if action.mutates { snapshot.error = nil }
        switch action {
        case .snapshot: return .snapshot(snapshot)
        case .outputImage(let id): return .image(try outputImages.image(id))
        case .statistics:
            let data = try await requireRPC().request("get_session_stats")
            let statistics: SessionStatistics
            do { statistics = try JSONDecoder().decode(SessionStatistics.self, from: JSONEncoder().encode(data)) }
            catch { throw RemoteFault.incompatiblePi }
            try statistics.validate()
            return .statistics(statistics)
        case .synchronize(let epoch, let after):
            return .synchronized(replay.synchronize(current: snapshot, epoch: epoch, after: after))
        case .directories(let id, let cursor): return .directories(try await directories.list(id: id, cursor: cursor))
        case .preview(let id): return .preview(try await directories.preview(id))
        case .createSession(let id):
            guard !snapshot.working, sessions.count < 256 else { throw RemoteFault.busy }
            try await requireIdle()
            let directory = try await directories.resolve(id)
            let sessionID = UUID()
            let folder = support.appendingPathComponent("pi-sessions/" + sessionID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let item = ManagedSession(
                info: SessionInfo(id: sessionID, title: directory.url.lastPathComponent, directory: directory.url.path),
                directory: directory, piID: sessionID.uuidString, folder: folder, file: nil, hasHistory: false
            )
            sessions.append(item); try saveSessions()
            try await activate(sessionID)
        case .resumeSession(let id):
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            try await activate(id)
        case .prompt(let text, let delivery, let image):
            let child = try requireRPC()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil,
                  text.utf8.count <= 256 * 1_024 else { throw RemoteFault.invalidRequest }
            guard snapshot.phase != "starting", snapshot.phase != "stopping" else { throw RemoteFault.busy }
            if text.hasPrefix("/") {
                let name = String(text.dropFirst().prefix { !$0.isWhitespace })
                guard snapshot.commands.contains(where: { $0.name == name }) else { throw RemoteFault.unsupportedFeature }
            }
            var fields: [String: JSONValue] = ["message": .string(text)]
            if let image {
                guard image.data.count <= 2 * 1_024 * 1_024, ["image/png", "image/jpeg", "image/webp"].contains(image.mimeType) else {
                    throw RemoteFault.tooLarge
                }
                fields["images"] = .array([.object(["type": .string("image"), "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mimeType)])])
            }
            if snapshot.working {
                guard delivery != .prompt else { throw RemoteFault.busy }
                fields["streamingBehavior"] = .string(delivery == .steer ? "steer" : "followUp")
            } else if delivery != .prompt { throw RemoteFault.invalidRequest }
            let previous = selectedIndex.map { sessions[$0] }
            let token = generation, revision = runRevision
            try markInterrupted(true)
            let result: JSONValue
            do { result = try await child.request("prompt", fields: fields) }
            catch {
                // A failed response rejects this prompt before acceptance. Do not undo
                // run events or process-exit recovery that arrived while awaiting it.
                if let failure = error as? RPCFailure,
                   failure == .providerAuthenticationRequired || failure == .rejected("prompt"),
                   token == generation, revision == runRevision,
                   let previous, let index = selectedIndex, sessions[index].info.id == previous.info.id {
                    sessions[index].info.interrupted = previous.info.interrupted
                    sessions[index].hasHistory = previous.hasHistory
                    try saveSessions()
                }
                throw error
            }
            if result["disposition"]?.string == "handled", !snapshot.working { try markInterrupted(false) }
        case .stop:
            guard snapshot.phase != "starting" else { throw RemoteFault.busy }
            let child = try requireRPC()
            snapshot.phase = "stopping"; publish()
            _ = try await child.request("clear_queue")
            for dialog in snapshot.dialogs { try await child.answerDialog(id: dialog.id, value: nil, confirmed: nil, cancelled: true) }
            snapshot.dialogs = []; dialogDeadlines = [:]
            try await child.stopWork()
            snapshot.phase = "idle"; try markInterrupted(false)
        case .model(let provider, let id):
            guard !snapshot.working, snapshot.models.contains(where: { $0.provider == provider && $0.model == id }) else { throw RemoteFault.busy }
            try await requireIdle()
            _ = try await requireRPC().request("set_model", fields: ["provider": .string(provider), "modelId": .string(id)])
            try await refreshConfiguration()
        case .thinking(let level):
            guard !snapshot.working, snapshot.thinkingLevels.contains(level) else { throw RemoteFault.invalidRequest }
            try await requireIdle()
            _ = try await requireRPC().request("set_thinking_level", fields: ["level": .string(level)])
            try await refreshConfiguration()
        case .compact(let instructions):
            guard !snapshot.working, instructions.utf8.count <= 16_384 else { throw RemoteFault.busy }
            try await requireIdle()
            let child = try requireRPC()
            snapshot.phase = "compacting"; publish()
            _ = try await child.request("compact", fields: ["customInstructions": .string(instructions)], timeout: 300)
            snapshot.phase = "idle"
            try await refreshHistory()
        case .rename(let name):
            guard !snapshot.working, !name.isEmpty, name.utf8.count <= 256 else { throw RemoteFault.invalidRequest }
            try await requireIdle()
            _ = try await requireRPC().request("set_session_name", fields: ["name": .string(name)])
            if let index = selectedIndex { sessions[index].info.title = name; try saveSessions() }
        case .history:
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            let result = try await requireRPC().request("get_entries")
            let entries = result["entries"]?.array ?? []
            return .history(entries.suffix(1_000).compactMap { raw in
                guard let id = raw["id"]?.string else { return nil }
                let message = raw["message"].flatMap(TranscriptReducer.message)
                return HistoryItem(id: id, parent: raw["parentId"]?.string, kind: raw["type"]?.string ?? "entry",
                                   text: DisplayLimit.text(message?.text ?? raw["summary"]?.string ?? "Session entry", bytes: 512),
                                   canFork: raw["message"]?["role"]?.string == "user")
            })
        case .historyPage(let cursor):
            guard !snapshot.working, let index = selectedIndex else { throw RemoteFault.busy }
            try await requireIdle()
            let item = sessions[index]
            var file = item.file
            if let value = file {
                try validateSessionFile(value)
                if !FileManager.default.fileExists(atPath: value.path), item.hasHistory == false { file = nil }
            }
            return .historyPage(try await history.page(session: item.info.id, file: file, cursor: cursor))
        case .historyEntry(let id):
            guard !snapshot.working, let session = snapshot.selected else { throw RemoteFault.busy }
            try await requireIdle()
            let entry = try await history.displayEntry(session: session, id: id)
            var preview = entry.preview
            if let message = entry.message {
                let display = outputImages.message(message)
                preview.images = TranscriptReducer.imageReferences(display["content"])
                if (message["content"]?.array ?? []).filter({ $0["type"]?.string == "image" }).count > 16 { preview.truncated = true }
            }
            return .preview(preview)
        case .fork(let entry):
            guard !snapshot.working, entry.utf8.count <= 128 else { throw RemoteFault.busy }
            try await requireIdle()
            let result = try await requireRPC().request("fork", fields: ["entryId": .string(entry)])
            guard result["cancelled"]?.bool != true else { throw RemoteFault.cancelled }
            snapshot.draft = result["text"]?.string; snapshot.draftID = UUID()
            try await adoptBranch()
        case .clone:
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            let result = try await requireRPC().request("clone")
            guard result["cancelled"]?.bool != true else { throw RemoteFault.cancelled }
            snapshot.draft = nil; snapshot.draftID = nil
            try await adoptBranch()
        case .command(let name, let arguments):
            guard !snapshot.working, snapshot.commands.contains(where: { $0.name == name }), arguments.utf8.count <= 16_384 else {
                throw RemoteFault.unsupportedFeature
            }
            try await requireIdle()
            _ = try await requireRPC().request("prompt", fields: ["message": .string("/" + name + (arguments.isEmpty ? "" : " " + arguments))])
        case .answer(let id, let value, let confirmed, let cancelled):
            guard let dialog = snapshot.dialogs.first(where: { $0.id == id }),
                  dialogDeadlines[id].map({ $0 > ProcessInfo.processInfo.systemUptime }) ?? true,
                  (value?.utf8.count ?? 0) <= 65_536 else { throw RemoteFault.expired }
            if dialog.method == "unavailable", !cancelled { throw RemoteFault.tooLarge }
            if dialog.method == "confirm", !cancelled, confirmed == nil { throw RemoteFault.invalidRequest }
            if ["input", "editor"].contains(dialog.method), !cancelled, value == nil { throw RemoteFault.invalidRequest }
            if dialog.method == "select", !cancelled, !dialog.options.contains(value ?? "") { throw RemoteFault.invalidRequest }
            try await requireRPC().answerDialog(id: id, value: value, confirmed: confirmed, cancelled: cancelled)
            snapshot.dialogs.removeAll { $0.id == id }; dialogDeadlines.removeValue(forKey: id)
            snapshot.phase = snapshot.dialogs.isEmpty ? reducer.phase : "waiting"
        case .diff:
            guard !snapshot.working, let index = selectedIndex else { throw RemoteFault.busy }
            let result = try await runUtility("/usr/bin/git", ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "diff", "--no-ext-diff", "--no-textconv", "--"], directory: sessions[index].directory.url, limit: 256 * 1_024)
            return .preview(FilePreview(name: "Working tree diff", text: String(decoding: result.0, as: UTF8.self), truncated: result.1))
        }
        return .ok
    }

    private func runUtility(_ path: String, _ arguments: [String], directory: URL, limit: Int = 1_048_576, environment: [String: String]? = nil) async throws -> (Data, Bool) {
        guard !closing else { throw RemoteFault.cancelled }
        guard utility == nil else { throw RemoteFault.busy }
        let operation = Task { try await LocalCommand.run(path, arguments, directory: directory, limit: limit, environment: environment) }
        utility = operation
        defer { utility = nil }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }

    private func requireIdle() async throws {
        guard let rpc else { return }
        let state = try await rpc.request("get_state")
        guard state["isStreaming"]?.bool == false, state["isCompacting"]?.bool == false,
              state["pendingMessageCount"] == .number(0) else { throw RemoteFault.busy }
    }

    private var selectedIndex: Int? { sessions.firstIndex { $0.info.id == snapshot.selected } }
    private func requireRPC() throws -> RPCProcess { guard let rpc else { throw RemoteFault.unavailable }; return rpc }

    private func activate(_ id: UUID) async throws {
        guard let index = sessions.firstIndex(where: { $0.info.id == id }) else { throw RemoteFault.staleDirectory }
        try DirectoryRegistry.validateDirectory(sessions[index].directory)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw RemoteFault.unavailable }
        let previous = rpc
        generation = UUID()
        let activation = generation
        observer?.cancel(); rpc = nil
        snapshot.phase = "starting"; snapshot.selected = id; snapshot.messages = []; snapshot.dialogs = []
        snapshot.draft = nil; snapshot.draftID = nil; outputImages = OutputImages()
        dialogDeadlines = [:]; statuses = [:]; notifications = []; publish()
        if let previous, !(await previous.shutdown()) { throw RemoteFault.unavailable }
        guard !closing, generation == activation else { throw RemoteFault.cancelled }
        let item = sessions[index]
        try DirectoryRegistry.validateDirectory(item.directory)
        _ = try sessionArguments(item)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let version = try await runUtility(executable.path, ["--version"], directory: item.directory.url, limit: 256, environment: environment)
        snapshot.piVersion = String(decoding: version.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !closing, generation == activation, !Task.isCancelled else { throw RemoteFault.cancelled }
        // Shutdown and executable inspection suspend this actor. Recheck paths before launch.
        try DirectoryRegistry.validateDirectory(item.directory)
        let child = try RPCProcess(executable: executable, arguments: sessionArguments(item), workingDirectory: item.directory.url, environment: environment)
        rpc = child
        let token = generation
        observer = Task { [weak self] in
            do {
                for try await event in child.events { await self?.consume(event, generation: token) }
                await self?.processEnded(token)
            } catch { await self?.processEnded(token) }
        }
        do {
            try await refreshConfiguration()
            try await refreshHistory()
            guard !closing, generation == activation else { throw RemoteFault.cancelled }
            snapshot.phase = "idle"
            sessions[index].info.updated = Date(); try saveSessions()
        } catch {
            generation = UUID(); observer?.cancel(); rpc = nil
            await child.shutdown(); snapshot.phase = "unavailable"; publish()
            throw error
        }
        publish()
    }

    private func sessionArguments(_ item: ManagedSession) throws -> [String] {
        var args = ["--mode", "rpc", "--session-dir", item.folder.path]
        if let file = item.file, FileManager.default.fileExists(atPath: file.path) {
            try validateSessionFile(file)
            try validateSessionHeader(file, session: item)
            args += ["--session", file.path]
        } else if item.file != nil && item.hasHistory != false {
            throw RemoteFault.staleDirectory
        } else { args += ["--session-id", item.piID] }
        return args
    }

    private func refreshConfiguration() async throws {
        let child = try requireRPC()
        let state = try await child.request("get_state")
        let models = try await child.request("get_available_models")
        let levels = try await child.request("get_available_thinking_levels")
        let commands = try await child.request("get_commands")
        snapshot.models = (models["models"]?.array ?? []).prefix(256).compactMap {
            guard let id = $0["id"]?.string, let provider = $0["provider"]?.string else { return nil }
            guard provider.utf8.count <= 128, id.utf8.count <= 256 else { return nil }
            return ModelOption(provider: provider, model: id, name: DisplayLimit.text($0["name"]?.string ?? id, bytes: 128))
        }
        snapshot.thinkingLevels = (levels["levels"]?.array ?? []).compactMap(\.string)
        snapshot.model = (state["model"]?["provider"]?.string ?? "") + "/" + (state["model"]?["id"]?.string ?? "")
        snapshot.thinking = state["thinkingLevel"]?.string ?? "off"
        snapshot.commands = (commands["commands"]?.array ?? []).prefix(256).compactMap {
            guard let name = $0["name"]?.string, name.utf8.count <= 128 else { return nil }
            return CommandOption(name: name, detail: DisplayLimit.text($0["description"]?.string ?? "", bytes: 256), source: DisplayLimit.text($0["source"]?.string ?? "extension", bytes: 32))
        }
        if let index = selectedIndex, let file = state["sessionFile"]?.string {
            let url = URL(fileURLWithPath: file)
            try validateSessionFile(url)
            sessions[index].file = url
            sessions[index].piID = state["sessionId"]?.string ?? sessions[index].piID
            try saveSessions()
        }
    }

    private func refreshHistory() async throws {
        let data = try await requireRPC().request("get_messages")
        reducer = TranscriptReducer()
        let messages = (data["messages"]?.array ?? []).map { outputImages.message($0) }
        reducer.replaceHistory(messages)
        snapshot.messages = reducer.messages; snapshot.hasOlderMessages = reducer.omitted
    }

    private func adoptBranch() async throws {
        guard let old = selectedIndex else { throw RemoteFault.unavailable }
        let data = try await requireRPC().request("get_state")
        guard let file = data["sessionFile"]?.string, let piID = data["sessionId"]?.string else { throw RemoteFault.incompatiblePi }
        let url = URL(fileURLWithPath: file); try validateSessionFile(url)
        let info = SessionInfo(id: UUID(), title: "Branch — " + sessions[old].info.title, directory: sessions[old].info.directory)
        sessions.append(ManagedSession(info: info, directory: sessions[old].directory, piID: piID, folder: sessions[old].folder, file: url, hasHistory: true))
        snapshot.selected = info.id; outputImages = OutputImages(); try saveSessions(); try await refreshHistory()
    }

    private func validateSessionFile(_ url: URL) throws {
        let root = support.appendingPathComponent("pi-sessions", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(root), url.pathExtension == "jsonl" else { throw RemoteFault.incompatiblePi }
    }

    private func validateSessionHeader(_ url: URL, session: ManagedSession) throws {
        do {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw RemoteFault.permissionDenied }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RemoteFault.incompatiblePi }
            let bytes = try handle.read(upToCount: 65_536) ?? Data()
            guard let end = bytes.firstIndex(of: 10),
                  let header = try? JSONDecoder().decode(JSONValue.self, from: bytes[..<end]),
                  header["type"]?.string == "session", header["id"]?.string == session.piID,
                  let cwd = header["cwd"]?.string, cwd.hasPrefix("/"),
                  (try? DirectoryRegistry.identify(URL(fileURLWithPath: cwd))) == session.directory else {
                throw RemoteFault.incompatiblePi
            }
        } catch let fault as RemoteFault { throw fault }
        catch { throw RemoteFault.permissionDenied }
    }

    private func markInterrupted(_ flag: Bool) throws {
        if let index = selectedIndex {
            sessions[index].info.interrupted = flag
            if flag { sessions[index].hasHistory = true }
            sessions[index].info.updated = Date(); try saveSessions()
        }
    }
    private func saveSessions() throws {
        try PrivateFiles.write(sessions, to: support.appendingPathComponent("sessions.json"))
        snapshot.sessions = sessions.map(\.info).sorted { $0.updated > $1.updated }
    }
    private func saveJournal() throws { try PrivateFiles.write(journal, to: support.appendingPathComponent("requests.json")) }

    private func consume(_ event: JSONValue, generation token: UUID) {
        guard token == generation else { return }
        reducer.consume(outputImages.event(event))
        snapshot.messages = reducer.messages
        if snapshot.phase != "starting" && snapshot.phase != "stopping" { snapshot.phase = reducer.phase }
        snapshot.hasOlderMessages = reducer.omitted
        if event["type"]?.string == "agent_start" {
            runRevision &+= 1
            do { try markInterrupted(true) } catch { snapshot.error = .storageFailure }
        }
        if event["type"]?.string == "agent_settled" {
            runRevision &+= 1
            do { try markInterrupted(false) } catch { snapshot.error = .storageFailure }
        }
        if event["type"]?.string == "extension_ui_request" { extensionEvent(event) }
        if event["type"]?.string == "extension_error" { snapshot.error = .unsupportedFeature }
        if event["type"]?.string == "message_end", event["message"]?["stopReason"]?.string == "error" {
            snapshot.error = RPCFailure.isProviderAuthenticationError(event["message"]?["errorMessage"]?.string ?? "")
                ? .providerAuthenticationRequired : .unavailable
        }
        if event["type"]?.string == "session_info_changed", let name = event["name"]?.string, let index = selectedIndex {
            sessions[index].info.title = DisplayLimit.text(name, bytes: 256); try? saveSessions()
        }
        if !snapshot.dialogs.isEmpty && snapshot.phase != "starting" && snapshot.phase != "stopping" { snapshot.phase = "waiting" }
        if ContinuousClock.now - lastPublish > .milliseconds(100) || event["type"]?.string == "agent_settled" { publish() }
        else if scheduledPublish == nil {
            scheduledPublish = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100)); await self?.publishScheduled()
            }
        }
    }

    private func extensionEvent(_ event: JSONValue) {
        let method = event["method"]?.string ?? ""
        if ["select", "confirm", "input", "editor"].contains(method), let id = event["id"]?.string {
            guard id.utf8.count <= 128 else { snapshot.error = .incompatiblePi; return }
            guard snapshot.dialogs.count < 8 else {
                snapshot.error = .capacity
                let child = rpc
                Task { try? await child?.answerDialog(id: id, value: nil, confirmed: nil, cancelled: true) }
                return
            }
            let title = event["title"]?.string ?? method
            let message = event["message"]?.string ?? event["placeholder"]?.string ?? ""
            let options = (event["options"]?.array ?? []).compactMap(\.string)
            let prefill = event["prefill"]?.string ?? ""
            let oversized = title.utf8.count > 512 || message.utf8.count > 4_096 || prefill.utf8.count > 65_536 ||
                options.count > 64 || options.contains { $0.utf8.count > 1_024 }
            var expires: Date?
            if case .number(let milliseconds) = event["timeout"], milliseconds >= 0, milliseconds <= 86_400_000 {
                let interval = milliseconds / 1_000
                expires = Date().addingTimeInterval(interval)
                let deadline = ProcessInfo.processInfo.systemUptime + interval
                dialogDeadlines[id] = deadline
                let token = generation
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int64(milliseconds)))
                    await self?.expireDialog(id, generation: token)
                }
            }
            snapshot.dialogs.append(ExtensionDialog(
                id: id, method: oversized ? "unavailable" : method,
                title: oversized ? "Dialog exceeds the display limit" : title,
                message: oversized ? "Cancel this request; no text or options will be submitted automatically." : message,
                options: oversized ? [] : options, text: oversized ? "" : prefill, expires: expires
            ))
        } else if method == "set_editor_text" {
            let text = event["text"]?.string ?? ""
            if text.utf8.count <= 256 * 1_024 { snapshot.draft = text; snapshot.draftID = UUID() }
            else { snapshot.error = .tooLarge }
        } else if method == "setStatus" || method == "setWidget" {
            let key = event["statusKey"]?.string ?? event["widgetKey"]?.string ?? method
            let text = event["statusText"]?.string ?? (event["widgetLines"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
            if text.isEmpty { statuses.removeValue(forKey: key) }
            else if statuses.count < 16 || statuses[key] != nil { statuses[key] = DisplayLimit.text(text, bytes: 2_048) }
        } else {
            let text = event["message"]?.string ?? event["title"]?.string ?? ""
            if !text.isEmpty { notifications.append(DisplayLimit.text(text, bytes: 2_048)); notifications = Array(notifications.suffix(8)) }
        }
        snapshot.notices = Array(statuses.values.prefix(16)) + notifications
    }

    private func expireDialog(_ id: String, generation token: UUID) {
        guard token == generation, let deadline = dialogDeadlines[id], deadline <= ProcessInfo.processInfo.systemUptime else { return }
        snapshot.dialogs.removeAll { $0.id == id }; dialogDeadlines.removeValue(forKey: id)
        if snapshot.phase == "waiting" { snapshot.phase = snapshot.dialogs.isEmpty ? reducer.phase : "waiting" }
        publish()
    }

    private func processEnded(_ token: UUID) {
        guard token == generation else { return }
        runRevision &+= 1
        rpc = nil; snapshot.phase = "interrupted"; snapshot.error = .unavailable
        snapshot.dialogs = []; dialogDeadlines = [:]
        do { try markInterrupted(true) } catch { snapshot.error = .storageFailure }
        publish()
    }
    private func publishScheduled() { scheduledPublish = nil; publish() }
    private func publish() {
        snapshot.sequence &+= 1; lastPublish = .now
        replay.append(snapshot)
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    public func shutdown() async {
        closing = true
        utility?.cancel()
        if let utility { _ = await utility.result }
        self.utility = nil
        generation = UUID(); observer?.cancel(); observer = nil
        scheduledPublish?.cancel(); scheduledPublish = nil
        if snapshot.working { try? markInterrupted(true) }
        let child = rpc; rpc = nil
        if let child { _ = await child.shutdown() }
        snapshot.phase = "unavailable"; publish()
    }
}
