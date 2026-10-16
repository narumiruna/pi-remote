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
    var text = ""
    var delivery = Delivery.prompt
    var sending = false
    var confirmResend = false
    var editorOffer: EditorOffer?
    @ObservationIgnored private var approvedResend = false
    @ObservationIgnored private var resendContext: SessionContext?
    @ObservationIgnored private var submissions = SubmissionState()
    var fault: RemoteFault?
    var startupError: String?
    var addresses = ListenAddress.all()
    var address = ""
    var listening = false
    var starting = false
    var code = ""
    var pending: PendingPair?
    var devices: [PairedDevice] = []
    var panel: String?
    var preview: FilePreview?
    var piPath = ""
    @ObservationIgnored private(set) var coordinator: HostCoordinator?
    @ObservationIgnored private var registry: DeviceRegistry?
    @ObservationIgnored private let support: URL
    @ObservationIgnored private let secrets = KeychainSecrets(service: "dev.narumi.PiRemote.Host")
    @ObservationIgnored private var server: AppServer?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var identity: ServerIdentity?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var pairingObservation: Task<Void, Never>?
    @ObservationIgnored private var codeExpiry: Task<Void, Never>?
    @ObservationIgnored private var lastDraft: UUID?
    @ObservationIgnored private var draftSession: UUID?
    @ObservationIgnored private var drafts: [UUID: String] = [:]
    @ObservationIgnored private let localDevice = UUID()

    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PiRemote", isDirectory: true)
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/pi").path,
            "/opt/homebrew/bin/pi", "/usr/local/bin/pi"
        ]
        piPath = UserDefaults.standard.string(forKey: "piExecutable") ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/local/bin/pi"
        address = addresses.first(where: { $0.address != "127.0.0.1" })?.address ?? "127.0.0.1"
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
                if self.state.context != state.context {
                    self.preview = nil; self.editorOffer = nil; self.confirmResend = false; self.resendContext = nil; self.approvedResend = false
                }
                if self.draftSession != state.selected {
                    if let old = self.draftSession { self.drafts[old] = self.text }
                    self.draftSession = state.selected; self.editorOffer = nil
                    self.text = state.selected.flatMap { self.drafts[$0] } ?? ""
                }
                self.state = state
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
    func acceptEditorOffer(_ offer: EditorOffer) {
        guard offer.session == state.selected else { editorOffer = nil; return }
        text = offer.text; editorOffer = nil
        if let session = state.selected { drafts[session] = text }
    }
    var needsActionReview: Bool { submissions.uncertain }
    func reviewedFault() { submissions.reviewed(); fault = nil; Task { _ = try? await request(.snapshot) } }
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
                do { try await coordinator?.setExecutable(url); piPath = url.path; UserDefaults.standard.set(url.path, forKey: "piExecutable") }
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
        observation?.cancel(); pairingObservation?.cancel(); codeExpiry?.cancel()
        await server?.stop(); await coordinator?.shutdown()
    }
}
