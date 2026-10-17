import AppKit
import Foundation
import Observation
import PiRemoteCore
import PiRemoteHost
import PiRemoteSecurity

@MainActor @Observable
final class CompanionModel {
    static let shared = CompanionModel()
    var state = HostSnapshot(host: UUID(), epoch: UUID())
    var text = "" { didSet { scheduleDraftSave() } }
    var destination: MacDestination? = .overview { didSet { saveWorkspacePreferences() } }
    var inspectorVisible = false { didSet { saveWorkspacePreferences() } }
    var addedWorkspaces: [String] = []
    var hiddenWorkspaces = Set<String>()
    var expandedWorkspaces = Set<String>()
    var openingSession = false
    var connectedDevices = Set<UUID>()
    var draftSaveError: String?
    var workspaces: [MacWorkspace] {
        let paths = Set(addedWorkspaces).union(state.sessions.map(\.directory)).subtracting(hiddenWorkspaces)
        return paths.sorted().map { path in
            MacWorkspace(directory: path, sessions: state.sessions.filter { $0.directory == path }.sorted { $0.updated > $1.updated })
        }
    }
    var selectedWorkspace: String? {
        switch destination {
        case .workspace(let path): return path
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
        return destination == .session(selected) && state.sessions.contains { $0.id == selected }
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
        case "unavailable", "interrupted": return "Pi: Not running"
        case "recovering": return "Pi: Status uncertain"
        default: return "Pi: " + state.phase.capitalized
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
    @ObservationIgnored private var server: AppServer?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var shuttingDown = false
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
        defaults: UserDefaults = .standard
    ) {
        self.support = support; self.secrets = secrets; self.defaults = defaults
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
            destination = saved.session.map(MacDestination.session) ?? saved.workspace.map(MacDestination.workspace) ?? .overview
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
    func request(_ action: SessionAction) async throws -> AppResult {
        try await request(action, expectedSession: state.selected)
    }
    private func request(_ action: SessionAction, expectedSession: UUID?) async throws -> AppResult {
        guard let coordinator else { throw RemoteFault.storageFailure }
        let request = AppRequest(epoch: coordinator.epoch, session: expectedSession, action: action)
        if action.changesSession { fault = nil }
        if action.mutates { submissions.begin(request.id) }
        let result = await coordinator.handle(request, device: localDevice)
        if case .failure(let error) = result {
            if action.mutates { submissions.finish(request.id, fault: error) }
            fault = error; throw error
        }
        if action.mutates { submissions.finish(request.id, fault: nil) }
        return result
    }

    func send(context: SessionContext? = nil) {
        guard !sending else { return }
        guard context == nil || context == state.context else { fault = .conflict; return }
        if submissions.uncertain && !approvedResend { resendContext = state.context; confirmResend = true; return }
        approvedResend = false
        sending = true
        let message = text, submittedSession = state.selected
        let action = SessionAction.prompt(text: message, delivery: state.working ? delivery : .prompt, image: nil)
        Task {
            defer { sending = false }
            do {
                _ = try await request(action, expectedSession: submittedSession)
                if let submittedSession, drafts[submittedSession] == message { drafts[submittedSession] = "" }
                if draftSession == submittedSession && text == message { text = "" }
            } catch { fault = error as? RemoteFault ?? .unavailable }
        }
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
    func shutdown() async {
        shuttingDown = true
        startup?.cancel()
        if let startup { await startup.value }
        observation?.cancel(); pairingObservation?.cancel(); connectionObservation?.cancel(); codeExpiry?.cancel()
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

    func openSession(_ id: UUID) async {
        destination = .session(id)
        guard state.selected != id || ["unavailable", "interrupted"].contains(state.phase) else { return }
        guard !openingSession, !state.working else { fault = .busy; return }
        openingSession = true
        defer { openingSession = false }
        do { _ = try await request(.resumeSession(id: id)) }
        catch { fault = error as? RemoteFault ?? .unavailable }
    }

    @discardableResult func createSession(in path: String) async -> Bool {
        guard !openingSession, !state.working else { fault = .busy; return false }
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

enum MacDestination: Hashable { case overview, workspace(String), session(UUID), devices, settings }

struct MacWorkspace: Identifiable, Equatable {
    let directory: String
    var sessions: [SessionInfo]
    var id: String { directory }
    var name: String { URL(fileURLWithPath: directory).lastPathComponent.isEmpty ? directory : URL(fileURLWithPath: directory).lastPathComponent }
}

private struct MacWorkspacePreferences: Codable {
    var added: [String]
    var hidden: Set<String>
    var expanded: Set<String>
    var workspace: String?
    var session: UUID?
    var inspectorVisible: Bool
}
