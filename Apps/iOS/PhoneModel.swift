import Foundation
import LocalAuthentication
import Observation
import PiRemoteClient
import PiRemoteCore
import SwiftUI
import UIKit

@MainActor @Observable
final class PhoneModel {
    var locked = true
    var covered = true
    var unlocking = false
    var connected = false
    var connecting = false
    var pairing = false
    var state: HostSnapshot?
    var saved: [SavedMac] = []
    var selectedMac: UUID?
    var text = ""
    var delivery = Delivery.prompt
    var image: ImageAttachment?
    var sending = false
    var fault: RemoteFault?
    private var dismissedHostFault: RemoteFault?
    var visibleFault: RemoteFault? {
        if needsActionReview { return .unknownOutcome }
        if let fault { return fault }
        return state?.error == dismissedHostFault ? nil : state?.error
    }
    var authError: String?
    var pairingText = ""
    var pairingInfo: String?
    var panel: String?
    var macToForget: SavedMac?
    private(set) var dialogSending = false
    private(set) var dialogFault: RemoteFault?
    private struct DialogScope: Equatable {
        var context: SessionContext
        var generation: UUID
        var id: String
    }
    private var dismissedDialog: DialogScope?
    private var acknowledgedDialog: DialogScope?
    private var dialogAnswerToken: UUID?
    var pendingDialog: ExtensionDialog? {
        guard let scope = pendingDialogScope, acknowledgedDialog != scope else { return nil }
        return state?.dialogs.first
    }
    private var pendingDialogScope: DialogScope? {
        guard let state, let dialog = state.dialogs.first else { return nil }
        return DialogScope(context: state.context, generation: generation, id: dialog.id)
    }
    var preview: FilePreview?
    var confirmResend = false
    var editorOffer: EditorOffer?
    struct ContentScope: Equatable { var host: UUID?; var session: UUID?; var epoch: UUID }
    var contentScope: ContentScope { ContentScope(host: selectedMac, session: state?.selected, epoch: generation) }
    var device: UUID
    typealias Authenticate = @MainActor (LAContext) async throws -> Bool
    @ObservationIgnored private let authenticate: Authenticate
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: ProtectedSecrets
    @ObservationIgnored private let client: any PhoneConnection
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastDraft: UUID?
    @ObservationIgnored private var context: LAContext?
    @ObservationIgnored private var unlockTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var pairTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var approvedResend = false
    @ObservationIgnored private var resendContext: SessionContext?
    @ObservationIgnored private var submissions = SubmissionState()
    @ObservationIgnored private var draftKey: String?
    @ObservationIgnored private var drafts: [String: String] = [:]

    init(defaults: UserDefaults = .standard, connection: (any PhoneConnection)? = nil, authenticate: @escaping Authenticate = { context in
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Pi Remote to view sessions and control your Mac.")
    }) {
        self.defaults = defaults
        self.authenticate = authenticate
        let secrets = ProtectedSecrets()
        self.secrets = secrets; client = connection ?? RemoteClient(secrets: secrets)
        device = defaults.string(forKey: "deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(device.uuidString, forKey: "deviceID")
        if let data = defaults.data(forKey: "savedMacs"),
           let values = try? JSONDecoder().decode([SavedMac].self, from: data) { saved = values }
        selectedMac = defaults.string(forKey: "selectedMac").flatMap(UUID.init(uuidString:)) ?? saved.first?.id
        text = defaults.string(forKey: "draft") ?? ""
        draftKey = defaults.string(forKey: "draftKey")
        drafts = defaults.dictionary(forKey: "sessionDrafts") as? [String: String] ?? [:]
        if defaults.bool(forKey: "uncertainAction") { fault = .unknownOutcome; submissions = SubmissionState(uncertain: true) }
    }

    func scene(_ phase: ScenePhase) {
        switch phase {
        case .active:
            covered = false
            if locked { unlock() }
        case .inactive: covered = true
        case .background: lock()
        @unknown default: lock()
        }
    }
    func unlock() {
        guard locked, !unlocking else { return }
        unlocking = true; authError = nil
        let token = generation
        let context = LAContext()
        self.context = context
        unlockTask = Task {
            defer { if generation == token { unlocking = false } }
            do {
                let approved = try await authenticate(context)
                guard generation == token, !Task.isCancelled else { return }
                guard approved else {
                    authError = "Authentication was not completed. Use Face ID or your device passcode to unlock."
                    return
                }
                secrets.authorize(context); locked = false
                observe(); connect()
            } catch {
                if generation == token { authError = "Authentication was not completed. Use Face ID or your device passcode to unlock." }
            }
        }
    }
    func lock() {
        saveDraft()
        generation = UUID(); locked = true; covered = true
        unlockTask?.cancel(); connectTask?.cancel(); pairTask?.cancel()
        context?.invalidate(); context = nil; secrets.invalidate()
        state = nil; connected = false; connecting = false; unlocking = false; pairing = false
        image = nil; pairingText = ""; pairingInfo = nil; panel = nil; preview = nil; editorOffer = nil
        macToForget = nil; resetDialogPresentation()
        confirmResend = false; resendContext = nil; approvedResend = false
        Task { await client.disconnect(fault: .unavailable) }
    }
    private func observe() {
        guard observation == nil else { return }
        observation = Task { [weak self, client] in
            let stream = await client.updates()
            for await update in stream {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .state(let state):
                    self.applyState(state)
                case .disconnected(let fault):
                    self.connected = false
                    if self.fault != .unknownOutcome && !self.locked { self.fault = fault }
                }
            }
        }
    }
    func applyState(_ state: HostSnapshot) {
        guard !locked, selectedMac == state.host else { return }
        if fault == .unavailable { fault = nil }
        if self.state?.context != state.context || self.state?.error != state.error { dismissedHostFault = nil }
        if self.state?.context != state.context {
            preview = nil; editorOffer = nil; confirmResend = false; resendContext = nil; approvedResend = false
        }
        let key = state.host.uuidString + "/" + (state.selected?.uuidString ?? "new")
        if draftKey != key {
            saveDraft(); draftKey = key; text = drafts[key] ?? ""; image = nil; editorOffer = nil
            saveDraft()
        }
        let previousDialog = pendingDialogScope
        self.state = state; connected = true
        if previousDialog != pendingDialogScope { resetDialogPresentation() }
        if let draft = state.draftID, draft != lastDraft {
            lastDraft = draft
            if text.isEmpty { text = state.draft ?? ""; saveDraft() }
            else { editorOffer = EditorOffer(id: draft, session: state.selected, text: state.draft ?? "") }
        }
        if let scope = pendingDialogScope, dismissedDialog != scope, acknowledgedDialog != scope { panel = "dialog" }
        else if pendingDialog == nil, panel == "dialog" { panel = nil }
    }
    private func resetDialogPresentation() {
        dismissedDialog = nil; acknowledgedDialog = nil; dialogFault = nil; dialogSending = false; dialogAnswerToken = nil
    }
    func closePanel() {
        if panel == "dialog" { dismissedDialog = pendingDialogScope }
        panel = nil
    }
    func reopenDialog() {
        guard !locked, !covered, pendingDialog != nil else { return }
        panel = "dialog"
    }
    func answerDialog(_ dialog: ExtensionDialog, in displayed: HostSnapshot, scope content: ContentScope, value: String?, confirmed: Bool?, cancelled: Bool) {
        let scope = DialogScope(context: displayed.context, generation: content.epoch, id: dialog.id)
        guard !locked, !covered, contentScope == content, pendingDialogScope == scope,
              acknowledgedDialog != scope, !dialogSending else { return }
        guard connected else { dialogFault = .unavailable; return }
        let token = UUID(), request = scopedRequest(for: displayed)
        dialogAnswerToken = token; dialogSending = true; dialogFault = nil
        Task {
            defer {
                if dialogAnswerToken == token { dialogSending = false; dialogAnswerToken = nil }
            }
            do {
                _ = try await request(.answer(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled))
                guard pendingDialogScope == scope, dialogAnswerToken == token else { return }
                // A snapshot can still contain the answered request. Do not present or answer it again.
                acknowledgedDialog = scope
                if panel == "dialog" { panel = nil }
            } catch {
                guard pendingDialogScope == scope, dialogAnswerToken == token else { return }
                dialogFault = error as? RemoteFault ?? .unavailable
            }
        }
    }
    func attachText(_ preview: FilePreview, context: SessionContext) throws {
        guard !locked, !covered else { throw RemoteFault.unauthorized }
        guard connected else { throw RemoteFault.unavailable }
        guard state?.context == context else { throw RemoteFault.conflict }
        text = try TextAttachment.append(preview, to: text)
        saveDraft()
    }

    func connect() {
        guard !locked, !connecting, let mac = saved.first(where: { $0.id == selectedMac }) else { return }
        connectTask?.cancel(); connecting = true
        let token = generation
        connectTask = Task {
            defer { if generation == token { connecting = false } }
            do { try await client.connect(mac) }
            catch { if generation == token { fault = error as? RemoteFault ?? .unavailable; connected = false } }
        }
    }
    func chooseMac(_ id: UUID) {
        saveDraft(); generation = UUID(); editorOffer = nil; image = nil
        confirmResend = false; resendContext = nil; approvedResend = false
        connectTask?.cancel(); pairTask?.cancel(); pairing = false; pairingInfo = nil
        connecting = false; connected = false; state = nil; selectedMac = id
        macToForget = nil; resetDialogPresentation()
        defaults.set(id.uuidString, forKey: "selectedMac")
        connect()
    }
    func acceptPairingScan(_ text: String, scope: ContentScope) -> Bool {
        guard !locked, !covered, !pairing, panel == "pair", contentScope == scope else { return false }
        do {
            _ = try PairingCode.decode(text)
            pairingText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            fault = nil
            return true
        } catch {
            fault = error as? RemoteFault ?? .invalidRequest
            return false
        }
    }

    func pair() {
        guard !locked, !pairing else { return }
        pairing = true
        let token = generation
        pairTask = Task {
            defer { if generation == token { pairing = false; pairingInfo = nil } }
            do {
                let code = try PairingCode.decode(pairingText)
                pairingInfo = "Confirm this device on " + code.name + ": " + device.uuidString
                let mac = try await client.pair(code: code, device: device, name: UIDevice.current.name)
                guard generation == token, !locked else { return }
                saved.removeAll { $0.id == mac.id }; saved.append(mac)
                try persistMacs(); pairingText = ""; panel = nil
                pairing = false; pairingInfo = nil
                chooseMac(mac.id)
            } catch { if generation == token { fault = error as? RemoteFault ?? .unavailable } }
        }
    }
    func requestForget(_ mac: SavedMac) {
        guard !locked, !covered, saved.contains(where: { $0.id == mac.id }) else { return }
        macToForget = mac
    }
    func confirmForget() {
        guard !locked, !covered, let mac = macToForget else { return }
        macToForget = nil
        forget(mac)
    }
    private func forget(_ mac: SavedMac) {
        Task {
            do {
                try await client.forget(mac)
                saved.removeAll { $0.id == mac.id }; try persistMacs()
                if selectedMac == mac.id {
                    if let next = saved.first { chooseMac(next.id) }
                    else {
                        saveDraft(); generation = UUID(); selectedMac = nil; state = nil; connected = false; editorOffer = nil
                        connectTask?.cancel(); connecting = false; panel = nil; resetDialogPresentation()
                        defaults.removeObject(forKey: "selectedMac")
                    }
                }
            } catch { fault = error as? RemoteFault ?? .storageFailure }
        }
    }
    func updateURL(_ value: String, mac: SavedMac) {
        guard let url = URL(string: value), url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil, url.query == nil,
              let index = saved.firstIndex(where: { $0.id == mac.id }) else { fault = .invalidRequest; return }
        saved[index].url = url
        do { try persistMacs(); if mac.id == selectedMac { chooseMac(mac.id) } }
        catch { fault = .storageFailure }
    }
    private func persistMacs() throws {
        defaults.set(try JSONEncoder().encode(saved), forKey: "savedMacs")
    }

    func scopedRequest(for displayed: HostSnapshot) -> (SessionAction) async throws -> AppResult {
        let context = displayed.context, token = generation
        return { [weak self] action in
            guard let self else { throw RemoteFault.unavailable }
            guard self.generation == token, self.state?.context == context else { self.fault = .conflict; throw RemoteFault.conflict }
            let result = try await self.request(action, context: context)
            guard self.generation == token, self.state?.host == context.host, self.state?.epoch == context.epoch,
                  action.changesSession || self.state?.context == context else { throw RemoteFault.conflict }
            return result
        }
    }
    func request(_ action: SessionAction) async throws -> AppResult {
        guard let state else { throw RemoteFault.unavailable }
        return try await request(action, context: state.context)
    }
    private func request(_ action: SessionAction, context: SessionContext) async throws -> AppResult {
        guard !locked, connected else { throw RemoteFault.unavailable }
        let token = generation
        let submission = UUID()
        if action.mutates { submissions.begin(submission); defaults.set(submissions.needsReview, forKey: "uncertainAction") }
        do {
            let result = try await client.request(action, context: context)
            if action.mutates { submissions.finish(submission, fault: nil); defaults.set(submissions.needsReview, forKey: "uncertainAction") }
            return result
        } catch {
            let fault = error as? RemoteFault ?? .unavailable
            if action.mutates { submissions.finish(submission, fault: fault); defaults.set(submissions.needsReview, forKey: "uncertainAction") }
            if (generation == token && state?.context == context) || fault == .unknownOutcome { self.fault = fault }
            throw fault
        }
    }
    func send(context: SessionContext? = nil) {
        guard !sending, connected, !locked, let state else { return }
        guard context == nil || context == state.context else { fault = .conflict; return }
        if submissions.uncertain && !approvedResend { resendContext = state.context; confirmResend = true; return }
        approvedResend = false; sending = true
        let message = text, attachment = image, submittedKey = draftKey, submittedContext = state.context
        let action = SessionAction.prompt(text: message, delivery: state.working ? delivery : .prompt, image: attachment)
        saveDraft()
        Task {
            defer { sending = false }
            do {
                _ = try await request(action, context: submittedContext)
                if let submittedKey, drafts[submittedKey] == message { drafts[submittedKey] = "" }
                if draftKey == submittedKey && text == message { text = ""; image = nil }
                saveDraft()
            } catch {}
        }
    }
    func acceptEditorOffer(_ offer: EditorOffer) {
        guard !locked, offer.session == state?.selected else { editorOffer = nil; return }
        text = offer.text; editorOffer = nil; saveDraft()
    }
    private func saveDraft() {
        if let draftKey { drafts[draftKey] = text }
        defaults.set(drafts, forKey: "sessionDrafts")
        defaults.set(text, forKey: "draft")
        defaults.set(draftKey, forKey: "draftKey")
    }
    var needsActionReview: Bool { submissions.uncertain }
    func reviewedFault() {
        submissions.reviewed(); defaults.set(submissions.needsReview, forKey: "uncertainAction")
        dismissedHostFault = state?.error; fault = nil
    }
    func resend() {
        guard !locked, connected, let resendContext, state?.context == resendContext else { fault = .conflict; return }
        approvedResend = true; reviewedFault(); send(context: resendContext); self.resendContext = nil
    }
    func stop() { Task { do { _ = try await request(.stop) } catch {} } }
}
