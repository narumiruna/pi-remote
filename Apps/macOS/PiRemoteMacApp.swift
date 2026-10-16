import AppKit
import PiRemoteCore
import SwiftUI

@MainActor final class CompanionDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await CompanionModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct PiRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    @State private var model = CompanionModel.shared
    var body: some Scene {
        WindowGroup("Pi Remote for Mac", id: "session") {
            CompanionWindow(model: model).frame(minWidth: 540, minHeight: 560).task { model.observe() }
        }
        MenuBarExtra("Pi Remote", systemImage: "sparkle") {
            CompanionMenu(model: model)
        }
    }
}

struct CompanionMenu: View {
    @Bindable var model: CompanionModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.listening ? "Listening · " + model.address : "Not listening")
        Text("Pi: " + model.state.phase)
        Button("Open session") { openWindow(id: "session") }
        Button("Stop work") { model.stopWork() }.disabled(!model.state.working)
        Divider()
        Button("Pair a device") { openWindow(id: "session"); model.openPairing() }.disabled(!model.listening)
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

struct CompanionWindow: View {
    @Bindable var model: CompanionModel
    @State private var settings = false
    @State private var resetIdentity = false
    var body: some View {
        let state = model.state
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.state.sessions.first(where: { $0.id == model.state.selected })?.title ?? "Pi Remote").font(.headline)
                    Text(model.state.sessions.first(where: { $0.id == model.state.selected })?.directory ?? "No session selected")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).help("The full working directory is shown in Session controls.")
                }
                Spacer()
                Text(model.state.phase).font(.caption)
                Menu("Session") {
                    Button("Sessions") { model.panel = "sessions" }
                    Button("Controls") { model.panel = "controls" }
                    Button("History") { model.panel = "history" }.disabled(model.state.working)
                    Button("Files") { model.panel = "files" }
                }
                Button("Connection", systemImage: "network") { settings.toggle() }.labelStyle(.iconOnly)
            }.padding(16)
            if let error = model.startupError { Text(error).foregroundStyle(.red).padding() }
            if let fault = model.needsActionReview ? RemoteFault.unknownOutcome : (model.fault ?? model.state.error) {
                HStack { Text(fault.explanation).font(.caption); Spacer(); Button(model.needsActionReview ? "Reviewed" : "Dismiss") { model.reviewedFault() } }.padding(12)
            }
            if settings || !model.listening { connectionSettings }
            if let pending = model.pending {
                VStack(alignment: .leading) {
                    Text("Allow " + pending.device.name + "?").font(.headline)
                    Text(pending.device.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    Text("This device can control Pi with your Mac permissions, including file changes and command execution.").font(.caption)
                    HStack {
                        Button("Allow") { model.approve(pending.id) }.buttonStyle(.borderedProminent)
                        Button("Deny", role: .cancel) { model.deny(pending.id) }
                    }
                }.padding()
            }
            ConversationView(state: state, text: $model.text, delivery: $model.delivery, sending: model.sending,
                             send: { model.send(context: state.context) },
                             stop: { Task { _ = try? await model.scopedRequest(for: state)(.stop) } }) { EmptyView() }
        }
        .modifier(EditorOfferPrompt(offer: $model.editorOffer, replace: model.acceptEditorOffer))
        .confirmationDialog("Send this instruction again?", isPresented: $model.confirmResend) {
            Button("Send again") { model.resend() }
        } message: { Text("The Mac may have accepted the previous action. Sending again can repeat file changes or external actions.") }
        .confirmationDialog("Replace this Mac's connection identity?", isPresented: $resetIdentity) {
            Button("Revoke devices and replace identity", role: .destructive) { model.resetIdentity() }
        } message: { Text("All phones must pair again. Pi and saved sessions will remain on this Mac.") }
        .sheet(isPresented: Binding(get: { model.panel != nil }, set: { if !$0 { model.panel = nil } })) {
            let request = model.scopedRequest(for: state)
            NavigationStack {
                switch model.panel {
                case "sessions":
                    SessionListView(state: state, request: request, newSession: { model.panel = "directory" }, selected: { model.panel = nil })
                case "directory":
                    DirectoryBrowser(selecting: true, request: request) { id in
                        _ = try await request(.createSession(directory: id)); model.panel = nil
                    }
                case "files": DirectoryBrowser(selecting: false, request: request) { _ in }
                case "controls": SessionControls(state: state, request: request) { model.preview = $0; model.panel = "preview" }
                case "history": HistoryView(request: request, paged: state.capabilities.contains("history-pages")) { model.panel = nil }
                case "dialog":
                    if let dialog = state.dialogs.first {
                        ExtensionDialogView(dialog: dialog) { value, confirmed, cancelled in
                            Task {
                                do { _ = try await request(.answer(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled)) }
                                catch {}
                            }
                        }.id(dialog.id)
                    }
                case "pairingQR": PairingQRView(code: model.code)
                case "preview": if let preview = model.preview { FilePreviewView(preview: preview) }
                default: EmptyView()
                }
            }
            .toolbar {
                if model.panel != "dialog" { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.panel = nil } } }
            }
            .frame(minWidth: 480, minHeight: model.panel == "pairingQR" ? 720 : 420)
            .id(state.context)
        }
    }

    private var connectionSettings: some View {
        Form {
            Picker("Listen address", selection: $model.address) {
                ForEach(model.addresses) { Text($0.address + " · " + $0.name).tag($0.address) }
            }.disabled(model.listening || model.starting)
            HStack {
                Button(model.listening ? "Stop listener" : "Start listener") { if model.listening { model.stopNetwork() } else { model.startNetwork() } }.disabled(model.starting)
                Button("Pair a device") { model.openPairing() }.disabled(!model.listening)
                Button("Pi executable") { model.chooseExecutable() }.disabled(model.state.working)
                Button("Folder access") { model.grantFolderAccess() }
            }
            Text(model.piPath).font(.caption.monospaced()).textSelection(.enabled)
            Button("Replace connection identity", role: .destructive) { resetIdentity = true }.disabled(model.starting)
            if !model.code.isEmpty {
                Text("Pairing code · expires in two minutes").font(.caption)
                Button("Show pairing QR code") { model.panel = "pairingQR" }
                Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.code, forType: .string) }
            }
            ForEach(model.devices) { device in
                HStack { Text(device.name); Spacer(); Button("Revoke", role: .destructive) { model.revoke(device.id) } }
            }
        }.formStyle(.grouped).frame(maxHeight: 260)
    }
}
