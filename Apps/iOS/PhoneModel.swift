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
    var authError: String?
    var pairingText = ""
    var pairingInfo: String?
    var panel: String?
    var preview: FilePreview?
    var confirmResend = false
    var editorOffer: EditorOffer?
    struct ContentScope: Equatable { var host: UUID?; var session: UUID?; var epoch: UUID }
    var contentScope: ContentScope { ContentScope(host: selectedMac, session: state?.selected, epoch: generation) }
    var device: UUID
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: ProtectedSecrets
    @ObservationIgnored private let client: RemoteClient
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let secrets = ProtectedSecrets()
        self.secrets = secrets; client = RemoteClient(secrets: secrets)
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
        guard !unlocking else { return }
        unlocking = true; authError = nil
        let token = generation
        let context = LAContext()
        self.context = context
        unlockTask = Task {
            defer { if generation == token { unlocking = false } }
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Pi Remote to view sessions and control your Mac.") else { return }
                guard generation == token, !Task.isCancelled else { return }
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
        confirmResend = false; resendContext = nil; approvedResend = false
        Task { await client.disconnect() }
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
        if self.state?.context != state.context {
            preview = nil; editorOffer = nil; confirmResend = false; resendContext = nil; approvedResend = false
        }
        let key = state.host.uuidString + "/" + (state.selected?.uuidString ?? "new")
        if draftKey != key {
            saveDraft(); draftKey = key; text = drafts[key] ?? ""; image = nil; editorOffer = nil
            saveDraft()
        }
        self.state = state; connected = true
        if let draft = state.draftID, draft != lastDraft {
            lastDraft = draft
            if text.isEmpty { text = state.draft ?? ""; saveDraft() }
            else { editorOffer = EditorOffer(id: draft, session: state.selected, text: state.draft ?? "") }
        }
        if state.dialogs.first != nil { panel = "dialog" }
        else if panel == "dialog" { panel = nil }
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
                let mac = try await RemoteClient.pair(code: code, device: device, name: UIDevice.current.name, secrets: secrets)
                guard generation == token, !locked else { return }
                saved.removeAll { $0.id == mac.id }; saved.append(mac)
                try persistMacs(); pairingText = ""; panel = nil
                pairing = false; pairingInfo = nil
                chooseMac(mac.id)
            } catch { if generation == token { fault = error as? RemoteFault ?? .unavailable } }
        }
    }
    func forget(_ mac: SavedMac) {
        Task {
            do {
                try await client.forget(mac)
                saved.removeAll { $0.id == mac.id }; try persistMacs()
                if selectedMac == mac.id {
                    if let next = saved.first { chooseMac(next.id) }
                    else {
                        saveDraft(); generation = UUID(); selectedMac = nil; state = nil; connected = false; editorOffer = nil
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
            if generation == token || fault == .unknownOutcome { self.fault = fault }
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
        submissions.reviewed(); defaults.set(submissions.needsReview, forKey: "uncertainAction"); fault = nil
    }
    func resend() {
        guard !locked, connected, let resendContext, state?.context == resendContext else { fault = .conflict; return }
        approvedResend = true; reviewedFault(); send(context: resendContext); self.resendContext = nil
    }
    func stop() { Task { do { _ = try await request(.stop) } catch {} } }
}
