import AppKit
import Foundation
import Observation
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity

enum MacNativeSlashCommand: String, CaseIterable, Equatable {
    case resume, tree, history
}

struct MacSlashOption: Identifiable, Equatable {
    var name: String
    var detail: String
    var id: String { name }
    var native: MacNativeSlashCommand?
    private var source: String

    init(name: String, detail: String, native: MacNativeSlashCommand?, source: String = "") {
        self.name = name; self.detail = detail; self.native = native; self.source = source
    }

    func isEnabled(in state: HostSnapshot) -> Bool { disabledReason(in: state) == nil }

    func disabledReason(in state: HostSnapshot) -> String? {
        switch native {
        case .resume:
            guard state.capabilities.contains("sessions") else { return "Session browsing is not available." }
            guard state.dialogs.isEmpty else { return "Answer or cancel the open request first." }
            return ["starting", "stopping", "recovering"].contains(state.phase) ? "Wait for Pi to finish changing state." : nil
        case .tree:
            guard state.capabilities.contains("session-tree") else { return "Session tree is not available." }
            guard state.selected != nil else { return "Select a session first." }
            return state.phase == "idle" ? nil : "Wait for the session to become idle."
        case .history:
            guard state.capabilities.contains("history-pages") else { return "Session history is not available." }
            guard state.selected != nil else { return "Select a session first." }
            return state.working ? "Wait for the session to finish working." : nil
        case nil:
            guard state.selected != nil else { return "Select a session first." }
            guard !["unavailable", "interrupted", "recovering", "starting", "stopping"].contains(state.phase) else { return "This command is not available in the current session state." }
            return state.working && source != "extension" ? "Wait for the session to become idle." : nil
        }
    }
}

struct MacSlashCompletion: Equatable {
    var query: String
    var tokenRange: NSRange
}

enum MacSlashSubmission: Equatable {
    case prompt
    case native(MacNativeSlashCommand)
    case command(name: String, arguments: String)
    case invalid(String)
}

enum MacSlashCommands {
    static func options(in state: HostSnapshot) -> [MacSlashOption] {
        var result = [
            MacSlashOption(name: "resume", detail: "Browse saved sessions", native: .resume),
            MacSlashOption(name: "tree", detail: "Inspect the session tree", native: .tree),
            MacSlashOption(name: "history", detail: "Browse session history", native: .history)
        ]
        var seen = Set(result.map(\.name))
        for command in state.commands where validName(command.name) {
            guard seen.insert(command.name).inserted else { continue }
            result.append(MacSlashOption(name: command.name, detail: command.detail, native: nil, source: command.source))
        }
        return result
    }

    static func matching(in state: HostSnapshot, query: String) -> [MacSlashOption] {
        options(in: state).filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || $0 == "/" }
    }

    private static func leadingToken(in text: String) -> NSRange? {
        let string = text as NSString
        var start = 0
        while start < string.length, (CharacterSet.whitespacesAndNewlines as NSCharacterSet).characterIsMember(string.character(at: start)) { start += 1 }
        guard start < string.length, string.character(at: start) == 47 else { return nil }
        var end = start + 1
        while end < string.length, !(CharacterSet.whitespacesAndNewlines as NSCharacterSet).characterIsMember(string.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        guard !string.substring(with: NSRange(location: start + 1, length: end - start - 1)).contains("/") else { return nil }
        return range
    }

    static func completion(in text: String, selection: NSRange) -> MacSlashCompletion? {
        let string = text as NSString
        guard selection.length == 0, selection.location >= 0, selection.location != NSNotFound,
              selection.location <= string.length,
              Range(selection, in: text) != nil,
              let token = leadingToken(in: text),
              selection.location > token.location, selection.location <= NSMaxRange(token) else { return nil }
        if selection.location > 0, selection.location < string.length {
            let previous = string.character(at: selection.location - 1)
            let next = string.character(at: selection.location)
            guard !(previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF) else { return nil }
        }
        return MacSlashCompletion(query: string.substring(with: NSRange(location: token.location + 1, length: selection.location - token.location - 1)), tokenRange: token)
    }

    static func completing(_ option: MacSlashOption, in text: String, completion: MacSlashCompletion) -> (text: String, selection: NSRange) {
        let string = text as NSString
        let fallback = (text: text, selection: NSRange(location: string.length, length: 0))
        guard validName(option.name), let token = leadingToken(in: text), token == completion.tokenRange else { return fallback }
        let end = NSMaxRange(token)
        let hasSeparator = end < string.length
        let replacement = "/" + option.name + (hasSeparator ? "" : " ")
        let result = string.replacingCharacters(in: token, with: replacement)
        return (result, NSRange(location: token.location + ("/" + option.name).utf16.count + 1, length: 0))
    }

    static func submission(_ text: String, in state: HostSnapshot) -> MacSlashSubmission {
        guard let token = leadingToken(in: text) else { return .prompt }
        let string = text as NSString
        let name = string.substring(with: NSRange(location: token.location + 1, length: token.length - 1))
        guard let option = options(in: state).first(where: { $0.name == name }) else {
            // Preserve literal root paths such as /tmp as ordinary prompt text.
            if validName(name), name.utf8.count <= 255,
               FileManager.default.fileExists(atPath: string.substring(with: token)) { return .prompt }
            return .invalid("Unknown slash command. Choose a command from the list.")
        }
        let end = NSMaxRange(token)
        let arguments = end < string.length ? string.substring(from: end + 1) : ""
        guard arguments.utf8.count <= 16_384 else { return .invalid("Command arguments exceed the 16,384-byte limit.") }
        if let native = option.native {
            guard arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalid("This command does not accept arguments. Use the native picker to select an item.") }
            if let reason = option.disabledReason(in: state) { return .invalid(reason) }
            return .native(native)
        }
        if let reason = option.disabledReason(in: state) { return .invalid(reason) }
        return .command(name: option.name, arguments: arguments)
    }
}

@MainActor @Observable
final class CompanionModel {
    static let shared = CompanionModel()
    var state = HostSnapshot(host: UUID(), epoch: UUID()) {
        didSet {
            if oldValue.context != state.context { composerError = nil }
            reconcileSessionVisibility()
            refreshSessionDisplayMetadata()
        }
    }
    private(set) var sessionDisplayMetadata: [UUID: SessionDisplayMetadata] = [:]
    @ObservationIgnored private var metadataRefresh: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var metadataCatalog: [SessionDisplayCatalogEntry] = []
    private var displayLabels: [UUID: String] = [:]
    private var presentationMetadata: [UUID: SessionDisplayMetadata] = [:]
    var text = "" { didSet { composerError = nil; scheduleDraftSave() } }
    var composerError: String?
    private var inputHistory: [UUID: [String]] = [:]
    var promptHistory: [String] { state.selected.flatMap { inputHistory[$0] } ?? [] }
    var destination: MacDestination? = .conversation { didSet { saveWorkspacePreferences() } }
    var inspectorVisible = false { didSet { saveWorkspacePreferences() } }
    var sidebarVisible = false { didSet { defaults.set(sidebarVisible, forKey: "piSidebarVisible") } }
    private var savedInterfaceMode = MacInterfaceMode.pi
    var interfaceMode: MacInterfaceMode {
        get { savedInterfaceMode }
        set {
            savedInterfaceMode = newValue
            defaults.set(newValue.rawValue, forKey: "macInterfaceMode")
        }
    }
    var addedWorkspaces: [String] = []
    var hiddenWorkspaces = Set<String>()
    var expandedWorkspaces = Set<String>()
    var openingSession = false
    private(set) var closingSession: UUID?
    private(set) var closedSessionIDs = Set<UUID>()
    private(set) var sessionVisibilityError: String?
    @ObservationIgnored private var visibilityPreferencesWritable = true
    @ObservationIgnored private var closeReceipts: [UUID: SessionCloseReceipt] = [:]
    var connectedDevices = Set<UUID>()
    var draftSaveError: String?
    var workspaces: [MacWorkspace] {
        let paths = Set(addedWorkspaces).union(state.sessions.map(\.directory)).subtracting(hiddenWorkspaces)
        return paths.sorted().map { path in
            MacWorkspace(directory: path, sessions: state.sessions.filter { $0.directory == path && !closedSessionIDs.contains($0.id) }.sorted { $0.updated > $1.updated })
        }
    }
    var selectedWorkspace: String? {
        switch destination {
        case .workspace(let path): return path
        case .conversation: return state.sessions.first(where: { $0.id == state.selected })?.directory
        case .session(let id): return state.sessions.first(where: { $0.id == id })?.directory
        default: return nil
        }
    }
    var connectionStatus: String { !listening ? "Remote access off" : (connectedDevices.isEmpty ? "No devices connected" : "\(connectedDevices.count) device\(connectedDevices.count == 1 ? "" : "s") connected") }
    var remoteAccessSummary: String {
        if starting { return "Remote access updating" }
        if !listening { return "Remote access off" }
        return connectedDevices.isEmpty ? "Remote access on · no devices" : connectionStatus
    }
    var showingLoadedSession: Bool {
        guard let selected = state.selected else { return false }
        return (destination == .session(selected) || destination == .conversation) && state.sessions.contains { $0.id == selected }
    }
    var delivery = Delivery.prompt
    var sending = false
    var confirmResend = false
    var editorOffer: EditorOffer?
    @ObservationIgnored private var approvedResend = false
    @ObservationIgnored private var resendContext: SessionContext?
    @ObservationIgnored private var submissions = SubmissionState()
    var fault: RemoteFault?
    private var dismissedHostFault: RemoteFault?
    var visibleFault: RemoteFault? {
        if needsActionReview { return .unknownOutcome }
        if let fault { return fault }
        return state.error == dismissedHostFault ? nil : state.error
    }
    var startupError: String?
    var addresses = ListenAddress.all()
    var address = ""
    var listening = false
    var starting = false
    var serverStatus: String { starting ? "Server: Updating" : (listening ? "Server: Listening" : "Server: Stopped") }
    var serverEndpoint: String { "wss://\(address):7443" }
    var sessionStatus: String { state.selected == nil ? "Session: None" : "Session: \(state.phase)" }
    var piStatus: String {
        guard state.selected != nil else { return "Pi: Not started" }
        switch state.phase {
        case "unavailable", "interrupted": return "Pi: Unavailable"
        case "recovering": return "Pi: Status uncertain"
        case "idle": return "Pi: Idle and ready"
        case "starting": return "Pi: Starting"
        case "waiting": return "Pi: Waiting for input"
        case "stopping": return "Pi: Stopping"
        case "retrying": return "Pi: Retrying"
        case "compacting": return "Pi: Compacting"
        default: return state.working ? "Pi: Processing…" : "Pi: " + state.phase.capitalized
        }
    }
    var code = ""
    var pending: PendingPair?
    var devices: [PairedDevice] = []
    var panel: String?
    var preview: FilePreview?
    var piPath = ""
    @ObservationIgnored private(set) var coordinator: HostCoordinator?
    @ObservationIgnored private var registry: DeviceRegistry?
    @ObservationIgnored private let support: URL
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    let debug: MacDebugController
    @ObservationIgnored private var server: AppServer?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private(set) var shuttingDown = false
    @ObservationIgnored private var terminationTask: Task<Void, Never>?
    @ObservationIgnored private var terminationFinished = false
    @ObservationIgnored private var identity: ServerIdentity?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var pairingObservation: Task<Void, Never>?
    @ObservationIgnored private var connectionObservation: Task<Void, Never>?
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    @ObservationIgnored private var rememberedWorkspace: String?
    @ObservationIgnored private var rememberedSession: UUID?
    @ObservationIgnored private var codeExpiry: Task<Void, Never>?
    @ObservationIgnored private var lastDraft: UUID?
    @ObservationIgnored private var draftSession: UUID?
    @ObservationIgnored private var drafts: [UUID: String] = [:]
    @ObservationIgnored private let localDevice = UUID()

    init(
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PiRemote", isDirectory: true),
        secrets: any SecretStore = KeychainSecrets(service: "dev.narumi.PiRemote.Host"),
        defaults: UserDefaults = .standard,
        debugDirectory: URL = MacDebugServer.defaultDirectory
    ) {
        self.support = support; self.secrets = secrets; self.defaults = defaults
        debug = MacDebugController(directory: debugDirectory)
        sidebarVisible = defaults.bool(forKey: "piSidebarVisible")
        savedInterfaceMode = defaults.string(forKey: "macInterfaceMode").flatMap(MacInterfaceMode.init(rawValue:)) ?? .pi
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/pi").path,
            "/opt/homebrew/bin/pi", "/usr/local/bin/pi"
        ]
        piPath = defaults.string(forKey: "piExecutable") ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/local/bin/pi"
        address = addresses.first(where: { $0.address != "127.0.0.1" })?.address ?? "127.0.0.1"
        if let data = defaults.data(forKey: "workspacePreferences"), let saved = try? JSONDecoder().decode(MacWorkspacePreferences.self, from: data) {
            addedWorkspaces = saved.added; hiddenWorkspaces = saved.hidden; expandedWorkspaces = saved.expanded
            inspectorVisible = saved.inspectorVisible
            rememberedWorkspace = saved.workspace; rememberedSession = saved.session
            destination = saved.session.map(MacDestination.session) ?? saved.workspace.map(MacDestination.workspace) ?? .conversation
        }
        if let value = defaults.object(forKey: "closedSessionIDs") {
            if let data = value as? Data, data.count <= 1_048_576,
               let saved = try? JSONDecoder().decode(MacSessionVisibilityPreferences.self, from: data),
               saved.version == 1, saved.closed.count <= 10_000 {
                closedSessionIDs = saved.closed
                if case .session(let id) = destination, saved.closed.contains(id) {
                    rememberedSession = nil
                    destination = rememberedWorkspace.map(MacDestination.workspace) ?? .conversation
                }
            } else {
                // Keep unreadable preference bytes intact, independently of workspace preferences.
                visibilityPreferencesWritable = false
                sessionVisibilityError = "Session visibility cannot be saved. Back up and remove only the closedSessionIDs preference to restore saving. Saved history and drafts are unchanged."
            }
        }
        if let data = defaults.data(forKey: "sessionDrafts"), data.count <= 8 * 1_024 * 1_024,
           let saved = try? JSONDecoder().decode([UUID: String].self, from: data) { drafts = saved }
        do {
            coordinator = try HostCoordinator(support: support, executable: URL(fileURLWithPath: piPath))
            registry = try DeviceRegistry(secrets: secrets, metadata: support.appendingPathComponent("devices.json"))
        } catch {
            coordinator = nil; registry = nil
            startupError = "Cannot open private host storage. Check disk access and whether another Pi Remote companion is already running."
        }
    }

    func displayName(for session: SessionInfo) -> String {
        displayLabels[session.id] ?? SessionDisplayName.full(session, metadata: nil)
    }

    func fullDisplayName(for session: SessionInfo) -> String {
        SessionDisplayName.full(session, metadata: presentationMetadata[session.id])
    }

    private func rebuildDisplayLabels(catalogChanged: Bool = false) {
        var metadata = sessionDisplayMetadata
        // Only a complete displayed transcript can supply the first instruction.
        if let id = state.selected, !state.hasOlderMessages, metadata[id]?.firstInstruction == nil,
           let message = state.messages.first(where: { $0.role == "user" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            var hints = metadata[id] ?? SessionDisplayMetadata()
            hints.firstInstruction = message.text
            metadata[id] = hints
        }
        guard catalogChanged || metadata != presentationMetadata else { return }
        presentationMetadata = metadata
        displayLabels = SessionDisplayName.labels(sessions: state.sessions, metadata: metadata)
    }

    private func refreshSessionDisplayMetadata() {
        let catalog = state.sessions.map { SessionDisplayCatalogEntry(id: $0.id, updated: $0.updated, title: $0.title, directory: $0.directory) }
        guard catalog != metadataCatalog else { rebuildDisplayLabels(); return }
        let old = Dictionary(uniqueKeysWithValues: metadataCatalog.map { ($0.id, $0) })
        metadataCatalog = catalog
        let current = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        for id in Array(metadataRefresh.keys) where old[id] != current[id] {
            metadataRefresh.removeValue(forKey: id)?.cancel()
        }
        sessionDisplayMetadata = sessionDisplayMetadata.filter { current[$0.key] != nil }
        rebuildDisplayLabels(catalogChanged: true)
        guard let coordinator, !shuttingDown else { return }
        for entry in catalog where old[entry.id] != entry {
            metadataRefresh[entry.id] = Task { [weak self] in
                let metadata = await coordinator.sessionDisplayMetadata(sessionID: entry.id)
                guard let self, !Task.isCancelled, !self.shuttingDown,
                      self.metadataCatalog.contains(entry) else { return }
                self.metadataRefresh.removeValue(forKey: entry.id)
                self.sessionDisplayMetadata[entry.id] = metadata
                self.rebuildDisplayLabels()
            }
        }
    }

    func observe() {
        guard observation == nil, let coordinator else { return }
        observation = Task { [weak self] in
            let stream = await coordinator.updates()
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                if self.state.context != state.context || self.state.error != state.error { self.dismissedHostFault = nil }
                if self.state.context != state.context {
                    self.preview = nil; self.editorOffer = nil; self.confirmResend = false; self.resendContext = nil; self.approvedResend = false
                }
                if self.draftSession != state.selected {
                    if let old = self.draftSession { self.drafts[old] = self.text }
                    self.draftSession = state.selected; self.editorOffer = nil
                    self.text = state.selected.flatMap { self.drafts[$0] } ?? ""
                }
                let previous = self.state.selected
                self.state = state
                if previous != state.selected, self.destination == previous.map(MacDestination.session), let id = state.selected {
                    self.destination = .session(id)
                }
                if let draftID = state.draftID, draftID != self.lastDraft {
                    self.lastDraft = draftID
                    if self.text.isEmpty { self.text = state.draft ?? "" }
                    else { self.editorOffer = EditorOffer(id: draftID, session: state.selected, text: state.draft ?? "") }
                }
                if state.dialogs.first != nil { self.panel = "dialog" }
                else if self.panel == "dialog" { self.panel = nil }
            }
        }
        Task { [weak self, registry] in self?.devices = await registry?.list() ?? [] }
    }

    func scopedRequest(for displayed: HostSnapshot) -> (SessionAction) async throws -> AppResult {
        let context = displayed.context
        return { [weak self] action in
            guard let self else { throw RemoteFault.unavailable }
            guard self.state.context == context else { self.fault = .conflict; throw RemoteFault.conflict }
            let result = try await self.request(action, expectedSession: context.session)
            guard self.state.host == context.host, self.state.epoch == context.epoch,
                  action.changesSession || self.state.context == context else { throw RemoteFault.conflict }
            return result
        }
    }
    /// Background footer reads do not publish recoverable read failures as action faults.
    func readStatistics(for displayed: HostSnapshot) async throws -> SessionStatistics {
        guard state.context == displayed.context, !sending, !openingSession, closingSession == nil,
              let coordinator else { throw RemoteFault.conflict }
        let value = try await coordinator.displayStatistics(context: displayed.context)
        guard state.context == displayed.context else { throw RemoteFault.conflict }
        return value
    }

    func request(_ action: SessionAction) async throws -> AppResult {
        try await request(action, expectedSession: state.selected)
    }
    private func request(_ action: SessionAction, expectedSession: UUID?, closeConfirmation: LocalCloseConfirmation? = nil) async throws -> AppResult {
        guard let coordinator else { throw RemoteFault.storageFailure }
        let request = AppRequest(epoch: coordinator.epoch, session: expectedSession, action: action)
        if action.changesSession { fault = nil }
        if action.mutates { submissions.begin(request.id) }
        let result = await coordinator.handle(request, device: localDevice, closeConfirmation: closeConfirmation)
        if case .failure(let error) = result {
            if action.mutates { submissions.finish(request.id, fault: error) }
            fault = error; throw error
        }
        if action.mutates { submissions.finish(request.id, fault: nil) }
        if case .rename = action, let expectedSession {
            // A real Pi name can equal the old directory fallback. Refresh hints
            // even when the persisted catalog title did not change.
            metadataCatalog.removeAll { $0.id == expectedSession }
            refreshSessionDisplayMetadata()
        }
        return result
    }

    func send(context: SessionContext? = nil) {
        guard !sending, closingSession == nil else { return }
        guard context == nil || context == state.context else { fault = .conflict; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = text, submittedSession = state.selected
        let action: SessionAction
        switch MacSlashCommands.submission(message, in: state) {
        case .prompt:
            action = .prompt(text: message, delivery: state.working ? delivery : .prompt, image: nil)
        case .native(let command):
            guard openNativeWorkflow(command, context: context) else { return }
            if text == message {
                text = ""
                if let submittedSession { drafts[submittedSession] = "" }
            }
            return
        case .command(let name, let arguments):
            action = .command(name: name, arguments: arguments)
        case .invalid(let error):
            composerError = error
            return
        }
        if submissions.uncertain && !approvedResend { resendContext = state.context; confirmResend = true; return }
        approvedResend = false
        composerError = nil
        sending = true
        Task {
            defer { sending = false }
            do {
                _ = try await request(action, expectedSession: submittedSession)
                if let submittedSession {
                    inputHistory[submittedSession] = Array(((inputHistory[submittedSession] ?? []) + [message]).suffix(100))
                }
                if let submittedSession, drafts[submittedSession] == message { drafts[submittedSession] = "" }
                if draftSession == submittedSession && text == message { text = "" }
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }
    @discardableResult func openNativeWorkflow(_ command: MacNativeSlashCommand, context: SessionContext? = nil) -> Bool {
        guard !sending, !shuttingDown, closingSession == nil else { fault = .busy; return false }
        guard context == nil || context == state.context else { fault = .conflict; return false }
        guard let option = MacSlashCommands.options(in: state).first(where: { $0.native == command }) else { return false }
        if let reason = option.disabledReason(in: state) { composerError = reason; return false }
        composerError = nil; panel = command.rawValue
        return true
    }

    func attachText(_ preview: FilePreview, context: SessionContext) throws {
        guard !shuttingDown, state.context == context else { throw RemoteFault.conflict }
        text = try TextAttachment.append(preview, to: text)
        if let session = state.selected { drafts[session] = text }
    }

    func acceptEditorOffer(_ offer: EditorOffer) {
        guard offer.session == state.selected else { editorOffer = nil; return }
        text = offer.text; editorOffer = nil
        if let session = state.selected { drafts[session] = text }
    }
    var needsActionReview: Bool { submissions.uncertain }
    func reviewedFault() {
        submissions.reviewed(); dismissedHostFault = state.error; fault = nil
        if coordinator != nil { Task { _ = try? await request(.snapshot) } }
    }
    func resend() {
        guard let resendContext, state.context == resendContext else { fault = .conflict; return }
        approvedResend = true; submissions.reviewed(); send(context: resendContext); self.resendContext = nil
    }
    func stopWork() { Task { do { _ = try await request(.stop) } catch { fault = error as? RemoteFault ?? .unavailable } } }

    func startNetwork() {
        guard !starting, !listening, !shuttingDown, let coordinator, let registry else { return }
        starting = true
        startup = Task {
            defer { starting = false }
            do {
                let identity = try await ServerIdentity.load(secrets: secrets, support: support)
                guard !shuttingDown, !Task.isCancelled else { return }
                self.identity = identity
                await coordinator.inspectPi()
                guard !shuttingDown, !Task.isCancelled else { return }
                let server = AppServer(coordinator: coordinator, registry: registry)
                self.server = server
                _ = try await server.start(identity: identity, address: address)
                listening = true
                let connections = await server.connectionUpdates()
                connectionObservation = Task { [weak self] in
                    for await devices in connections {
                        guard let self, !Task.isCancelled, self.server === server else { return }
                        self.connectedDevices = devices
                    }
                }
                let updates = await server.pairingUpdates()
                pairingObservation = Task { [weak self] in
                    for await value in updates {
                        guard let self, !Task.isCancelled else { return }
                        self.pending = value
                        if value != nil, self.panel == "pairingQR" { self.panel = nil }
                        self.listening = await server.isRunning()
                        if !self.listening { self.code = "" }
                    }
                }
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }

    func stopNetwork() {
        Task {
            await server?.stop(); server = nil; listening = false; code = ""
            pairingObservation?.cancel(); pairingObservation = nil
            connectionObservation?.cancel(); connectionObservation = nil; connectedDevices = []
        }
    }

    func openPairing() {
        guard let server, let coordinator, let identity, listening else { fault = .unavailable; return }
        codeExpiry?.cancel(); codeExpiry = nil
        Task {
            do {
                let grant = try await server.openPairing()
                code = try PairingCode(
                    host: coordinator.hostID, name: Host.current().localizedName ?? "Mac",
                    url: URL(string: "wss://\(address):7443/")!, certificate: identity.certificate,
                    grant: grant, expires: Date().addingTimeInterval(120)
                ).encoded()
                panel = "pairingQR"
                codeExpiry?.cancel()
                codeExpiry = Task {
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    code = ""; await server.closePairing()
                }
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }
    func approve(_ id: UUID) {
        Task {
            do { try await server?.approve(id); code = ""; devices = await registry?.list() ?? [] }
            catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }
    func deny(_ id: UUID) { Task { await server?.deny(id); code = "" } }
    func revoke(_ id: UUID) {
        Task {
            do {
                if let server { try await server.revoke(id) }
                else { try await registry?.revoke(id) }
                devices = await registry?.list() ?? []
            }
            catch { devices = await registry?.list() ?? []; fault = error as? RemoteFault ?? .storageFailure }
        }
    }
    func resetIdentity() {
        guard !starting, !shuttingDown, let registry else { return }
        starting = true
        startup = Task {
            defer { starting = false }
            await server?.stop(); server = nil; listening = false; code = ""
            pairingObservation?.cancel(); pairingObservation = nil; codeExpiry?.cancel(); codeExpiry = nil
            connectionObservation?.cancel(); connectionObservation = nil; connectedDevices = []
            do {
                for device in await registry.list() {
                    try Task.checkCancellation()
                    try await registry.revoke(device.id)
                }
                try Task.checkCancellation()
                try secrets.remove("server.identity")
                identity = nil; devices = []; addresses = ListenAddress.all()
                address = addresses.first(where: { $0.address != "127.0.0.1" })?.address ?? "127.0.0.1"
            } catch { devices = await registry.list(); fault = error as? RemoteFault ?? .storageFailure }
        }
    }
    func chooseExecutable() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.canChooseFiles = true; picker.showsHiddenFiles = true
        picker.message = "Select the installed Pi executable."
        if picker.runModal() == .OK, let url = picker.url {
            Task {
                do { try await coordinator?.setExecutable(url); piPath = url.path; defaults.set(url.path, forKey: "piExecutable") }
                catch { fault = error as? RemoteFault ?? .busy }
            }
        }
    }
    func grantFolderAccess() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.message = "Grant Mac folder access. This does not register or restrict the iPhone's working directories."
        _ = picker.runModal()
    }
    static func terminationAlert(workChanged: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = workChanged ? "Pi work changed. Stop work and quit?" : "Stop Pi work and quit?"
        alert.informativeText = "Quitting disconnects phones and stops managed Pi, including waiting or uncertain work. File changes cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop work and quit")
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalent = ""
        alert.window.initialFirstResponder = alert.buttons[0]
        return alert
    }

    // Both native Quit and menu-bar Quit enter through the application delegate.
    func requestTermination(confirm: @escaping @MainActor (_ workChanged: Bool) async -> Bool,
                            reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if terminationFinished { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            var workChanged = false
            do {
                // Check consent before cancelling startup. Shutdown cancels it
                // before waiting, so a version check cannot delay this decision.
                if let coordinator {
                    while true {
                        let consent = try await coordinator.quitConfirmation()
                        let confirmed: Bool
                        if consent.requiresConfirmation {
                            confirmed = await confirm(workChanged)
                            guard confirmed else {
                                terminationTask = nil; reply(false); return
                            }
                        } else { confirmed = false }
                        do {
                            try await coordinator.reserveShutdown(confirmation: consent, confirmed: confirmed)
                            break
                        } catch RemoteFault.conflict {
                            // A phone or Pi may have changed work while the dialog was open.
                            workChanged = true
                        }
                    }
                }
                await shutdown()
                terminationFinished = true
                terminationTask = nil
                reply(true)
            } catch {
                fault = error as? RemoteFault ?? .unavailable
                terminationTask = nil
                reply(false)
            }
        }
        return .terminateLater
    }

    func shutdown() async {
        shuttingDown = true
        debug.disable()
        startup?.cancel()
        if let startup { await startup.value }
        observation?.cancel(); pairingObservation?.cancel(); connectionObservation?.cancel(); codeExpiry?.cancel()
        for task in metadataRefresh.values { task.cancel() }
        metadataRefresh.removeAll()
        draftSave?.cancel(); persistDrafts()
        await server?.stop(); await coordinator?.shutdown()
    }

    func chooseWorkspace(startSession: Bool = false) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.prompt = startSession ? "Start Pi here" : "Add workspace"
        picker.message = "Choose a local Mac working directory. Pi runs with your Mac permissions."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        Task {
            do {
                try await addWorkspace(path: url.path); panel = nil
                if startSession { await createSession(in: url.path) }
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }

    func setExpanded(_ path: String, expanded: Bool) {
        if expanded { expandedWorkspaces.insert(path) } else { expandedWorkspaces.remove(path) }
        saveWorkspacePreferences()
    }

    func addWorkspace(path: String) async throws {
        guard case .directories(let page) = try await request(.directoryAtPath(path: path)) else { throw RemoteFault.invalidRequest }
        if !addedWorkspaces.contains(page.path) {
            guard addedWorkspaces.count < 256 else { throw RemoteFault.capacity }
            addedWorkspaces.append(page.path)
        }
        hiddenWorkspaces.remove(page.path); expandedWorkspaces.insert(page.path)
        destination = .workspace(page.path); saveWorkspacePreferences()
    }

    func removeWorkspace(_ path: String) {
        addedWorkspaces.removeAll { $0 == path }; hiddenWorkspaces.insert(path); expandedWorkspaces.remove(path)
        if rememberedWorkspace == path || state.sessions.contains(where: { $0.id == rememberedSession && $0.directory == path }) {
            rememberedWorkspace = nil; rememberedSession = nil
        }
        if selectedWorkspace == path { destination = .overview }
        saveWorkspacePreferences()
    }

    func closeSessionDisabledReason(_ id: UUID) -> String? {
        guard state.sessions.contains(where: { $0.id == id }) else { return "This saved session is no longer available." }
        guard closingSession == nil, !openingSession, !shuttingDown else { return "Wait for the session change to finish." }
        guard state.selected == id else { return nil }
        guard !sending, !submissions.needsReview, state.error != .unknownOutcome else { return "Wait for pending actions or review the unknown outcome first." }
        guard state.dialogs.isEmpty else { return "Answer or cancel the open request first." }
        guard state.phase == "idle" || closeSessionRequiresConfirmation(id) else { return "Wait for Pi to reach a known working or idle state." }
        return nil
    }

    func closeSessionRequiresConfirmation(_ id: UUID) -> Bool {
        state.selected == id && ["working", "streaming", "tool", "retrying", "compacting", "queued", "bash"].contains(state.phase)
    }

    func prepareSessionClose(_ id: UUID) async -> LocalCloseConfirmation? {
        guard closeSessionDisabledReason(id) == nil, closeSessionRequiresConfirmation(id), let coordinator else {
            fault = .busy; return nil
        }
        let context = state.context
        do {
            let confirmation = try await coordinator.closeConfirmation(for: context)
            try Task.checkCancellation()
            guard state.context == context, closeSessionDisabledReason(id) == nil,
                  closeSessionRequiresConfirmation(id) else { throw RemoteFault.conflict }
            return confirmation
        } catch { fault = error as? RemoteFault ?? .unavailable; return nil }
    }

    @discardableResult func closeSession(_ id: UUID, confirmation: LocalCloseConfirmation? = nil) async -> Bool {
        guard confirmation == nil || (confirmation?.context == state.context && closeSessionRequiresConfirmation(id)) else {
            fault = .conflict; return false
        }
        guard closeSessionDisabledReason(id) == nil else { fault = .busy; return false }
        let displayed = state
        let context = displayed.context
        let loaded = context.session == id
        guard !loaded || !state.working || confirmation?.context == context else { fault = .busy; return false }
        closingSession = id
        defer { closingSession = nil }
        do {
            try Task.checkCancellation()
            var receipt: HostSnapshot?
            if loaded {
                if let draftSession { drafts[draftSession] = text }
                draftSave?.cancel(); persistDrafts()
                guard draftSaveError == nil else { throw RemoteFault.capacity }
                guard let coordinator else { throw RemoteFault.unavailable }
                let initial = await coordinator.state()
                try Task.checkCancellation()
                guard state.context == context, !shuttingDown, !sending,
                      !submissions.needsReview, state.error != .unknownOutcome, state.dialogs.isEmpty,
                      initial.context == context, initial.dialogs.isEmpty, initial.error != .unknownOutcome,
                      initial.phase == displayed.phase, state.phase == displayed.phase else { throw RemoteFault.conflict }
                let action = scopedRequest(for: displayed)
                if displayed.working {
                    // The host checks the captured work token before accepting Stop.
                    _ = try await request(.stop, expectedSession: id, closeConfirmation: confirmation)
                    // Stop acknowledges cancellation. Require authoritative idle in the same context.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while true {
                        try Task.checkCancellation()
                        guard state.context == context, !shuttingDown, !sending,
                              !submissions.needsReview, state.error != .unknownOutcome, state.dialogs.isEmpty else { throw RemoteFault.conflict }
                        let current = await coordinator.state()
                        guard current.context == context, current.dialogs.isEmpty, current.error != .unknownOutcome else { throw RemoteFault.conflict }
                        if current.phase == "idle" { break }
                        guard !["recovering", "unavailable", "interrupted", "starting"].contains(current.phase),
                              ContinuousClock.now < deadline else { throw RemoteFault.unavailable }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                guard state.context == context, !shuttingDown, !sending,
                      !submissions.needsReview, state.error != .unknownOutcome, state.dialogs.isEmpty else { throw RemoteFault.conflict }
                let beforeClose = await coordinator.state()
                try Task.checkCancellation()
                guard beforeClose.context == context, beforeClose.phase == "idle", beforeClose.dialogs.isEmpty,
                      beforeClose.error != .unknownOutcome else { throw RemoteFault.conflict }
                guard state.context == context, !shuttingDown, !sending,
                      !submissions.needsReview, state.error != .unknownOutcome, state.dialogs.isEmpty else { throw RemoteFault.conflict }
                _ = try await action(.closeSession)
                receipt = await coordinator.state()
            }
            try Task.checkCancellation()
            try finishSessionClose(id, context: context, receipt: receipt)
            return true
        } catch { fault = error as? RemoteFault ?? .unavailable; return false }
    }

    // Keep this transition synchronous: an observer cannot interleave its update
    // between the sequence check and the local visibility change.
    func finishSessionClose(_ id: UUID, context: SessionContext, receipt: HostSnapshot?) throws {
        guard !shuttingDown else { throw RemoteFault.conflict }
        if let receipt {
            guard receipt.host == context.host, receipt.epoch == context.epoch, receipt.selected == nil,
                  state.host == context.host, state.epoch == context.epoch,
                  state.selected == nil || (state.selected == id && state.sequence <= receipt.sequence) else {
                throw RemoteFault.conflict
            }
            closeReceipts[id] = SessionCloseReceipt(host: receipt.host, epoch: receipt.epoch, sequence: receipt.sequence)
        }
        closedSessionIDs.insert(id)
        saveSessionVisibility()
        if destination == .session(id),
           let path = state.sessions.first(where: { $0.id == id })?.directory { destination = .workspace(path) }
    }

    private func reconcileSessionVisibility() {
        guard let id = state.selected, closedSessionIDs.contains(id) else { return }
        if let receipt = closeReceipts[id], receipt.host == state.host, receipt.epoch == state.epoch,
           state.sequence <= receipt.sequence { return }
        closedSessionIDs.remove(id); closeReceipts.removeValue(forKey: id)
        saveSessionVisibility()
        if let path = state.sessions.first(where: { $0.id == id })?.directory {
            hiddenWorkspaces.remove(path); expandedWorkspaces.insert(path)
            saveWorkspacePreferences()
        }
    }

    private func saveSessionVisibility() {
        guard visibilityPreferencesWritable else { return }
        guard closedSessionIDs.count <= 10_000,
              let data = try? JSONEncoder().encode(MacSessionVisibilityPreferences(version: 1, closed: closedSessionIDs)), data.count <= 1_048_576 else {
            sessionVisibilityError = "Session visibility exceeds the local storage limit. This visibility change will not survive an app restart."
            return
        }
        defaults.set(data, forKey: "closedSessionIDs"); sessionVisibilityError = nil
    }

    private func revealSession(_ id: UUID) {
        closedSessionIDs.remove(id); closeReceipts.removeValue(forKey: id)
        saveSessionVisibility()
        if let path = state.sessions.first(where: { $0.id == id })?.directory {
            hiddenWorkspaces.remove(path); expandedWorkspaces.insert(path)
        }
        destination = .session(id)
    }

    @discardableResult func openSession(_ id: UUID) async -> Bool {
        destination = .session(id)
        guard closingSession == nil, !openingSession else { fault = .busy; return false }
        guard state.selected != id || ["unavailable", "interrupted"].contains(state.phase) else { revealSession(id); return true }
        guard !state.working else { fault = .busy; return false }
        openingSession = true
        defer { openingSession = false }
        do {
            _ = try await scopedRequest(for: state)(.resumeSession(id: id))
            guard let coordinator, await coordinator.state().selected == id else { throw RemoteFault.conflict }
            revealSession(id)
            return true
        } catch { fault = error as? RemoteFault ?? .unavailable; return false }
    }

    @discardableResult func createSession(in path: String) async -> Bool {
        guard !openingSession, closingSession == nil, !state.working else { fault = .busy; return false }
        openingSession = true
        defer { openingSession = false }
        do {
            let displayed = state.context
            guard case .directories(let page) = try await scopedRequest(for: state)(.directoryAtPath(path: path)), state.context == displayed else { throw RemoteFault.conflict }
            _ = try await scopedRequest(for: state)(.createSession(directory: page.id))
            if let coordinator, let id = await coordinator.state().selected { destination = .session(id) }
            return true
        } catch { fault = error as? RemoteFault ?? .unavailable; return false }
    }

    func revealWorkspace(_ path: String) {
        Task {
            do {
                guard case .directories(let page) = try await request(.directoryAtPath(path: path)) else { throw RemoteFault.invalidRequest }
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: page.path)
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }

    func revealEntry(_ id: UUID, directory: Bool) {
        Task {
            do {
                guard let coordinator else { throw RemoteFault.unavailable }
                let path = try await coordinator.directories.resolve(id, directory: directory)
                NSWorkspace.shared.activateFileViewerSelecting([path.url])
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
    }

    func copy(_ value: String) {
        do { try LocalClipboard.copy(value) } catch { fault = error as? RemoteFault ?? .unavailable }
    }

    private func saveWorkspacePreferences() {
        switch destination {
        case .session(let id):
            rememberedSession = id
            if let path = state.sessions.first(where: { $0.id == id })?.directory { rememberedWorkspace = path }
        case .workspace(let path): rememberedWorkspace = path; rememberedSession = nil
        default: break
        }
        let saved = MacWorkspacePreferences(added: addedWorkspaces, hidden: hiddenWorkspaces, expanded: expandedWorkspaces,
                                            workspace: rememberedWorkspace, session: rememberedSession, inspectorVisible: inspectorVisible)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "workspacePreferences") }
    }

    private func scheduleDraftSave() {
        guard let session = draftSession else { return }
        drafts[session] = text
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.persistDrafts()
        }
    }

    private func persistDrafts() {
        guard drafts.values.allSatisfy({ $0.utf8.count <= 256 * 1_024 }),
              let data = try? JSONEncoder().encode(drafts), data.count <= 8 * 1_024 * 1_024 else {
            draftSaveError = "This draft is too large to save locally. Copy it before closing the app."; return
        }
        defaults.set(data, forKey: "sessionDrafts"); draftSaveError = nil
    }
}

enum MacDestination: Hashable { case conversation, overview, workspace(String), session(UUID), devices, settings }

struct MacWorkspace: Identifiable, Equatable {
    let directory: String
    var sessions: [SessionInfo]
    var id: String { directory }
    var name: String { URL(fileURLWithPath: directory).lastPathComponent.isEmpty ? directory : URL(fileURLWithPath: directory).lastPathComponent }
}

private struct SessionDisplayCatalogEntry: Equatable {
    var id: UUID
    var updated: Date
    var title: String
    var directory: String
}

/// Pure local naming policy. Never changes the catalog or a Pi session name.
enum SessionDisplayName {
    static func full(_ session: SessionInfo, metadata: SessionDisplayMetadata?) -> String {
        let raw = usable(session.title)
        let basename = usable(URL(fileURLWithPath: session.directory).lastPathComponent)
        if let raw, raw != basename { return raw }
        if let name = usable(metadata?.name) { return name }
        if let instruction = usable(metadata?.firstInstruction) { return instruction }
        return "Session · " + shortID(session.id)
    }

    static func resolve(_ session: SessionInfo, sessions: [SessionInfo], metadata: [UUID: SessionDisplayMetadata]) -> String {
        labels(sessions: sessions, metadata: metadata)[session.id] ?? concise(full(session, metadata: metadata[session.id]))
    }

    static func labels(sessions: [SessionInfo], metadata: [UUID: SessionDisplayMetadata]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for workspace in Dictionary(grouping: sessions, by: \.directory).values {
            let base = Dictionary(uniqueKeysWithValues: workspace.map { ($0.id, concise(full($0, metadata: metadata[$0.id]))) })
            var lengths: [UUID: Int] = [:]
            var labels = base
            // Each collision increases a suffix, up to the unique full UUID.
            while true {
                let collisions = Dictionary(grouping: workspace, by: { labels[$0.id]! }).values.filter { $0.count > 1 }
                if collisions.isEmpty { break }
                for group in collisions {
                    for session in group {
                        let length = min(36, lengths[session.id].map { $0 + 1 } ?? 8)
                        lengths[session.id] = length
                        labels[session.id] = concise(base[session.id]!, limit: 70 - length - 3) + " · " + shortID(session.id, length: length)
                    }
                }
            }
            result.merge(labels) { _, new in new }
        }
        return result
    }

    private static func usable(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.isEmpty ? nil : String(normalized.prefix(4_096))
    }
    private static func concise(_ text: String, limit: Int = 70) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
    private static func shortID(_ id: UUID, length: Int = 8) -> String {
        String(id.uuidString.lowercased().prefix(length))
    }
}

private struct SessionCloseReceipt {
    var host: UUID
    var epoch: UUID
    var sequence: UInt64
}

private struct MacSessionVisibilityPreferences: Codable {
    var version: Int
    var closed: Set<UUID>
}

private struct MacWorkspacePreferences: Codable {
    var added: [String]
    var hidden: Set<String>
    var expanded: Set<String>
    var workspace: String?
    var session: UUID?
    var inspectorVisible: Bool
}
