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
        // Pi does not persist an empty session. Keep confirmed ancestry until reopen.
        var parentFile: URL? = nil
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
    private struct InspectionContext {
        var session: UUID
        var generation: UUID
        var revision: UInt64
    }
    private struct CachedInspection {
        var context: InspectionContext
        var tree: SessionTreeInspection
        var file: URL?
        var fileRevision: String?
        var created = ProcessInfo.processInfo.systemUptime
    }
    private struct InspectionCursor {
        var inspection: UUID
        var offset: Int
        var created = ProcessInfo.processInfo.systemUptime
    }
    private var inspections: [UUID: CachedInspection] = [:]
    private var inspectionCursors: [UUID: InspectionCursor] = [:]
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
    private var recoveringEvents = false
    private var recoveryNotice: String?
    private var lifecycleTransition: UUID?
    private var lifecycleUI: [JSONValue] = []
    private var lifecycleUIOverflow = false
    private var lifecycleNameReadBack = false
    private var lifecycleNameRefresh: Task<Void, Never>?
    private var lifecycleNameVersion: UInt64 = 0
    private var historyNeedsRefresh = false
    private var historyRefresh: Task<Void, Never>?
    private var lastPublish = ContinuousClock.now
    private var scheduledPublish: Task<Void, Never>?

    private let rpcEventCapacity: Int

    public init(support: URL, executable: URL, directories: DirectoryRegistry = DirectoryRegistry()) throws {
        try self.init(support: support, executable: executable, directories: directories, rpcEventCapacity: 256)
    }

    // Internal seam for deterministic overflow tests; no remote or user setting changes this limit.
    init(support: URL, executable: URL, directories: DirectoryRegistry, rpcEventCapacity: Int) throws {
        precondition(rpcEventCapacity > 0)
        self.rpcEventCapacity = rpcEventCapacity
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
        do {
            let environment = PiLaunchEnvironment.make(executable: executable)
            try PiLaunchEnvironment.validate(executable: executable, environment: environment)
            snapshot.piVersion = try await inspectVersion(directory: support, environment: environment)
            if snapshot.error == .piLaunchFailed || snapshot.error == .nodeUnavailable { snapshot.error = nil }
        } catch { snapshot.piVersion = "Unavailable"; snapshot.error = error as? RemoteFault ?? .piLaunchFailed }
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
        switch request.action {
        case .newSession, .fork, .clone: break // Completed replacements precede their now-stale session binding.
        default:
            guard !request.action.needsSession || (request.session != nil && request.session == snapshot.selected) else { return .failure(.conflict) }
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
            // A completed native New request remains deduplicated after selected changes.
            guard !request.action.needsSession || (request.session != nil && request.session == snapshot.selected) else {
                throw RemoteFault.conflict
            }
            let result = try await perform(request)
            if request.action.mutates {
                journal.finish(device: device, request: request, fault: nil)
                try saveJournal()
            }
            scheduleHistoryRefresh()
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
                snapshot.phase = displayPhase
            }
            snapshot.error = fault; publish()
            return .failure(fault)
        }
    }

    private func perform(_ request: AppRequest) async throws -> AppResult {
        let action = request.action
        if recoveringEvents, action.mutates, action != .stop { throw RemoteFault.busy }
        if action.mutates || action.needsSession {
            let priority: Bool
            switch action { case .stop, .answer, .abortRetry: priority = true; default: priority = false }
            guard priority || mutations.isEmpty else { throw RemoteFault.busy }
            mutations.insert(request.id)
        }
        defer { mutations.remove(request.id) }
        if action.mutates { snapshot.error = nil }
        switch action {
        case .snapshot: return .snapshot(snapshot)
        case .releaseNotes(let offset, let revision):
            return .releaseNotes(try PiReleaseNotes.page(executable: executable, offset: offset, revision: revision))
        case .outputImage(let id): return .image(try outputImages.image(id))
        case .lastAssistant:
            let data = try await requireRPC().request("get_last_assistant_text")
            guard case .object = data else { throw RemoteFault.incompatiblePi }
            let text: String
            // Pi 1.3.0 omits undefined text; the reference also permits null.
            if data["text"] == nil || data["text"] == .null { text = "" }
            else if let value = data["text"]?.string { text = value }
            else { throw RemoteFault.incompatiblePi }
            return .preview(FilePreview(name: "Last assistant text", text: DisplayLimit.text(text, bytes: 256 * 1_024), truncated: text.utf8.count > 256 * 1_024))
        case .runtimeSettings:
            let value = try await refreshRuntime()
            return .runtimeSettings(value)
        case .queueMode(let kind, let mode):
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            let command = kind == .steering ? "set_steering_mode" : "set_follow_up_mode"
            _ = try await requireRPC().request(command, fields: ["mode": .string(mode.rawValue)])
            let applied = try await refreshRuntime()
            guard (kind == .steering ? applied.steeringMode : applied.followUpMode) == mode else { throw RemoteFault.conflict }
        case .autoCompaction(let enabled):
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            _ = try await requireRPC().request("set_auto_compaction", fields: ["enabled": .bool(enabled)])
            let applied = try await refreshRuntime()
            guard applied.autoCompactionEnabled == enabled else { throw RemoteFault.conflict }
        case .autoRetry(let enabled):
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            var value = try await refreshRuntime()
            _ = try await requireRPC().request("set_auto_retry", fields: ["enabled": .bool(enabled)])
            value.acknowledgedAutoRetry = enabled
            snapshot.runtime = value
        case .abortRetry:
            _ = try await requireRPC().request("abort_retry")
        case .closeSession:
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            snapshot.phase = "stopping"; publish()
            generation = UUID(); observer?.cancel(); observer = nil
            lifecycleNameRefresh?.cancel(); lifecycleNameRefresh = nil; lifecycleNameReadBack = false
            lifecycleUI = []; lifecycleUIOverflow = false
            historyRefresh?.cancel(); historyRefresh = nil; historyNeedsRefresh = false
            scheduledPublish?.cancel(); scheduledPublish = nil
            if let child = rpc, !(await child.shutdown()) {
                preserveUnconfirmedShutdown(child, selected: snapshot.selected)
                throw RemoteFault.unavailable
            }
            rpc = nil; reducer = TranscriptReducer(); outputImages = OutputImages()
            recoveringEvents = false; recoveryNotice = nil
            snapshot.selected = nil; snapshot.phase = "idle"; snapshot.messages = []; snapshot.dialogs = []
            snapshot.model = ""; snapshot.thinking = ""; snapshot.models = []; snapshot.thinkingLevels = []; snapshot.commands = []
            snapshot.runtime = nil; snapshot.pendingMessages = nil; snapshot.draft = nil; snapshot.draftID = nil; snapshot.notices = []; snapshot.hasOlderMessages = false
            dialogDeadlines = [:]; statuses = [:]; notifications = []
        case .exportSession:
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            return .exportSession(try await SessionExporter.export(using: requireRPC(), support: support))
        case .exportJSONL:
            guard !snapshot.working, let index = selectedIndex else { throw RemoteFault.busy }
            try await requireIdle()
            let item = sessions[index]
            let response = try await requireRPC().request("get_entries")
            return .exportSession(try SessionExporter.branch(response, piID: item.piID, directory: item.directory.url.path))
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
        case .directoryAtPath(let path): return .directories(try await directories.list(path: path))
        case .preview(let id): return .preview(try await directories.preview(id))
        case .createSession(let id):
            guard !snapshot.working, sessions.count < 256 else { throw RemoteFault.busy }
            let selected = snapshot.selected, token = generation
            try await requireIdle()
            let directory = try await directories.resolve(id)
            guard selected == snapshot.selected, token == generation, !closing, !snapshot.working else { throw RemoteFault.conflict }
            try DirectoryRegistry.validateDirectory(directory)
            if let index = selectedIndex, rpc != nil, sessions[index].directory == directory {
                try await replaceInChild(target: nil, parent: false)
            } else {
                let sessionID = UUID()
                let folder = support.appendingPathComponent("pi-sessions/" + sessionID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let item = ManagedSession(info: SessionInfo(id: sessionID, title: directory.url.lastPathComponent, directory: directory.url.path),
                                          directory: directory, piID: sessionID.uuidString, folder: folder, file: nil, hasHistory: false)
                try await installAndActivate(item)
            }
        case .newSession(let parent):
            guard !snapshot.working, sessions.count < 256 else { throw RemoteFault.busy }
            try await replaceInChild(target: nil, parent: parent)
        case .importSession(let data):
            try await importSession(data, directory: nil, expectedSession: request.session)
        case .importSessionInDirectory(let data, let directory):
            try await importSession(data, directory: directory, expectedSession: request.session)
        case .resumeSession(let id):
            guard !snapshot.working else { throw RemoteFault.busy }
            try await resumeManaged(id)
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
            let command: String
            if snapshot.working {
                guard delivery != .prompt else { throw RemoteFault.busy }
                command = delivery == .steer ? "steer" : "follow_up"
            } else {
                guard delivery == .prompt else { throw RemoteFault.invalidRequest }
                command = "prompt"
            }
            let previous = selectedIndex.map { sessions[$0] }
            let token = generation, revision = runRevision
            try markInterrupted(true)
            let result: JSONValue
            do { result = try await child.request(command, fields: fields) }
            catch {
                // A failed response rejects this prompt before acceptance. Do not undo
                // run events or process-exit recovery that arrived while awaiting it.
                if let failure = error as? RPCFailure,
                   failure == .providerAuthenticationRequired || failure == .rejected(command),
                   token == generation, revision == runRevision,
                   let previous, let index = selectedIndex, sessions[index].info.id == previous.info.id {
                    sessions[index].info.interrupted = previous.info.interrupted
                    sessions[index].hasHistory = previous.hasHistory
                    try saveSessions()
                }
                throw error
            }
            if result["disposition"]?.string == "handled", !snapshot.working {
                // Handled input can be metadata/UI only. Restore the empty-file
                // expectation unless a run, message or persisted file proves otherwise.
                if token == generation, revision == runRevision, let previous, let index = selectedIndex,
                   sessions[index].info.id == previous.info.id, previous.hasHistory != true,
                   sessions[index].file.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                    sessions[index].hasHistory = previous.hasHistory
                }
                try markInterrupted(false)
            }
        case .stop:
            guard snapshot.phase != "starting" || lifecycleTransition != nil else { throw RemoteFault.busy }
            let child = try requireRPC()
            if lifecycleTransition != nil {
                // A hook can ignore dialog cancellation. Fence its pending reply and stop the
                // child; only confirmed termination can settle this unknown replacement.
                lifecycleTransition = nil; lifecycleUI = []; lifecycleUIOverflow = false
                generation = UUID(); observer?.cancel(); observer = nil
                let stopping = generation
                snapshot.phase = "stopping"; publish()
                for dialog in snapshot.dialogs { try? await child.answerDialog(id: dialog.id, value: nil, confirmed: nil, cancelled: true) }
                guard await interruptEventStream(child, generation: stopping) else { throw RemoteFault.unavailable }
                return .ok
            }
            if recoveringEvents {
                let token = generation
                guard await interruptEventStream(child, generation: token) else { throw RemoteFault.unavailable }
                return .ok
            }
            snapshot.phase = "stopping"; publish()
            _ = try await child.request("clear_queue")
            for dialog in snapshot.dialogs { try await child.answerDialog(id: dialog.id, value: nil, confirmed: nil, cancelled: true) }
            snapshot.dialogs = []; dialogDeadlines = [:]
            try await child.stopWork()
            snapshot.pendingMessages = 0; snapshot.phase = "idle"; try markInterrupted(false)
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
        case .cycleModel, .cycleThinking:
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            let command = action == .cycleModel ? "cycle_model" : "cycle_thinking_level"
            _ = try await requireRPC().request(command)
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
            let state = try await requireRPC().request("get_state")
            try adoptSessionName(state["sessionName"])
        case .history:
            let context = try inspectionContext()
            try await requireIdle()
            try checkInspection(context)
            let result = try await requireRPC().request("get_entries")
            try checkInspection(context)
            let entries = result["entries"]?.array ?? []
            return .history(entries.suffix(1_000).compactMap { raw in
                guard let id = raw["id"]?.string else { return nil }
                let message = raw["message"].flatMap(TranscriptReducer.message)
                return HistoryItem(id: id, parent: raw["parentId"]?.string, kind: raw["type"]?.string ?? "entry",
                                   text: DisplayLimit.text(message?.text ?? raw["summary"]?.string ?? "Session entry", bytes: 512),
                                   canFork: false)
            })
        case .sessionTree(let cursor):
            return .sessionTree(try await inspectionPage(cursor: cursor))
        case .historyPage(let cursor):
            let context = try inspectionContext()
            try await requireIdle()
            try checkInspection(context)
            guard let index = selectedIndex else { throw RemoteFault.conflict }
            let item = sessions[index]
            var file = item.file
            if let value = file {
                try validateSessionFile(value)
                if !FileManager.default.fileExists(atPath: value.path), item.hasHistory == false { file = nil }
            }
            let page = try await history.page(session: item.info.id, file: file, cursor: cursor)
            try checkInspection(context)
            return .historyPage(page)
        case .historyEntry(let id):
            let context = try inspectionContext()
            try await requireIdle()
            try checkInspection(context)
            let entry = try await history.displayEntry(session: context.session, id: id)
            try checkInspection(context)
            var preview = entry.preview
            if let message = entry.message {
                let display = outputImages.message(message)
                preview.images = TranscriptReducer.imageReferences(display["content"])
                if (message["content"]?.array ?? []).filter({ $0["type"]?.string == "image" }).count > 16 { preview.truncated = true }
            }
            return .preview(preview)
        case .fork(let entry):
            guard sessions.count < 256 else { throw RemoteFault.capacity }
            guard !entry.isEmpty, entry.utf8.count <= 128 else { throw RemoteFault.invalidRequest }
            let context = try inspectionContext()
            let child = try requireRPC()
            try await requireIdle()
            try checkInspection(context)
            let file = try inspectionFile()
            let revision = try await history.revision(file: file)
            try checkInspection(context)
            let options = try SessionInspectionMapper.forks(await child.request("get_fork_messages"))
            try checkInspection(context)
            guard options.contains(where: { $0.entryID == entry }) else { throw RemoteFault.invalidRequest }
            try await requireIdle()
            try checkInspection(context)
            let current = try await history.revision(file: file)
            try checkInspection(context)
            guard current == revision else { throw RemoteFault.conflict }
            try await replaceBranch("fork", fields: ["entryId": .string(entry)])
        case .clone:
            guard sessions.count < 256 else { throw RemoteFault.capacity }
            guard !snapshot.working else { throw RemoteFault.busy }
            try await requireIdle()
            try await replaceBranch("clone", fields: [:])
        case .command(let name, let arguments):
            guard let command = snapshot.commands.first(where: { $0.name == name }), arguments.utf8.count <= 16_384 else {
                throw RemoteFault.unsupportedFeature
            }
            guard snapshot.phase != "starting", snapshot.phase != "stopping" else { throw RemoteFault.busy }
            if snapshot.working { guard command.source == "extension" else { throw RemoteFault.busy } }
            else { try await requireIdle() }
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
            snapshot.phase = lifecycleTransition != nil ? "starting" : (snapshot.dialogs.isEmpty ? displayPhase : "waiting")
        case .diff:
            guard !snapshot.working, let index = selectedIndex else { throw RemoteFault.busy }
            let result = try await runUtility("/usr/bin/git", ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "diff", "--no-ext-diff", "--no-textconv", "--"], directory: sessions[index].directory.url, limit: 256 * 1_024)
            return .preview(FilePreview(name: "Working tree diff", text: String(decoding: result.0, as: UTF8.self), truncated: result.1))
        }
        return .ok
    }

    private func inspectionContext() throws -> InspectionContext {
        guard !snapshot.working, !recoveringEvents, !closing else { throw RemoteFault.busy }
        guard let session = snapshot.selected, rpc != nil else { throw RemoteFault.unavailable }
        return InspectionContext(session: session, generation: generation, revision: runRevision)
    }

    private func checkInspection(_ context: InspectionContext) throws {
        guard !Task.isCancelled, !closing, context.generation == generation,
              context.session == snapshot.selected, context.revision == runRevision, rpc != nil else {
            throw RemoteFault.conflict
        }
        guard !snapshot.working, !recoveringEvents else { throw RemoteFault.busy }
    }

    private func inspectionFile() throws -> URL? {
        guard let index = selectedIndex else { throw RemoteFault.conflict }
        let item = sessions[index]
        guard let file = item.file else { return nil }
        try validateSessionFile(file)
        if !FileManager.default.fileExists(atPath: file.path), item.hasHistory == false { return nil }
        return file
    }

    private func captureInspection() async throws -> CachedInspection {
        let context = try inspectionContext(), child = try requireRPC()
        try await requireIdle()
        try checkInspection(context)
        let file = try inspectionFile()
        let revision = try await history.revision(file: file)
        try checkInspection(context)
        // App mutations remain serialized by perform(). Fence the two core reads
        // with another tree read and the managed file revision to reject changes.
        let before = try await child.request("get_tree")
        try checkInspection(context)
        let forks = try SessionInspectionMapper.forks(await child.request("get_fork_messages"))
        try checkInspection(context)
        let after = try await child.request("get_tree")
        try checkInspection(context)
        let first = try SessionInspectionMapper.tree(before, forks: forks)
        let tree = try SessionInspectionMapper.tree(after, forks: forks)
        guard first == tree else { throw RemoteFault.conflict }
        try await requireIdle()
        try checkInspection(context)
        let current = try await history.revision(file: file)
        try checkInspection(context)
        guard current == revision else { throw RemoteFault.conflict }
        return CachedInspection(context: context, tree: tree, file: file, fileRevision: revision)
    }

    private func inspectionPage(cursor: UUID?) async throws -> SessionTreePage {
        _ = try inspectionContext()
        let now = ProcessInfo.processInfo.systemUptime
        inspections = inspections.filter { now - $0.value.created < 300 }
        inspectionCursors = inspectionCursors.filter { inspections[$0.value.inspection] != nil }
        let id: UUID, offset: Int, value: CachedInspection
        if let cursor {
            guard let saved = inspectionCursors[cursor], let cached = inspections[saved.inspection] else { throw RemoteFault.expired }
            id = saved.inspection; offset = saved.offset; value = cached
            do { try checkInspection(value.context) } catch { throw RemoteFault.expired }
            try await requireIdle()
        } else {
            id = UUID(); offset = 0; value = try await captureInspection()
        }
        try checkInspection(value.context)
        let revision = try await history.revision(file: value.file)
        try checkInspection(value.context)
        guard revision == value.fileRevision else { throw RemoteFault.expired }
        let nodes = Array(value.tree.nodes.dropFirst(offset).prefix(100))
        let previews = try await history.inspectionPreviews(session: value.context.session, file: value.file, ids: Set(nodes.map(\.id)))
        try checkInspection(value.context)
        let current = try await history.revision(file: value.file)
        try checkInspection(value.context)
        guard current == value.fileRevision else { throw RemoteFault.expired }
        inspections[id] = value
        while inspections.count > 2, let oldest = inspections.min(by: { $0.value.created < $1.value.created })?.key {
            inspections.removeValue(forKey: oldest)
        }
        inspectionCursors = inspectionCursors.filter { inspections[$0.value.inspection] != nil }
        var next: UUID?
        if offset + nodes.count < value.tree.nodes.count {
            let token = UUID()
            inspectionCursors[token] = InspectionCursor(inspection: id, offset: offset + nodes.count)
            next = token
        }
        while inspectionCursors.count > 32, let oldest = inspectionCursors.min(by: { $0.value.created < $1.value.created })?.key {
            inspectionCursors.removeValue(forKey: oldest)
        }
        return SessionTreePage(items: nodes.map { SessionTreeItem(node: $0, preview: previews[$0.id]) }, leafID: value.tree.leafID, next: next)
    }

    private func importSession(_ data: Data, directory directoryID: UUID?, expectedSession: UUID?) async throws {
        guard expectedSession == snapshot.selected else { throw RemoteFault.conflict }
        guard !snapshot.working, sessions.count < 256 else { throw RemoteFault.busy }
        let token = generation
        let imported = try SessionImport(data: data)
        let directory: RegisteredPath
        if let directoryID { directory = try await directories.resolve(directoryID) }
        else {
            guard let path = imported.directory else { throw RemoteFault.invalidRequest }
            directory = try DirectoryRegistry.identify(URL(fileURLWithPath: path))
        }
        try DirectoryRegistry.validateDirectory(directory)
        guard generation == token, expectedSession == snapshot.selected, !closing, !snapshot.working else { throw RemoteFault.conflict }
        try await requireIdle()
        guard !closing, !Task.isCancelled, generation == token, expectedSession == snapshot.selected, !snapshot.working else { throw RemoteFault.cancelled }
        try DirectoryRegistry.validateDirectory(directory)
        let contents = try SessionImport.preparedCopy(of: data, directory: directoryID == nil ? nil : directory.url.path)
        let sessionID = UUID()
        let folder = support.appendingPathComponent("pi-sessions/" + sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("imported.jsonl")
        do {
            try contents.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw RemoteFault.storageFailure
        }
        let item = ManagedSession(info: SessionInfo(id: sessionID, title: imported.title, directory: directory.url.path, interrupted: true),
                                  directory: directory, piID: imported.piID, folder: folder, file: file, hasHistory: true)
        do {
            if let index = selectedIndex, rpc != nil, sessions[index].directory == item.directory {
                try await replaceInChild(target: item, parent: false)
            } else { try await installAndActivate(item) }
        } catch {
            if !sessions.contains(where: { $0.info.id == item.info.id }) { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
    }

    private func inspectVersion(directory: URL, environment: [String: String]) async throws -> String {
        do {
            let output = try await runUtility(executable.path, ["--version"], directory: directory, limit: 256, environment: environment)
            let version = String(decoding: output.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.1, !version.isEmpty else { throw RemoteFault.piLaunchFailed }
            return version
        } catch let fault as RemoteFault where fault == .cancelled || fault == .busy { throw fault }
        catch { throw RemoteFault.piLaunchFailed }
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

    private func installAndActivate(_ item: ManagedSession) async throws {
        sessions.append(item)
        do { try saveSessions(); try await activate(item.info.id) }
        catch {
            // Keep the catalog and files if this child has not confirmed shutdown.
            if rpc != nil, snapshot.selected == item.info.id { throw error }
            sessions.removeAll { $0.info.id == item.info.id }
            if snapshot.selected == item.info.id { snapshot.selected = nil }
            try? saveSessions()
            try? FileManager.default.removeItem(at: item.folder)
            throw error
        }
    }

    private func validateManaged(_ item: ManagedSession) throws {
        try DirectoryRegistry.validateDirectory(item.directory)
        if let parent = item.parentFile {
            try validateSessionFile(parent)
            guard parent != item.file else { throw RemoteFault.incompatiblePi }
        }
        if let file = item.file {
            try validateSessionFile(file)
            if FileManager.default.fileExists(atPath: file.path) { try validateSessionHeader(file, session: item) }
            else if item.hasHistory != false { throw RemoteFault.staleDirectory }
        } else if item.hasHistory == true { throw RemoteFault.staleDirectory }
    }

    private func resumeManaged(_ id: UUID) async throws {
        guard let item = sessions.first(where: { $0.info.id == id }) else { throw RemoteFault.staleDirectory }
        let selected = snapshot.selected, token = generation
        try validateManaged(item)
        let fileIdentity = try item.file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try DirectoryRegistry.identify($0) : nil }
        try await requireIdle()
        guard !closing, !Task.isCancelled, token == generation, selected == snapshot.selected, !snapshot.working else { throw RemoteFault.conflict }
        try validateManaged(item)
        if let identity = fileIdentity { guard try DirectoryRegistry.identify(identity.url) == identity else { throw RemoteFault.staleDirectory } }
        if let index = selectedIndex, rpc != nil, sessions[index].directory == item.directory,
           let file = item.file, FileManager.default.fileExists(atPath: file.path) {
            try await replaceInChild(target: item, parent: false)
        } else {
            // Core switch_session cannot restore an allocated but unwritten session path.
            // Launch explicitly with its managed ID; no history or prompt is manufactured.
            try await activate(id)
        }
    }

    private func replaceInChild(target: ManagedSession?, parent: Bool) async throws {
        guard !snapshot.working, let index = selectedIndex else { throw RemoteFault.busy }
        let source = sessions[index], child = try requireRPC(), priorSelection = snapshot.selected
        let initialGeneration = generation
        try validateManaged(source)
        if let target { try validateManaged(target); guard target.directory == source.directory else { throw RemoteFault.conflict } }
        let sourceFileIdentity = try source.file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try DirectoryRegistry.identify($0) : nil }
        let targetFileIdentity = try target?.file.map { try DirectoryRegistry.identify($0) }
        if parent { guard sourceFileIdentity != nil else { throw RemoteFault.invalidRequest } }
        try await requireIdle()
        guard generation == initialGeneration, snapshot.selected == priorSelection, rpc === child, !closing, !Task.isCancelled, !snapshot.working else {
            throw RemoteFault.conflict
        }
        try validateManaged(source)
        if let target { try validateManaged(target) }
        let before = try await child.request("get_state")
        guard generation == initialGeneration, snapshot.selected == priorSelection, rpc === child, !closing, !Task.isCancelled, !snapshot.working else {
            throw RemoteFault.conflict
        }
        guard before["sessionId"]?.string == source.piID,
              before["isStreaming"]?.bool == false, before["isCompacting"]?.bool == false,
              before["pendingMessageCount"] == .number(0) else { throw RemoteFault.busy }
        try validateManaged(source)
        if let target { try validateManaged(target) }
        let priorPhase = snapshot.phase
        // Fence outgoing callbacks before dispatch. Old name/status/history events must not
        // be applied to either catalog entry while core replaces its extension runtime.
        let token = generation
        lifecycleTransition = token
        lifecycleUI = []; lifecycleUIOverflow = false; lifecycleNameReadBack = true
        defer { if lifecycleTransition == token { lifecycleTransition = nil; lifecycleUI = []; lifecycleUIOverflow = false } }
        historyRefresh?.cancel(); historyRefresh = nil; historyNeedsRefresh = false
        scheduledPublish?.cancel(); scheduledPublish = nil
        snapshot.phase = "starting"; publish()
        var committed = false
        var dispatched = false
        func check(_ selected: UUID?) throws {
            guard !closing, !Task.isCancelled, generation == token, lifecycleTransition == token, rpc === child, snapshot.selected == selected else {
                throw RemoteFault.conflict
            }
            try validateManaged(source)
            if let identity = sourceFileIdentity { guard try DirectoryRegistry.identify(identity.url) == identity else { throw RemoteFault.staleDirectory } }
            if let target { try validateManaged(target) }
            if let identity = targetFileIdentity { guard try DirectoryRegistry.identify(identity.url) == identity else { throw RemoteFault.staleDirectory } }
        }
        do {
            try check(priorSelection)
            var fields: [String: JSONValue] = [:]
            if let target, let file = target.file { fields["sessionPath"] = .string(file.path) }
            else if parent, let file = source.file { fields["parentSession"] = .string(file.path) }
            dispatched = true
            let result = try await child.request(target == nil ? "new_session" : "switch_session", fields: fields, timeout: 15)
            try check(priorSelection)
            guard let cancelled = result["cancelled"]?.bool else { throw RemoteFault.incompatiblePi }
            if cancelled {
                try finishLifecycleObservation(child)
                snapshot.dialogs = []; dialogDeadlines = [:]
                snapshot.phase = priorPhase
                throw RemoteFault.cancelled
            }
            let state = try await child.request("get_state")
            try check(priorSelection)
            guard state["isStreaming"]?.bool == false, state["isCompacting"]?.bool == false,
                  state["pendingMessageCount"] == .number(0),
                  let piID = state["sessionId"]?.string, !piID.isEmpty, piID.utf8.count <= 128,
                  let path = state["sessionFile"]?.string else { throw RemoteFault.incompatiblePi }
            let file = URL(fileURLWithPath: path)
            try validateSessionFile(file)
            var item: ManagedSession
            if let target {
                guard piID == target.piID, file.resolvingSymlinksInPath().path == target.file?.resolvingSymlinksInPath().path else { throw RemoteFault.incompatiblePi }
                item = target
            } else {
                guard piID != source.piID, UUID(uuidString: piID) != nil else { throw RemoteFault.incompatiblePi }
                let id = UUID()
                item = ManagedSession(info: SessionInfo(id: id, title: source.directory.url.lastPathComponent, directory: source.directory.url.path),
                                      directory: source.directory, piID: piID, folder: file.deletingLastPathComponent(), file: file, hasHistory: false)
            }
            item.file = file
            if target == nil { item.parentFile = parent ? source.file : nil }
            try validateManaged(item)
            if let existing = sessions.firstIndex(where: { $0.info.id == item.info.id }) { sessions[existing] = item }
            else { guard sessions.count < 256 else { throw RemoteFault.capacity }; sessions.append(item) }
            committed = true
            snapshot.selected = item.info.id
            reducer = TranscriptReducer(); outputImages = OutputImages()
            snapshot.messages = []; snapshot.hasOlderMessages = false; snapshot.dialogs = []
            snapshot.draft = nil; snapshot.draftID = nil; snapshot.notices = []; snapshot.pendingMessages = 0
            dialogDeadlines = [:]; statuses = [:]; notifications = []
            // runtime is intentionally retained until read-back: retry acknowledgement is process-scoped.
            try saveSessions()
            try await refreshConfiguration(); try check(item.info.id); try validateManaged(item)
            try await refreshHistory(); try check(item.info.id); try validateManaged(item)
            try await requireIdle(); try check(item.info.id)
            try finishLifecycleObservation(child)
            snapshot.phase = "idle"
            if let selected = selectedIndex { sessions[selected].info.updated = Date(); try saveSessions() }
            publish()
        } catch {
            if !dispatched {
                try finishLifecycleObservation(child)
                snapshot.phase = priorPhase
                throw error
            }
            if !committed, error as? RemoteFault == .cancelled, snapshot.phase == priorPhase { throw error }
            // Dispatch may have succeeded. Stop this child instead of restoring an invented idle state
            // or retrying the lifecycle command. Existing recovery retains the unknown outcome.
            _ = await interruptEventStream(child, generation: token)
            throw error
        }
    }

    private func finishLifecycleObservation(_ child: RPCProcess) throws {
        guard rpc === child else { throw RemoteFault.conflict }
        lifecycleTransition = nil
        runRevision &+= 1
        // Core UI records have no session tags. Treat these as transition-generated
        // updates for the resolved context, including a cancelled outgoing hook.
        let events = lifecycleUI; lifecycleUI = []
        for event in events { extensionEvent(event) }
        if lifecycleUIOverflow {
            snapshot.error = .capacity
            notifications.append("Some session-transition UI updates exceeded the display limit.")
            notifications = Array(notifications.suffix(8)); refreshNotices()
        }
        lifecycleUIOverflow = false
        // Keep the subscription: a UI record queued before the RPC reply may not yet
        // have reached this actor. Its normal event path must remain intact.
    }

    private func retainLifecycleUI(_ event: JSONValue) {
        guard let method = event["method"]?.string,
              ["set_editor_text", "notify", "setTitle", "setStatus", "setWidget"].contains(method) else { return }
        var fields: [String: JSONValue] = ["type": .string("extension_ui_request"), "method": .string(method)]
        let textLimit = method == "set_editor_text" ? 256 * 1_024 : 2_048
        for key in ["text", "message", "title", "statusText"] {
            if let value = event[key]?.string {
                if method == "set_editor_text", value.utf8.count > textLimit { lifecycleUIOverflow = true; return }
                fields[key] = .string(DisplayLimit.text(value, bytes: textLimit))
            }
        }
        for key in ["statusKey", "widgetKey"] {
            if let value = event[key]?.string {
                guard value.utf8.count <= 256 else { lifecycleUIOverflow = true; return }
                fields[key] = .string(value)
            }
        }
        if let lines = event["widgetLines"]?.array {
            fields["widgetLines"] = .array([.string(DisplayLimit.text(lines.compactMap(\.string).joined(separator: "\n"), bytes: 2_048))])
        }
        lifecycleUI.append(.object(fields))
        func bytes(_ event: JSONValue) -> Int { (try? JSONEncoder().encode(event).count) ?? 512 * 1_024 }
        var total = lifecycleUI.reduce(0) { $0 + bytes($1) }
        while lifecycleUI.count > 64 || total > 512 * 1_024 {
            total -= bytes(lifecycleUI.removeFirst()); lifecycleUIOverflow = true
        }
    }

    private func scheduleLifecycleNameReadBack() {
        guard lifecycleNameRefresh == nil, lifecycleTransition == nil, let child = rpc, let index = selectedIndex, !closing else { return }
        let token = generation, selected = snapshot.selected, piID = sessions[index].piID, revision = lifecycleNameVersion
        lifecycleNameRefresh = Task { [weak self] in
            guard let self else { return }
            await self.readLifecycleName(child, generation: token, selected: selected, piID: piID, revision: revision)
        }
    }

    private func readLifecycleName(_ child: RPCProcess, generation token: UUID, selected: UUID?, piID: String, revision: UInt64) async {
        defer {
            if generation == token {
                lifecycleNameRefresh = nil
                if revision != lifecycleNameVersion { scheduleLifecycleNameReadBack() }
            }
        }
        do {
            let state = try await child.request("get_state", timeout: 5)
            guard generation == token, snapshot.selected == selected, rpc === child, lifecycleTransition == nil, !closing else { return }
            guard state["sessionId"]?.string == piID else { throw RemoteFault.conflict }
            try adoptSessionName(state["sessionName"]); publish()
        } catch {
            if generation == token, snapshot.selected == selected, lifecycleTransition == nil, !closing { snapshot.error = .unavailable; publish() }
        }
    }

    private func activate(_ id: UUID) async throws {
        guard let index = sessions.firstIndex(where: { $0.info.id == id }) else { throw RemoteFault.staleDirectory }
        try validateManaged(sessions[index])
        let environment = PiLaunchEnvironment.make(executable: executable)
        try PiLaunchEnvironment.validate(executable: executable, environment: environment)
        let previous = rpc, previousSelection = snapshot.selected
        lifecycleNameRefresh?.cancel(); lifecycleNameRefresh = nil; lifecycleNameReadBack = false
        generation = UUID()
        let activation = generation
        historyRefresh?.cancel(); historyRefresh = nil; historyNeedsRefresh = false
        observer?.cancel(); rpc = nil
        snapshot.phase = "starting"; snapshot.selected = id; snapshot.messages = []; snapshot.dialogs = []
        snapshot.draft = nil; snapshot.draftID = nil; snapshot.runtime = nil; snapshot.pendingMessages = nil
        reducer = TranscriptReducer(); outputImages = OutputImages()
        recoveringEvents = false; recoveryNotice = nil
        dialogDeadlines = [:]; statuses = [:]; notifications = []; publish()
        if let previous, !(await previous.shutdown()) {
            preserveUnconfirmedShutdown(previous, selected: previousSelection)
            throw RemoteFault.unavailable
        }
        guard !closing, generation == activation else { throw RemoteFault.cancelled }
        let item = sessions[index]
        try DirectoryRegistry.validateDirectory(item.directory)
        _ = try sessionArguments(item)
        snapshot.piVersion = try await inspectVersion(directory: item.directory.url, environment: environment)
        guard !closing, generation == activation, !Task.isCancelled else { throw RemoteFault.cancelled }
        // Shutdown and executable inspection suspend this actor. Recheck paths before launch.
        try DirectoryRegistry.validateDirectory(item.directory)
        let child = try RPCProcess(executable: executable, arguments: sessionArguments(item), workingDirectory: item.directory.url, eventCapacity: rpcEventCapacity, environment: environment)
        rpc = child
        observe(child, events: child.events)
        do {
            try await refreshConfiguration()
            try await refreshHistory()
            guard !closing, generation == activation else { throw RemoteFault.cancelled }
            snapshot.phase = "idle"
            sessions[index].info.updated = Date(); try saveSessions()
        } catch {
            generation = UUID(); observer?.cancel()
            if await child.shutdown() { rpc = nil; snapshot.phase = "unavailable"; publish() }
            else { preserveUnconfirmedShutdown(child, selected: id) }
            throw error
        }
        publish()
    }

    private func observe(_ child: RPCProcess, events initial: AsyncThrowingStream<JSONValue, any Error>) {
        let token = generation
        observer = Task { [weak self] in
            var events = initial
            var recoveries = 0
            while !Task.isCancelled {
                do {
                    for try await event in events { await self?.consume(event, generation: token) }
                    if !Task.isCancelled { await self?.processEnded(token) }
                    return
                } catch RPCFailure.eventOverflow {
                    guard !Task.isCancelled else { return }
                    recoveries += 1
                    guard recoveries <= 3 else {
                        _ = await self?.interruptEventStream(child, generation: token)
                        return
                    }
                    do { events = try child.resumeEvents() }
                    catch { _ = await self?.interruptEventStream(child, generation: token); return }
                    guard await self?.recoverEventStream(child, generation: token) == true else { return }
                } catch {
                    if !Task.isCancelled { _ = await self?.interruptEventStream(child, generation: token) }
                    return
                }
            }
        }
    }

    private func sessionArguments(_ item: ManagedSession) throws -> [String] {
        // activate() calls this only after the previous child has stopped.
        // Restore only a confirmed, empty session header; never replace history.
        if item.hasHistory == false, let parent = item.parentFile, let file = item.file,
           !FileManager.default.fileExists(atPath: file.path) {
            try validateManaged(item)
            let header: JSONValue = .object([
                "type": .string("session"), "version": .number(3), "id": .string(item.piID),
                "cwd": .string(item.directory.url.path),
                "timestamp": .string(ISO8601DateFormatter().string(from: item.info.updated)),
                "parentSession": .string(parent.path)
            ])
            var data = try JSONEncoder().encode(header); data.append(10)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw RemoteFault.storageFailure }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do { try handle.write(contentsOf: data); try handle.close() }
            catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw RemoteFault.storageFailure }
        }
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

    private func decodeRuntime(_ data: JSONValue) throws -> RuntimeSettings {
        do {
            var value = try JSONDecoder().decode(RuntimeSettings.self, from: JSONEncoder().encode(data))
            value.acknowledgedAutoRetry = snapshot.runtime?.acknowledgedAutoRetry
            return value
        }
        catch { throw RemoteFault.incompatiblePi }
    }

    private func refreshRuntime() async throws -> RuntimeSettings {
        let data = try await requireRPC().request("get_state")
        let value = try decodeRuntime(data)
        snapshot.runtime = value
        return value
    }

    private func refreshConfiguration() async throws {
        let child = try requireRPC()
        let state = try await child.request("get_state")
        snapshot.pendingMessages = try pendingCount(state["pendingMessageCount"])
        try adoptSessionName(state["sessionName"])
        snapshot.runtime = try? decodeRuntime(state)
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
        let messages = (data["messages"]?.array ?? []).map { outputImages.message($0) }
        if !messages.isEmpty { try retainHistoryPresence() }
        reducer.replaceHistory(messages)
        snapshot.messages = reducer.messages; snapshot.hasOlderMessages = reducer.omitted
        historyNeedsRefresh = false
    }

    private func scheduleHistoryRefresh(allowRetry: Bool = true) {
        guard historyNeedsRefresh, historyRefresh == nil, !snapshot.working, mutations.isEmpty, !closing else { return }
        let token = generation, revision = runRevision, session = snapshot.selected
        historyRefresh = Task { [weak self] in
            await self?.refreshSettledHistory(generation: token, revision: revision, session: session, allowRetry: allowRetry)
        }
    }

    private func refreshSettledHistory(generation token: UUID, revision: UInt64, session: UUID?, allowRetry: Bool) async {
        guard generation == token, snapshot.selected == session, !snapshot.working, mutations.isEmpty, !closing else {
            if generation == token { historyRefresh = nil }
            return
        }
        let mutation = UUID()
        mutations.insert(mutation)
        var supersededRun = false
        defer {
            mutations.remove(mutation)
            if generation == token {
                historyRefresh = nil
                if supersededRun && allowRetry { scheduleHistoryRefresh(allowRetry: false) }
            }
        }
        do {
            let data = try await requireRPC().request("get_messages")
            guard generation == token, snapshot.selected == session else { return }
            guard runRevision == revision, !snapshot.working else {
                supersededRun = runRevision != revision
                return
            }
            let messages = (data["messages"]?.array ?? []).map { outputImages.message($0) }
            if !messages.isEmpty { try retainHistoryPresence() }
            reducer.replaceHistory(messages)
            snapshot.messages = reducer.messages; snapshot.hasOlderMessages = reducer.omitted
            historyNeedsRefresh = false
            publish()
        } catch {
            if generation == token { snapshot.error = .unavailable; publish() }
        }
    }

    private func replaceBranch(_ command: String, fields: [String: JSONValue]) async throws {
        guard !snapshot.working, !closing, lifecycleTransition == nil else { throw RemoteFault.busy }
        guard sessions.count < 256, let index = selectedIndex else { throw RemoteFault.capacity }
        let source = sessions[index], child = try requireRPC(), token = generation, priorPhase = snapshot.phase
        try validateManaged(source)
        let sourceIdentity = try source.file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try DirectoryRegistry.identify($0) : nil }
        lifecycleTransition = token; lifecycleUI = []; lifecycleUIOverflow = false; lifecycleNameReadBack = true
        defer { if lifecycleTransition == token { lifecycleTransition = nil; lifecycleUI = []; lifecycleUIOverflow = false } }
        historyRefresh?.cancel(); historyRefresh = nil; historyNeedsRefresh = false
        snapshot.phase = "starting"; publish()
        do {
            let result = try await child.request(command, fields: fields, timeout: 15)
            guard generation == token, lifecycleTransition == token, rpc === child, snapshot.selected == source.info.id, !closing, !Task.isCancelled else { throw RemoteFault.conflict }
            try validateManaged(source)
            if let identity = sourceIdentity { guard try DirectoryRegistry.identify(identity.url) == identity else { throw RemoteFault.staleDirectory } }
            guard let cancelled = result["cancelled"]?.bool else { throw RemoteFault.incompatiblePi }
            if cancelled {
                try finishLifecycleObservation(child)
                snapshot.dialogs = []; dialogDeadlines = [:]; snapshot.phase = priorPhase
                throw RemoteFault.cancelled
            }
            let forkText = command == "fork" ? result["text"]?.string : nil
            let oversizedDraft = (forkText?.utf8.count ?? 0) > 256 * 1_024
            // A successful core fork is already committed. Never truncate its returned
            // input, reject that success, or repeat it because the native draft is smaller.
            snapshot.draft = oversizedDraft ? nil : forkText
            snapshot.draftID = snapshot.draft == nil ? nil : UUID()
            try await adoptBranch()
            guard generation == token, lifecycleTransition == token, rpc === child, !closing, !Task.isCancelled else { throw RemoteFault.conflict }
            try await requireIdle()
            guard generation == token, lifecycleTransition == token, rpc === child, !closing, !Task.isCancelled else { throw RemoteFault.conflict }
            try finishLifecycleObservation(child)
            if oversizedDraft {
                notifications.append("Fork succeeded. The source message exceeds the 256 KiB draft limit and was not copied to the draft.")
                notifications = Array(notifications.suffix(8)); refreshNotices()
            }
            snapshot.phase = "idle"; publish()
        } catch {
            if error as? RemoteFault == .cancelled, snapshot.phase == priorPhase { throw error }
            _ = await interruptEventStream(child, generation: token)
            throw error
        }
    }

    private func adoptBranch() async throws {
        guard sessions.count < 256 else { throw RemoteFault.capacity }
        guard let old = selectedIndex else { throw RemoteFault.unavailable }
        let source = sessions[old], child = try requireRPC(), token = generation
        let data = try await child.request("get_state")
        guard generation == token, rpc === child, snapshot.selected == source.info.id, lifecycleTransition == token, !closing else { throw RemoteFault.conflict }
        try validateManaged(source)
        guard data["isStreaming"]?.bool == false, data["isCompacting"]?.bool == false, data["pendingMessageCount"] == .number(0),
              let file = data["sessionFile"]?.string, let piID = data["sessionId"]?.string, piID != source.piID else { throw RemoteFault.incompatiblePi }
        let url = URL(fileURLWithPath: file); try validateSessionFile(url)
        let info = SessionInfo(id: UUID(), title: "Branch — " + source.info.title, directory: source.info.directory)
        let persisted = FileManager.default.fileExists(atPath: url.path)
        let item = ManagedSession(info: info, directory: source.directory, piID: piID, folder: url.deletingLastPathComponent(), file: url,
                                  hasHistory: persisted, parentFile: persisted ? nil : source.file)
        try validateManaged(item)
        sessions.append(item)
        snapshot.selected = info.id; reducer = TranscriptReducer(); outputImages = OutputImages()
        snapshot.messages = []; snapshot.hasOlderMessages = false; snapshot.dialogs = []; snapshot.notices = []; snapshot.pendingMessages = 0
        dialogDeadlines = [:]; statuses = [:]; notifications = []
        try saveSessions()
        try await refreshConfiguration()
        guard generation == token, rpc === child, snapshot.selected == info.id, lifecycleTransition == token, !closing else { throw RemoteFault.conflict }
        try validateManaged(item)
        try await refreshHistory()
        guard generation == token, rpc === child, snapshot.selected == info.id, lifecycleTransition == token, !closing else { throw RemoteFault.conflict }
        try validateManaged(item)
    }

    private var displayPhase: String {
        if recoveringEvents { return "recovering" }
        return reducer.phase == "idle" && (snapshot.pendingMessages ?? 0) > 0 ? "queued" : reducer.phase
    }

    private func preserveUnconfirmedShutdown(_ child: RPCProcess, selected: UUID?) {
        rpc = child; snapshot.selected = selected
        recoveringEvents = true; snapshot.phase = "recovering"; snapshot.error = .unknownOutcome
        snapshot.dialogs = []; dialogDeadlines = [:]; snapshot.pendingMessages = nil
        recoveryNotice = "Pi did not confirm shutdown. Use Stop again before changing sessions."
        do { try retainInterruptedState() } catch { snapshot.error = .storageFailure }
        refreshNotices(); publish()
    }

    private func retainInterruptedState() throws {
        if let index = selectedIndex {
            sessions[index].info.interrupted = true
            sessions[index].info.updated = Date()
            try saveSessions()
        }
    }

    private func recoverEventStream(_ child: RPCProcess, generation token: UUID) async -> Bool {
        guard generation == token, rpc === child, !closing else { return false }
        recoveringEvents = true
        recoveryNotice = "Live events were lost. Recovery is in progress; do not resend accepted work."
        snapshot.phase = "recovering"; snapshot.error = .unknownOutcome
        snapshot.dialogs = []; dialogDeadlines = [:]
        do { try retainInterruptedState() } catch { snapshot.error = .storageFailure }
        refreshNotices(); publish()
        do {
            try await refreshConfiguration()
            try await refreshHistory()
            guard generation == token, rpc === child, !closing else { return false }
            // Core RPC cannot replay lost extension dialogs or report an outstanding retry wait.
            // Preserve the child, but require explicit Stop/reopen before further mutations.
            recoveryNotice = "Session history was refreshed after lost events. Work status is uncertain. Use Stop, then reopen the saved session; do not resend uncertain actions."
            snapshot.phase = "recovering"; refreshNotices(); publish()
            return true
        } catch {
            _ = await interruptEventStream(child, generation: token)
            return false
        }
    }

    @discardableResult private func interruptEventStream(_ child: RPCProcess, generation token: UUID) async -> Bool {
        guard generation == token, rpc === child else { return false }
        generation = UUID()
        snapshot.phase = "stopping"; publish()
        let stopped = await child.shutdown()
        if stopped { rpc = nil }
        observer = nil
        recoveringEvents = !stopped
        snapshot.dialogs = []; dialogDeadlines = [:]; snapshot.pendingMessages = nil
        snapshot.phase = stopped ? "interrupted" : "recovering"
        snapshot.error = .unknownOutcome
        recoveryNotice = stopped
            ? "Pi stopped after an event-stream gap. Reopen the saved session; do not resend uncertain actions."
            : "Pi did not confirm shutdown after lost events. Use Stop again; do not resend uncertain actions."
        do { try retainInterruptedState() } catch { snapshot.error = .storageFailure }
        refreshNotices(); publish()
        return stopped
    }

    private func pendingCount(_ value: JSONValue?) throws -> Int {
        guard case .number(let count) = value, count.isFinite, count >= 0, count <= 1_000_000, count.rounded() == count else {
            throw RemoteFault.incompatiblePi
        }
        return Int(count)
    }

    private func adoptSessionName(_ value: JSONValue?) throws {
        guard let index = selectedIndex else { return }
        guard value == nil || value == .null || value?.string != nil else { throw RemoteFault.incompatiblePi }
        let name = value?.string
        let title = name.flatMap { $0.isEmpty ? nil : DisplayLimit.text($0, bytes: 256) } ?? sessions[index].directory.url.lastPathComponent
        if sessions[index].info.title != title {
            sessions[index].info.title = title
            try saveSessions()
        }
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
            if let parent = session.parentFile, header["parentSession"]?.string != parent.path {
                throw RemoteFault.incompatiblePi
            }
        } catch let fault as RemoteFault { throw fault }
        catch { throw RemoteFault.permissionDenied }
    }

    private func retainHistoryPresence() throws {
        guard let index = selectedIndex, sessions[index].hasHistory != true,
              let file = sessions[index].file, FileManager.default.fileExists(atPath: file.path) else { return }
        // Core can keep setup/custom context in memory without creating a file.
        // Only an observed persisted file makes its later absence a history-loss error.
        sessions[index].hasHistory = true
        try saveSessions()
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
        if lifecycleTransition != nil {
            // Keep standard hook dialogs answerable. Other events cannot be attributed to
            // the outgoing or incoming session; authoritative reads replace their view state.
            if event["type"]?.string == "extension_ui_request",
               ["select", "confirm", "input", "editor"].contains(event["method"]?.string ?? "") {
                extensionEvent(event); snapshot.phase = "waiting"; publish()
            } else if event["type"]?.string == "extension_ui_request" {
                retainLifecycleUI(event)
            }
            return
        }
        // Custom messages can complete without an agent run. Fence history reads
        // against these transcript changes as well as agent boundaries.
        if event["type"]?.string == "message_end" {
            runRevision &+= 1
            if event["message"]?["role"]?.string != nil {
                do { try retainHistoryPresence() } catch { snapshot.error = .storageFailure }
            }
        }
        reducer.consume(outputImages.event(event))
        snapshot.messages = reducer.messages
        if event["type"]?.string == "queue_update" {
            if let steering = event["steering"]?.array, let followUp = event["followUp"]?.array {
                snapshot.pendingMessages = steering.count + followUp.count
                if (snapshot.pendingMessages ?? 0) > 0 {
                    do { try markInterrupted(true) } catch { snapshot.error = .storageFailure }
                }
            } else { snapshot.error = .incompatiblePi }
        }
        if event["type"]?.string == "compaction_end", event["result"] != nil, event["result"] != .null {
            historyNeedsRefresh = true
        }
        if event["type"]?.string == "thinking_level_changed", let level = event["level"]?.string, level.utf8.count <= 128 {
            snapshot.thinking = level
        }
        if snapshot.phase != "starting" && snapshot.phase != "stopping" { snapshot.phase = displayPhase }
        snapshot.hasOlderMessages = reducer.omitted
        if event["type"]?.string == "agent_start" {
            runRevision &+= 1
            do { try markInterrupted(true) } catch { snapshot.error = .storageFailure }
        }
        if event["type"]?.string == "agent_settled" {
            runRevision &+= 1
            do { try markInterrupted((snapshot.pendingMessages ?? 0) > 0) } catch { snapshot.error = .storageFailure }
        }
        if event["type"]?.string == "extension_ui_request" { extensionEvent(event) }
        if event["type"]?.string == "extension_error" { snapshot.error = .unsupportedFeature }
        if event["type"]?.string == "message_end", event["message"]?["stopReason"]?.string == "error" {
            snapshot.error = RPCFailure.isProviderAuthenticationError(event["message"]?["errorMessage"]?.string ?? "")
                ? .providerAuthenticationRequired : .unavailable
        }
        if event["type"]?.string == "session_info_changed" {
            if lifecycleNameReadBack {
                lifecycleNameVersion &+= 1; scheduleLifecycleNameReadBack()
            } else {
                do { try adoptSessionName(event["name"]) }
                catch { snapshot.error = error as? RemoteFault ?? .storageFailure }
            }
        }
        if !snapshot.dialogs.isEmpty && snapshot.phase != "starting" && snapshot.phase != "stopping" { snapshot.phase = "waiting" }
        scheduleHistoryRefresh()
        if ContinuousClock.now - lastPublish > .milliseconds(100) || event["type"]?.string == "agent_settled" { publish() }
        else if scheduledPublish == nil {
            scheduledPublish = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100)); await self?.publishScheduled()
            }
        }
    }

    private func extensionEvent(_ event: JSONValue) {
        let method = event["method"]?.string ?? ""
        if recoveringEvents, ["select", "confirm", "input", "editor"].contains(method) { return }
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
            let rawKey = event["statusKey"]?.string ?? event["widgetKey"]?.string ?? method
            guard rawKey.utf8.count <= 256 else { snapshot.error = .tooLarge; return }
            let key = method + ":" + rawKey
            let text = event["statusText"]?.string ?? (event["widgetLines"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
            if text.isEmpty { statuses.removeValue(forKey: key) }
            else if statuses.count < 16 || statuses[key] != nil { statuses[key] = DisplayLimit.text(text, bytes: 2_048) }
        } else {
            let text = event["message"]?.string ?? event["title"]?.string ?? ""
            if !text.isEmpty { notifications.append(DisplayLimit.text(text, bytes: 2_048)); notifications = Array(notifications.suffix(8)) }
        }
        refreshNotices()
    }

    private func refreshNotices() {
        snapshot.notices = (recoveryNotice.map { [$0] } ?? []) + Array(statuses.values.prefix(16)) + notifications
    }

    private func expireDialog(_ id: String, generation token: UUID) {
        guard token == generation, let deadline = dialogDeadlines[id], deadline <= ProcessInfo.processInfo.systemUptime else { return }
        snapshot.dialogs.removeAll { $0.id == id }; dialogDeadlines.removeValue(forKey: id)
        if snapshot.phase == "waiting" { snapshot.phase = snapshot.dialogs.isEmpty ? displayPhase : "waiting" }
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
        lifecycleTransition = nil; lifecycleUI = []; lifecycleUIOverflow = false
        lifecycleNameRefresh?.cancel(); lifecycleNameRefresh = nil
        utility?.cancel()
        if let utility { _ = await utility.result }
        self.utility = nil
        generation = UUID(); observer?.cancel(); observer = nil
        historyRefresh?.cancel(); historyRefresh = nil; historyNeedsRefresh = false
        scheduledPublish?.cancel(); scheduledPublish = nil
        if snapshot.working { try? markInterrupted(true) }
        let child = rpc; rpc = nil
        if let child { _ = await child.shutdown() }
        snapshot.phase = "unavailable"; publish()
    }
}
