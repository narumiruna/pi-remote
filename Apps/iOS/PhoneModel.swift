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
    var device: UUID
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
    @ObservationIgnored private var submissions = SubmissionState()
    @ObservationIgnored private var draftKey: String?
    @ObservationIgnored private var drafts: [String: String] = [:]

    init() {
        let secrets = ProtectedSecrets()
        self.secrets = secrets; client = RemoteClient(secrets: secrets)
        device = UserDefaults.standard.string(forKey: "deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(device.uuidString, forKey: "deviceID")
        if let data = UserDefaults.standard.data(forKey: "savedMacs"),
           let values = try? JSONDecoder().decode([SavedMac].self, from: data) { saved = values }
        selectedMac = UserDefaults.standard.string(forKey: "selectedMac").flatMap(UUID.init(uuidString:)) ?? saved.first?.id
        text = UserDefaults.standard.string(forKey: "draft") ?? ""
        draftKey = UserDefaults.standard.string(forKey: "draftKey")
        drafts = UserDefaults.standard.dictionary(forKey: "sessionDrafts") as? [String: String] ?? [:]
        if UserDefaults.standard.bool(forKey: "uncertainAction") { fault = .unknownOutcome; submissions = SubmissionState(uncertain: true) }
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
            defer { unlocking = false }
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
        state = nil; connected = false; image = nil; pairingText = ""; pairingInfo = nil; panel = nil
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
                    guard !self.locked, self.selectedMac == state.host else { continue }
                    if self.fault == .unavailable { self.fault = nil }
                    let key = state.host.uuidString + "/" + (state.selected?.uuidString ?? "new")
                    if self.draftKey != key {
                        self.saveDraft(); self.draftKey = key; self.text = self.drafts[key] ?? ""; self.image = nil
                        self.saveDraft()
                    }
                    self.state = state; self.connected = true
                    if let draft = state.draftID, draft != self.lastDraft {
                        self.lastDraft = draft
                        if self.text.isEmpty { self.text = state.draft ?? "" } else { self.fault = .conflict }
                    }
                    if state.dialogs.first != nil { self.panel = "dialog" }
                    else if self.panel == "dialog" { self.panel = nil }
                case .disconnected(let fault):
                    self.connected = false
                    if self.fault != .unknownOutcome && !self.locked { self.fault = fault }
                }
            }
        }
    }
    func connect() {
        guard !locked, !connecting, let mac = saved.first(where: { $0.id == selectedMac }) else { return }
        connectTask?.cancel(); connecting = true
        let token = generation
        connectTask = Task {
            defer { connecting = false }
            do { try await client.connect(mac) }
            catch { if generation == token { fault = error as? RemoteFault ?? .unavailable; connected = false } }
        }
    }
    func chooseMac(_ id: UUID) {
        saveDraft()
        connectTask?.cancel(); connecting = false; connected = false; state = nil; selectedMac = id
        UserDefaults.standard.set(id.uuidString, forKey: "selectedMac")
        connect()
    }
    func pair() {
        guard !locked, !pairing else { return }
        pairing = true
        let token = generation
        pairTask = Task {
            defer { pairing = false; pairingInfo = nil }
            do {
                let code = try PairingCode.decode(pairingText)
                pairingInfo = "Confirm this device on " + code.name + ": " + device.uuidString
                let mac = try await RemoteClient.pair(code: code, device: device, name: UIDevice.current.name, secrets: secrets)
                guard generation == token, !locked else { return }
                saved.removeAll { $0.id == mac.id }; saved.append(mac)
                try persistMacs(); pairingText = ""; panel = nil
                chooseMac(mac.id)
            } catch { if generation == token { fault = error as? RemoteFault ?? .unavailable } }
        }
    }
    func forget(_ mac: SavedMac) {
        Task {
            do {
                try await client.forget(mac)
                saved.removeAll { $0.id == mac.id }; try persistMacs()
                if selectedMac == mac.id { selectedMac = saved.first?.id; connected = false; state = nil }
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
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: "savedMacs")
    }

    func request(_ action: SessionAction) async throws -> AppResult {
        try await request(action, expectedSession: state?.selected)
    }
    private func request(_ action: SessionAction, expectedSession: UUID?) async throws -> AppResult {
        guard !locked, connected else { throw RemoteFault.unavailable }
        let submission = UUID()
        if action.mutates { submissions.begin(submission); UserDefaults.standard.set(submissions.needsReview, forKey: "uncertainAction") }
        do {
            let result = try await client.request(action, expectedSession: expectedSession)
            if action.mutates { submissions.finish(submission, fault: nil); UserDefaults.standard.set(submissions.needsReview, forKey: "uncertainAction") }
            return result
        } catch {
            let fault = error as? RemoteFault ?? .unavailable
            if action.mutates { submissions.finish(submission, fault: fault); UserDefaults.standard.set(submissions.needsReview, forKey: "uncertainAction") }
            self.fault = fault
            throw fault
        }
    }
    func send() {
        guard !sending, connected, !locked else { return }
        if submissions.uncertain && !approvedResend { confirmResend = true; return }
        approvedResend = false; sending = true
        let message = text, attachment = image, submittedKey = draftKey, submittedSession = state?.selected
        let action = SessionAction.prompt(text: message, delivery: state?.working == true ? delivery : .prompt, image: attachment)
        saveDraft()
        Task {
            defer { sending = false }
            do {
                _ = try await request(action, expectedSession: submittedSession)
                if let submittedKey, drafts[submittedKey] == message { drafts[submittedKey] = "" }
                if draftKey == submittedKey && text == message { text = ""; image = nil }
                saveDraft()
            } catch {}
        }
    }
    private func saveDraft() {
        if let draftKey { drafts[draftKey] = text }
        UserDefaults.standard.set(drafts, forKey: "sessionDrafts")
        UserDefaults.standard.set(text, forKey: "draft")
        UserDefaults.standard.set(draftKey, forKey: "draftKey")
    }
    var needsActionReview: Bool { submissions.uncertain }
    func reviewedFault() {
        submissions.reviewed(); UserDefaults.standard.set(submissions.needsReview, forKey: "uncertainAction"); fault = nil
    }
    func resend() { approvedResend = true; reviewedFault(); send() }
    func stop() { Task { do { _ = try await request(.stop) } catch {} } }
}
