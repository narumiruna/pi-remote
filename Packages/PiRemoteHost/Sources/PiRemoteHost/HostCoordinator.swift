import Darwin
import Foundation
import PiRPC
import PiRemoteCore
import PiRemoteSecurity

/// Local-only authority to stop the work shown before a close confirmation dialog.
public struct LocalCloseConfirmation: Sendable, Equatable {
    public let context: SessionContext
    fileprivate let lifecycle: UUID
    fileprivate let work: UUID
}

/// Local-only consent for ordinary app termination. Never sent to a phone.
public struct LocalQuitConfirmation: Sendable, Equatable {
    public let requiresConfirmation: Bool
    fileprivate let context: SessionContext
    fileprivate let lifecycle: UUID
    fileprivate let work: UUID
    fileprivate let mutationRevision: UInt64
    fileprivate let pending: Set<UUID>
    fileprivate let dialogs: [String]
    fileprivate let transition: UUID?
}

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
    private var bashTask: Task<Void, Never>?
    private var bashEnqueued: Task<Void, Never>?
    private var bashCancellation: Task<Void, Never>?
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
    // Confirmation follows work boundaries, not streaming message completion.
    private var workGeneration = UUID()
    private var observers: [UUID: AsyncStream<HostSnapshot>.Continuation] = [:]
    private var journal: RequestJournal
    private var replay = StateReplay()
    private var mutations: Set<UUID> = []
    private var mutationRevision: UInt64 = 0
    private var pendingQuitMutations: Set<UUID> = []
    // Displayed read errors must not hide an unresolved state-changing outcome.
    private var unresolvedQuitOutcome = false
    private var closing = false
    private var utility: Task<(Data, Bool), any Error>?
    private var dialogDeadlines: [String: TimeInterval] = [:]
    private var extensionMetadata = ExtensionDisplayMetadata()
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

    /// Local footer reads must not reserve foreground action admission or publish read faults.
    public func displayStatistics(context: SessionContext) async throws -> SessionStatistics {
        guard snapshot.context == context, context.session != nil, !snapshot.working,
              mutations.isEmpty, !closing else { throw RemoteFault.conflict }
        let token = generation, work = workGeneration, mutation = mutationRevision
        let data = try await requireRPC().request("get_session_stats")
        guard snapshot.context == context, generation == token, workGeneration == work,
              mutationRevision == mutation, mutations.isEmpty, !snapshot.working, !closing else { throw RemoteFault.conflict }
        return try Self.decodeStatistics(data)
    }

    private static func decodeStatistics(_ data: JSONValue) throws -> SessionStatistics {
        let statistics: SessionStatistics
        do { statistics = try JSONDecoder().decode(SessionStatistics.self, from: JSONEncoder().encode(data)) }
        catch { throw RemoteFault.incompatiblePi }
        try statistics.validate()
        return statistics
    }

    /// Local, read-only display hints for a saved session. Does not activate Pi.
    public func sessionDisplayMetadata(sessionID: UUID) async -> SessionDisplayMetadata? {
        guard !Task.isCancelled, let item = sessions.first(where: { $0.info.id == sessionID }),
              let file = item.file else { return nil }
        do {
            let metadata = try await history.displayMetadata(file: file,
                root: support.appendingPathComponent("pi-sessions", isDirectory: true),
                piID: item.piID, directory: item.directory, parentFile: item.parentFile)
            guard !Task.isCancelled, !closing, sessions.contains(where: {
                $0.info.id == sessionID && $0.file == file && $0.piID == item.piID && $0.directory == item.directory
            }) else { return nil }
            return metadata
        } catch { return nil }
    }
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

    public func quitConfirmation() throws -> LocalQuitConfirmation {
        guard !closing else { throw RemoteFault.busy }
        return currentQuitConfirmation()
    }

    private func currentQuitConfirmation() -> LocalQuitConfirmation {
        LocalQuitConfirmation(
            requiresConfirmation: snapshot.working || unresolvedQuitOutcome || snapshot.error == .unknownOutcome ||
                !pendingQuitMutations.isEmpty || lifecycleTransition != nil || recoveringEvents,
            context: snapshot.context, lifecycle: generation, work: workGeneration,
            mutationRevision: mutationRevision, pending: pendingQuitMutations,
            dialogs: snapshot.dialogs.map(\.id), transition: lifecycleTransition)
    }

    /// Validate consent and stop admitting local/remote actions in one actor turn.
    /// The caller must then finish normal shutdown, including listener cleanup.
    public func reserveShutdown(confirmation: LocalQuitConfirmation, confirmed: Bool) throws {
        guard !closing, confirmation == currentQuitConfirmation() else { throw RemoteFault.conflict }
        guard confirmed || !confirmation.requiresConfirmation else { throw RemoteFault.busy }
        closing = true
    }

    public func closeConfirmation(for context: SessionContext) throws -> LocalCloseConfirmation {
        guard context == snapshot.context, context.session != nil, !closing, rpc != nil else { throw RemoteFault.conflict }
        guard snapshot.working, !["starting", "stopping", "recovering"].contains(snapshot.phase),
              snapshot.dialogs.isEmpty, lifecycleTransition == nil, mutations.isEmpty,
              !recoveringEvents, snapshot.error != .unknownOutcome else {
            throw RemoteFault.busy
        }
        return LocalCloseConfirmation(context: context, lifecycle: generation, work: workGeneration)
    }

    private func validateCloseConfirmation(_ confirmation: LocalCloseConfirmation?, for request: AppRequest) throws {
        guard let confirmation else { return }
        guard request.action == .stop, confirmation.context == snapshot.context,
              request.session == confirmation.context.session, request.epoch == confirmation.context.epoch,
              confirmation.lifecycle == generation, confirmation.work == workGeneration,
              rpc != nil, !closing else { throw RemoteFault.conflict }
        guard snapshot.working, !["starting", "stopping", "recovering"].contains(snapshot.phase),
              snapshot.dialogs.isEmpty, lifecycleTransition == nil, mutations.isEmpty,
              !recoveringEvents, snapshot.error != .unknownOutcome else { throw RemoteFault.busy }
    }

    public func handle(_ request: AppRequest, device: UUID, authorization: AuthorizationLease? = nil) async -> AppResult {
        await handle(request, device: device, authorization: authorization, closeConfirmation: nil)
    }

    public func handle(_ request: AppRequest, device: UUID, authorization: AuthorizationLease? = nil,
                       closeConfirmation: LocalCloseConfirmation?) async -> AppResult {
        guard !closing, authorization?.valid ?? true, !Task.isCancelled else { return .failure(.unauthorized) }
        guard request.epoch == epoch else { return .failure(.unknownOutcome) }
        switch request.action {
        case .newSession, .fork, .clone: break // Completed replacements precede their now-stale session binding.
        default:
            guard !request.action.needsSession || (request.session != nil && request.session == snapshot.selected) else { return .failure(.conflict) }
        }
        if closeConfirmation != nil {
            guard request.action == .stop else { return .failure(.conflict) }
            do {
                // Replays need their recorded result, not new consent. Probe a
                // value copy so a stale, undispatched token cannot enter the journal.
                var probe = journal
                switch try probe.begin(device: device, request: request) {
                case .completed(let fault): return fault.map(AppResult.failure) ?? .ok
                case .unknown: return .failure(.unknownOutcome)
                case .dispatch: break
                }
            } catch { return .failure(error as? RemoteFault ?? .storageFailure) }
        }
        do { try validateCloseConfirmation(closeConfirmation, for: request) }
        catch { return .failure(error as? RemoteFault ?? .conflict) }
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
            let result = try await perform(request, closeConfirmation: closeConfirmation)
            // Explicit Stop or a confirmed lifecycle change ends interruption risk
            // from the previous uncertain mutation. Other reads/actions do not.
            if request.action == .stop || request.action == .recoverQueue(stop: true) || request.action == .closeSession || request.action.changesSession {
                if request.action != .recoverQueue(stop: true) || !recoveringEvents { unresolvedQuitOutcome = false }
            }
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
                if fault == .unknownOutcome || fault == .storageFailure { unresolvedQuitOutcome = true }
                journal.finish(device: device, request: request, fault: fault)
                do { try saveJournal() }
                catch {
                    unresolvedQuitOutcome = true
                    snapshot.error = .unknownOutcome; publish()
                    return .failure(.unknownOutcome)
                }
            }
            if snapshot.phase == "starting" && rpc == nil { snapshot.phase = "unavailable" }
            if snapshot.phase == "compacting", fault == .invalidRequest || fault == .providerAuthenticationRequired {
                snapshot.phase = displayPhase
            }
            snapshot.error = fault; publish()
            return .failure(fault)
        }
    }

    private func perform(_ request: AppRequest, closeConfirmation: LocalCloseConfirmation?) async throws -> AppResult {
        // Validate in the same actor turn as mutation reservation and Stop dispatch.
        try validateCloseConfirmation(closeConfirmation, for: request)
        let action = request.action
        if recoveringEvents, action.mutates, action != .stop { throw RemoteFault.busy }
        if action.mutates || action.needsSession {
            let priority: Bool
            switch action { case .stop, .answer, .abortRetry, .abortBash: priority = true; default: priority = false }
            guard priority || mutations.isEmpty else { throw RemoteFault.busy }
            mutations.insert(request.id)
        }
        defer { mutations.remove(request.id); pendingQuitMutations.remove(request.id) }
        if action.mutates {
            mutationRevision &+= 1
            pendingQuitMutations.insert(request.id)
            snapshot.error = nil
        }
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
            let child = try requireRPC()
            workGeneration = UUID()
            _ = try await child.request("abort_retry")
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
            snapshot.bash = nil
            snapshot.selected = nil; snapshot.phase = "idle"; snapshot.messages = []; snapshot.dialogs = []
            snapshot.model = ""; snapshot.thinking = ""; snapshot.models = []; snapshot.thinkingLevels = []; snapshot.commands = []
            snapshot.runtime = nil; snapshot.pendingMessages = nil; snapshot.draft = nil; snapshot.draftID = nil; snapshot.notices = []; snapshot.hasOlderMessages = false
            dialogDeadlines = [:]; clearExtensionDisplay()
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
            return .statistics(try Self.decodeStatistics(data))
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
            guard snapshot.bash?.working != true else { throw RemoteFault.busy }
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
            workGeneration = UUID()
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
        case .bash(let command, let excludeFromContext, let confirmed):
            guard confirmed else { throw RemoteFault.permissionDenied }
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !command.contains("\0"), command.utf8.count <= BashExecution.commandLimit else { throw RemoteFault.invalidRequest }
            guard !snapshot.working, bashCancellation == nil, snapshot.dialogs.isEmpty, snapshot.error != .unknownOutcome else { throw RemoteFault.busy }
            let lifecycle = generation, work = workGeneration
            try await requireIdle()
            guard lifecycle == generation, work == workGeneration, !closing, !snapshot.working else { throw RemoteFault.conflict }
            let child = try requireRPC(), token = generation
            try retainInterruptedState()
            workGeneration = UUID()
            bashCancellation = nil
            snapshot.bash = BashExecution(id: request.id, command: command, excludeFromContext: excludeFromContext)
            snapshot.phase = "bash"; publish()
            let enqueued = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            bashEnqueued = Task { for await _ in enqueued.stream { return } }
            // Accepted work belongs to the host, not the caller's connection or task.
            bashTask = Task { [weak self] in
                defer { enqueued.continuation.finish() }
                do {
                    let result = try await child.request("bash", fields: ["command": .string(command),
                        "excludeFromContext": .bool(excludeFromContext)], timeout: 300, id: request.id.uuidString,
                        onEnqueued: { enqueued.continuation.yield(()) })
                    await self?.finishBash(id: request.id, generation: token, result: result, error: nil)
                } catch {
                    await self?.finishBash(id: request.id, generation: token, result: nil, error: error)
                }
            }
        case .abortBash(let id):
            guard snapshot.bash?.id == id, snapshot.bash?.working == true else { throw RemoteFault.conflict }
            try await abortBash(id: id)
        case .recoverQueue(let stop):
            guard !["starting", "stopping", "recovering"].contains(snapshot.phase), snapshot.dialogs.isEmpty else { throw RemoteFault.busy }
            let child = try requireRPC(), token = generation
            workGeneration = UUID()
            let result = try await child.request("clear_queue")
            guard generation == token, snapshot.selected == request.session else { throw RemoteFault.conflict }
            snapshot.pendingMessages = 0
            let text: String
            do {
                guard let steering = result["steering"]?.array, let followUp = result["followUp"]?.array else { throw RemoteFault.incompatiblePi }
                let messages = steering + followUp
                guard messages.allSatisfy({ $0.string != nil }) else { throw RemoteFault.incompatiblePi }
                text = messages.compactMap(\.string).joined(separator: "\n\n")
                guard text.utf8.count <= 256 * 1_024 else { throw RemoteFault.tooLarge }
            } catch {
                // clear_queue already removed these messages. Do not pretend a
                // truncated draft is complete or automatically queue anything again.
                recoveryNotice = "Pi cleared queued instructions, but their text could not be recovered within the display limit. Do not assume the draft contains them."
                refreshNotices()
                if stop { try await stopWork() }
                throw error
            }
            if stop {
                do { try await stopWork() }
                catch {
                    // Queue recovery succeeded. Do not lose that text because
                    // the separate abort or settlement check failed afterwards.
                    snapshot.error = .unknownOutcome; unresolvedQuitOutcome = true
                    if let child = rpc {
                        _ = await interruptEventStream(child, generation: generation)
                    } else {
                        recoveringEvents = false; snapshot.phase = "interrupted"
                    }
                    recoveryNotice = rpc == nil
                        ? "Queued input was recovered, but Pi did not confirm Stop. The child is no longer running. Reopen explicitly and inspect saved history; recovered text remains unsent."
                        : "Queued input was recovered, but Pi did not confirm Stop. Use Stop again before changing sessions; recovered text remains unsent."
                    refreshNotices()
                }
            }
            return .recoveredQueue(text: text)
        case .stop:
            try await stopWork()
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
            workGeneration = UUID()
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
            guard snapshot.bash?.working != true, bashCancellation == nil else { throw RemoteFault.busy }
            guard let command = snapshot.commands.first(where: { $0.name == name }), arguments.utf8.count <= 16_384 else {
                throw RemoteFault.unsupportedFeature
            }
            guard snapshot.phase != "starting", snapshot.phase != "stopping" else { throw RemoteFault.busy }
            if snapshot.working { guard command.source == "extension" else { throw RemoteFault.busy } }
            else { try await requireIdle() }
            let child = try requireRPC()
            workGeneration = UUID()
            _ = try await child.request("prompt", fields: ["message": .string("/" + name + (arguments.isEmpty ? "" : " " + arguments))])
        case .answer(let id, let value, let confirmed, let cancelled):
            guard let dialog = snapshot.dialogs.first(where: { $0.id == id }),
                  dialogDeadlines[id].map({ $0 > ProcessInfo.processInfo.systemUptime }) ?? true,
                  (value?.utf8.count ?? 0) <= 65_536 else { throw RemoteFault.expired }
            if dialog.method == "unavailable", !cancelled { throw RemoteFault.tooLarge }
            if dialog.method == "confirm", !cancelled, confirmed == nil { throw RemoteFault.invalidRequest }
            if ["input", "editor"].contains(dialog.method), !cancelled, value == nil { throw RemoteFault.invalidRequest }
            if dialog.method == "select", !cancelled, !dialog.options.contains(value ?? "") { throw RemoteFault.invalidRequest }
            let child = try requireRPC()
            workGeneration = UUID()
            try await child.answerDialog(id: id, value: value, confirmed: confirmed, cancelled: cancelled)
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
        // App mutations remain serialized by perform(). Fence the two upstream Pi core reads
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

    private func stopWork() async throws {
        guard snapshot.phase != "starting" || lifecycleTransition != nil else { throw RemoteFault.busy }
        let child = try requireRPC()
        workGeneration = UUID()
        if lifecycleTransition != nil {
            lifecycleTransition = nil; lifecycleUI = []; lifecycleUIOverflow = false
            generation = UUID(); observer?.cancel(); observer = nil
            let stopping = generation
            snapshot.phase = "stopping"; publish()
            for dialog in snapshot.dialogs { try? await child.answerDialog(id: dialog.id, value: nil, confirmed: nil, cancelled: true) }
            guard await interruptEventStream(child, generation: stopping) else { throw RemoteFault.unavailable }
            return
        }
        if recoveringEvents {
            guard await interruptEventStream(child, generation: generation) else { throw RemoteFault.unavailable }
            return
        }
        snapshot.phase = "stopping"; publish()
        _ = try await child.request("clear_queue")
        if recoveringEvents || snapshot.bash?.status == .unknownOutcome {
            guard await interruptEventStream(child, generation: generation) else { throw RemoteFault.unavailable }
            return
        }
        for dialog in snapshot.dialogs { try await child.answerDialog(id: dialog.id, value: nil, confirmed: nil, cancelled: true) }
        snapshot.dialogs = []; dialogDeadlines = [:]
        if let bash = snapshot.bash, bash.working {
            try await abortBash(id: bash.id)
            for _ in 0..<100 {
                if snapshot.bash?.working != true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        if recoveringEvents || snapshot.bash?.working == true || snapshot.bash?.status == .unknownOutcome {
            guard await interruptEventStream(child, generation: generation) else { throw RemoteFault.unavailable }
            return
        }
        await bashCancellation?.value
        let token = generation
        try await child.stopWork()
        guard generation == token, rpc === child else { throw RemoteFault.unknownOutcome }
        if recoveringEvents || snapshot.bash?.working == true || snapshot.bash?.status == .unknownOutcome {
            guard await interruptEventStream(child, generation: token) else { throw RemoteFault.unavailable }
            return
        }
        snapshot.pendingMessages = 0; snapshot.phase = "idle"; try markInterrupted(false)
    }

    private func abortBash(id: UUID) async throws {
        await bashEnqueued?.value
        guard snapshot.bash?.id == id, snapshot.bash?.working == true else { return }
        guard bashCancellation == nil else { return }
        snapshot.bash?.status = .cancelling; publish()
        let token = generation
        bashCancellation = Task { [weak self] in await self?.repeatBashCancellation(id: id, generation: token) }
    }

    private func repeatBashCancellation(id: UUID, generation token: UUID) async {
        defer {
            if snapshot.bash?.id == id {
                bashCancellation = nil
                if generation == token, snapshot.phase == "bash" { snapshot.phase = displayPhase }
                scheduleHistoryRefresh()
                publish()
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        // Upstream handles commands concurrently and awaits user_bash hooks before
        // registering its abort controller. An early acknowledgement can do nothing.
        while generation == token, snapshot.bash?.id == id, snapshot.bash?.working == true,
              !closing, ProcessInfo.processInfo.systemUptime < deadline {
            _ = try? await rpc?.request("abort_bash", timeout: 1)
            if snapshot.bash?.working != true { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == token, snapshot.bash?.id == id, snapshot.bash?.working == true, !closing else { return }
        snapshot.bash?.status = .unknownOutcome; snapshot.bash?.fault = .unknownOutcome
        snapshot.error = .unknownOutcome; unresolvedQuitOutcome = true; recoveringEvents = true
        recoveryNotice = "Pi did not confirm shell cancellation. Use Stop before changing sessions; do not resend the command."
        if snapshot.phase != "stopping" { snapshot.phase = "recovering" }
        refreshNotices(); publish()
    }

    private func finishBash(id: UUID, generation token: UUID, result: JSONValue?, error: (any Error)?) {
        guard token == generation, snapshot.bash?.id == id else { return }
        bashTask = nil; bashEnqueued = nil
        do {
            if let error { throw error }
            guard let result else { throw RemoteFault.incompatiblePi }
            try snapshot.bash?.finish(result)
            runRevision &+= 1
            try retainHistoryPresence()
            try markInterrupted(false)
            historyNeedsRefresh = true
        } catch {
            // Upstream can reject after execution when recording the result fails.
            // No failed bash response proves that side effects did not happen.
            snapshot.bash?.status = .unknownOutcome
            snapshot.bash?.fault = .unknownOutcome
            snapshot.error = .unknownOutcome
            unresolvedQuitOutcome = true
            recoveringEvents = true
            recoveryNotice = "Shell outcome is uncertain. Use Stop, then inspect saved history. Do not resend the command."
            refreshNotices()
        }
        if snapshot.phase != "stopping" { snapshot.phase = displayPhase }
        scheduleHistoryRefresh()
        publish()
    }

    private func scheduleBashPublish() {
        if ContinuousClock.now - lastPublish > .milliseconds(100) { publish() }
        else if scheduledPublish == nil {
            scheduledPublish = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100)); await self?.publishScheduled()
            }
        }
    }

    private func requireIdle() async throws {
        guard snapshot.bash?.working != true, bashCancellation == nil else { throw RemoteFault.busy }
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
            // Upstream Pi core switch_session cannot restore an allocated but unwritten session path.
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
        // be applied to either catalog entry while upstream Pi core replaces its extension runtime.
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
            snapshot.bash = nil
            reducer = TranscriptReducer(); outputImages = OutputImages()
            snapshot.messages = []; snapshot.hasOlderMessages = false; snapshot.dialogs = []
            snapshot.draft = nil; snapshot.draftID = nil; snapshot.notices = []; snapshot.pendingMessages = 0
            dialogDeadlines = [:]; clearExtensionDisplay()
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
        // Upstream Pi core UI records have no session tags. Treat these as transition-generated
        // updates for the resolved context, including a cancelled outgoing hook.
        let events = lifecycleUI; lifecycleUI = []
        for event in events { extensionEvent(event) }
        if lifecycleUIOverflow {
            snapshot.error = .capacity
            extensionMetadata.appendNotice("Some session-transition UI updates exceeded the display limit.", severity: .warning)
            refreshNotices()
        }
        lifecycleUIOverflow = false
        // Keep the subscription: a UI record queued before the RPC reply may not yet
        // have reached this actor. Its normal event path must remain intact.
    }

    private func retainLifecycleUI(_ event: JSONValue) {
        guard let method = event["method"]?.string,
              ["set_editor_text", "notify", "setTitle", "setStatus", "setWidget"].contains(method) else {
            snapshot.error = .unsupportedFeature; return
        }
        if method != "set_editor_text" {
            do { var validation = ExtensionDisplayMetadata(); try validation.consume(event) }
            catch { snapshot.error = error as? RemoteFault ?? .incompatiblePi; return }
        }
        var fields: [String: JSONValue] = ["type": .string("extension_ui_request"), "method": .string(method)]
        for key in ["notifyType", "widgetPlacement"] { fields[key] = event[key] }
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
        snapshot.bash = nil
        snapshot.phase = "starting"; snapshot.selected = id; snapshot.messages = []; snapshot.dialogs = []
        snapshot.draft = nil; snapshot.draftID = nil; snapshot.runtime = nil; snapshot.pendingMessages = nil
        reducer = TranscriptReducer(); outputImages = OutputImages()
        recoveringEvents = false; recoveryNotice = nil
        dialogDeadlines = [:]; clearExtensionDisplay(); publish()
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
        let work = workGeneration, mutation = mutationRevision
        var supersededRun = false
        defer {
            if generation == token {
                historyRefresh = nil
                if supersededRun && allowRetry { scheduleHistoryRefresh(allowRetry: false) }
            }
        }
        do {
            let data = try await requireRPC().request("get_messages")
            guard generation == token, snapshot.selected == session else { return }
            // This is a background read. Do not reserve foreground admission;
            // discard the result if any work or mutation crossed the read.
            guard runRevision == revision, workGeneration == work, mutationRevision == mutation,
                  mutations.isEmpty, !snapshot.working, !closing else {
                supersededRun = runRevision != revision || workGeneration != work || mutationRevision != mutation
                return
            }
            let messages = (data["messages"]?.array ?? []).map { outputImages.message($0) }
            if !messages.isEmpty { try retainHistoryPresence() }
            reducer.replaceHistory(messages)
            snapshot.messages = reducer.messages; snapshot.hasOlderMessages = reducer.omitted
            historyNeedsRefresh = false
            publish()
        } catch {
            if generation == token, snapshot.selected == session, workGeneration == work,
               mutationRevision == mutation, !snapshot.working, !closing {
                snapshot.error = .unavailable; publish()
            }
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
            // A successful upstream Pi core fork is already committed. Never truncate its returned
            // input, reject that success, or repeat it because the native draft is smaller.
            snapshot.draft = oversizedDraft ? nil : forkText
            snapshot.draftID = snapshot.draft == nil ? nil : UUID()
            try await adoptBranch()
            guard generation == token, lifecycleTransition == token, rpc === child, !closing, !Task.isCancelled else { throw RemoteFault.conflict }
            try await requireIdle()
            guard generation == token, lifecycleTransition == token, rpc === child, !closing, !Task.isCancelled else { throw RemoteFault.conflict }
            try finishLifecycleObservation(child)
            if oversizedDraft {
                extensionMetadata.appendNotice("Fork succeeded. The source message exceeds the 256 KiB draft limit and was not copied to the draft.", severity: .warning)
                refreshNotices()
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
        snapshot.bash = nil
        snapshot.selected = info.id; reducer = TranscriptReducer(); outputImages = OutputImages()
        snapshot.messages = []; snapshot.hasOlderMessages = false; snapshot.dialogs = []; snapshot.notices = []; snapshot.pendingMessages = 0
        dialogDeadlines = [:]; clearExtensionDisplay()
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
        if snapshot.bash?.working == true || bashCancellation != nil { return "bash" }
        return reducer.phase == "idle" && (snapshot.pendingMessages ?? 0) > 0 ? "queued" : reducer.phase
    }

    private func preserveUnconfirmedShutdown(_ child: RPCProcess, selected: UUID?) {
        if snapshot.bash?.working == true { snapshot.bash?.status = .unknownOutcome; snapshot.bash?.fault = .unknownOutcome }
        rpc = child; snapshot.selected = selected
        clearExtensionDisplay()
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
        if snapshot.bash?.working == true { snapshot.bash?.status = .unknownOutcome; snapshot.bash?.fault = .unknownOutcome }
        recoveringEvents = true
        clearExtensionDisplay()
        recoveryNotice = "Live events were lost. Recovery is in progress; do not resend accepted work."
        snapshot.phase = "recovering"; snapshot.error = .unknownOutcome
        snapshot.dialogs = []; dialogDeadlines = [:]
        do { try retainInterruptedState() } catch { snapshot.error = .storageFailure }
        refreshNotices(); publish()
        do {
            try await refreshConfiguration()
            try await refreshHistory()
            guard generation == token, rpc === child, !closing else { return false }
            // Upstream Pi core RPC cannot replay lost extension dialogs or report an outstanding retry wait.
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
        if snapshot.bash?.working == true { snapshot.bash?.status = .unknownOutcome; snapshot.bash?.fault = .unknownOutcome }
        generation = UUID()
        snapshot.phase = "stopping"; publish()
        let stopped = await child.shutdown()
        if stopped { rpc = nil }
        observer = nil
        recoveringEvents = !stopped
        snapshot.dialogs = []; dialogDeadlines = [:]; snapshot.pendingMessages = nil
        snapshot.phase = stopped ? "interrupted" : "recovering"
        snapshot.error = .unknownOutcome
        clearExtensionDisplay()
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
        // Upstream Pi core can keep setup/custom context in memory without creating a file.
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
        if event["type"]?.string == "bash_execution_update" {
            guard let id = snapshot.bash?.id, event["id"]?.string == id.uuidString,
                  let delta = event["delta"]?.string else { return }
            snapshot.bash?.append(delta)
            scheduleBashPublish()
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
            workGeneration = UUID()
            runRevision &+= 1
            do { try markInterrupted(true) } catch { snapshot.error = .storageFailure }
        }
        if event["type"]?.string == "agent_settled" {
            workGeneration = UUID()
            runRevision &+= 1
            do { try markInterrupted((snapshot.pendingMessages ?? 0) > 0 || snapshot.bash?.working == true || snapshot.bash?.status == .unknownOutcome || recoveringEvents) }
            catch { snapshot.error = .storageFailure }
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
        } else {
            do { try extensionMetadata.consume(event) }
            catch { snapshot.error = error as? RemoteFault ?? .incompatiblePi }
        }
        refreshNotices()
    }

    private func clearExtensionDisplay() {
        extensionMetadata = ExtensionDisplayMetadata(); recoveryNotice = nil
        snapshot.notices = []; snapshot.extensionDisplay = nil
    }

    private func refreshNotices() {
        snapshot.notices = extensionMetadata.legacyNotices(recovery: recoveryNotice)
        snapshot.extensionDisplay = extensionMetadata.display(recovery: recoveryNotice)
    }

    private func expireDialog(_ id: String, generation token: UUID) {
        guard token == generation, let deadline = dialogDeadlines[id], deadline <= ProcessInfo.processInfo.systemUptime else { return }
        snapshot.dialogs.removeAll { $0.id == id }; dialogDeadlines.removeValue(forKey: id)
        if snapshot.phase == "waiting" { snapshot.phase = snapshot.dialogs.isEmpty ? displayPhase : "waiting" }
        publish()
    }

    private func processEnded(_ token: UUID) {
        guard token == generation else { return }
        workGeneration = UUID()
        runRevision &+= 1
        if snapshot.bash?.working == true { snapshot.bash?.status = .unknownOutcome; snapshot.bash?.fault = .unknownOutcome }
        rpc = nil; recoveringEvents = false; snapshot.phase = "interrupted"; snapshot.error = .unavailable
        snapshot.dialogs = []; dialogDeadlines = [:]; clearExtensionDisplay()
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
        if snapshot.bash?.working == true { snapshot.bash?.status = .unknownOutcome; snapshot.bash?.fault = .unknownOutcome }
        clearExtensionDisplay()
        snapshot.phase = "unavailable"; publish()
    }
}

/// Retains bounded RPC text for legacy clients and plain text for native display slots.
struct ExtensionDisplayMetadata {
    private var statuses: [String: String] = [:]
    private var widgets: [String: ExtensionWidget] = [:]
    private var notices: [ExtensionNotice] = []

    mutating func consume(_ event: JSONValue) throws {
        switch event["method"]?.string {
        case "setStatus":
            let key = try key(event["statusKey"])
            guard event["statusText"] == nil || event["statusText"]?.string != nil else { throw RemoteFault.incompatiblePi }
            let text = event["statusText"]?.string ?? ""
            if text.isEmpty { statuses.removeValue(forKey: key) }
            else {
                try checkCapacity(replacing: statuses[key] != nil)
                statuses[key] = DisplayLimit.text(text, bytes: 2_048)
            }
        case "setWidget":
            let key = try key(event["widgetKey"])
            let placement: ExtensionWidgetPlacement
            if let value = event["widgetPlacement"] {
                guard let raw = value.string, let parsed = ExtensionWidgetPlacement(rawValue: raw) else { throw RemoteFault.incompatiblePi }
                placement = parsed
            } else { placement = .aboveEditor }
            var text = ""
            if let value = event["widgetLines"] {
                guard let lines = value.array, lines.allSatisfy({ $0.string != nil }) else { throw RemoteFault.incompatiblePi }
                text = lines.compactMap(\.string).joined(separator: "\n")
            }
            if text.isEmpty { widgets.removeValue(forKey: key) }
            else {
                try checkCapacity(replacing: widgets[key] != nil)
                widgets[key] = ExtensionWidget(id: key, text: DisplayLimit.text(text, bytes: 2_048), placement: placement)
            }
        case "notify", "setTitle":
            let isTitle = event["method"]?.string == "setTitle"
            guard let text = event[isTitle ? "title" : "message"]?.string else { throw RemoteFault.incompatiblePi }
            var severity = ExtensionNoticeSeverity.info
            if !isTitle, let value = event["notifyType"] {
                guard let raw = value.string, let parsed = ExtensionNoticeSeverity(rawValue: raw) else { throw RemoteFault.incompatiblePi }
                severity = parsed
            }
            appendNotice(text, severity: severity)
        default: throw RemoteFault.unsupportedFeature
        }
    }

    private func key(_ value: JSONValue?) throws -> String {
        guard let key = value?.string else { throw RemoteFault.incompatiblePi }
        guard key.utf8.count <= 256 else { throw RemoteFault.tooLarge }
        return key
    }

    private func checkCapacity(replacing: Bool) throws {
        guard replacing || statuses.count + widgets.count < 16 else { throw RemoteFault.capacity }
    }

    mutating func appendNotice(_ text: String, severity: ExtensionNoticeSeverity = .info) {
        guard !text.isEmpty else { return }
        notices.append(ExtensionNotice(id: UUID().uuidString, text: DisplayLimit.text(text, bytes: 2_048), severity: severity))
        notices = Array(notices.suffix(8))
    }

    func legacyNotices(recovery: String?) -> [String] {
        (recovery.map { [$0] } ?? []) + statuses.keys.sorted().compactMap { statuses[$0] } +
            widgets.keys.sorted().compactMap { widgets[$0]?.text } + notices.map(\.text)
    }

    func display(recovery: String?) -> ExtensionDisplayState {
        let recoveryNotices = recovery.map { [ExtensionNotice(id: "recovery", text: Self.plainText($0), severity: .warning)] } ?? []
        return ExtensionDisplayState(
            statuses: statuses.keys.sorted().compactMap { key in
                statuses[key].map { ExtensionStatus(id: key, text: Self.plainText($0)) }
            },
            widgets: widgets.keys.sorted().compactMap { key in
                widgets[key].map { ExtensionWidget(id: $0.id, text: Self.plainText($0.text), placement: $0.placement) }
            },
            notices: recoveryNotices + notices.suffix(recovery == nil ? 8 : 7).map { ExtensionNotice(id: $0.id, text: Self.plainText($0.text), severity: $0.severity) }
        )
    }

    /// Discards terminal commands, including OSC clipboard/title payloads and incomplete sequences.
    private static func plainText(_ text: String) -> String {
        enum State { case text, escape, escapeIntermediate, csi, controlString, stringEscape }
        var state = State.text, result = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B: state = .escape
                case 0x9B: state = .csi
                case 0x90, 0x98, 0x9D, 0x9E, 0x9F: state = .controlString
                case 0x09, 0x0A: result.unicodeScalars.append(scalar)
                case 0...0x1F, 0x7F...0x9F: break
                default: result.unicodeScalars.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5B: state = .csi
                case 0x50, 0x58, 0x5D, 0x5E, 0x5F: state = .controlString
                case 0x20...0x2F: state = .escapeIntermediate
                case 0x1B: break
                default: state = .text
                }
            case .escapeIntermediate:
                if (0x30...0x7E).contains(value) { state = .text }
            case .csi:
                if (0x40...0x7E).contains(value) { state = .text }
                else if value == 0x1B { state = .escape }
            case .controlString:
                if value == 0x07 || value == 0x9C { state = .text }
                else if value == 0x1B { state = .stringEscape }
            case .stringEscape:
                if value == 0x5C || value == 0x07 || value == 0x9C { state = .text }
                else if value != 0x1B { state = .controlString }
            }
        }
        return result
    }
}
