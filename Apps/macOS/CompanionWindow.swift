import AppKit
import PiRemoteCore
import SwiftUI

struct CompanionWindow: View {
    @Bindable var model: CompanionModel
    var body: some View {
        GeometryReader { geometry in content(size: geometry.size) }
    }

    private func content(size: CGSize) -> some View {
        let state = model.state
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.state.sessions.first(where: { $0.id == model.state.selected })?.title ?? "Pi Remote for Mac").font(.headline)
                    Text(model.state.sessions.first(where: { $0.id == model.state.selected })?.directory ?? "No session selected")
                        .font(.caption.monospaced()).foregroundStyle(.primary.opacity(0.75)).lineLimit(1).help("The full working directory is shown in Session controls.")
                }
                Spacer()
                Text(model.sessionStatus).font(.caption).accessibilityIdentifier("mac-session-status")
                Menu("Session") {
                    Button("Sessions") { model.panel = "sessions" }
                    Button("Controls") { model.panel = "controls" }.disabled(state.selected == nil)
                    Button("History") { model.panel = "history" }.disabled(state.selected == nil || state.working)
                    Button("Files") { model.panel = "files" }.disabled(state.selected == nil)
                }
                Button("Connection settings", systemImage: "gearshape") { model.panel = "connection" }
                    .accessibilityIdentifier("mac-connection-settings")
            }.padding(16)
            if let error = model.startupError { Text(error).foregroundStyle(.primary).padding() }
            if let fault = model.visibleFault {
                HStack { Text(fault.explanation).font(.caption); Spacer(); Button(model.needsActionReview ? "Reviewed" : "Dismiss") { model.reviewedFault() } }.padding(12)
            }
            CompanionServerControls(model: model)
                .padding(.horizontal, 16).padding(.bottom, 12)
            if let pending = model.pending {
                VStack(alignment: .leading) {
                    Text("Allow " + pending.device.name + "?").font(.headline)
                    Text(pending.device.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    Text("This device can control Pi with your Mac permissions, including file changes and command execution.").font(.caption)
                    HStack {
                        Button("Allow") { model.approve(pending.id) }.buttonStyle(.borderedProminent).foregroundStyle(.background)
                        Button("Deny", role: .cancel) { model.deny(pending.id) }
                    }
                }.padding()
            }
            if state.selected == nil {
                CompanionEmptySessionView(available: model.coordinator != nil && model.startupError == nil,
                                          chooseFolder: { model.panel = "directory" },
                                          openSessions: { model.panel = "sessions" })
            } else {
                ConversationView(state: state, text: $model.text, delivery: $model.delivery, sending: model.sending,
                                 send: { model.send(context: state.context) },
                                 stop: { Task { _ = try? await model.scopedRequest(for: state)(.stop) } },
                                 request: model.scopedRequest(for: state)) { EmptyView() }
            }
        }
        .modifier(EditorOfferPrompt(offer: $model.editorOffer, replace: model.acceptEditorOffer))
        .confirmationDialog("Send this instruction again?", isPresented: $model.confirmResend) {
            Button("Send again") { model.resend() }
        } message: { Text("The Mac may have accepted the previous action. Sending again can repeat file changes or external actions.") }
        .sheet(isPresented: Binding(get: { model.panel != nil }, set: { if !$0 { model.panel = nil } })) {
            let request = model.scopedRequest(for: state)
            NavigationStack {
                switch model.panel {
                case "connection": CompanionConnectionSettings(model: model)
                case "sessions":
                    SessionListView(state: state, request: request, newSession: { model.panel = "directory" }, selected: { model.panel = nil })
                case "directory":
                    DirectoryBrowser(selecting: true, request: request, pathEntry: state.capabilities.contains("directory-path")) { id, _ in
                        _ = try await request(.createSession(directory: id)); model.panel = nil
                    }
                case "files":
                    DirectoryBrowser(selecting: false, request: request, attach: { preview in
                        try model.attachText(preview, context: state.context); model.panel = nil
                    }, pathEntry: state.capabilities.contains("directory-path")) { _, _ in }
                case "controls": SessionControls(state: state, request: request, closed: { model.panel = "sessions" }) { model.preview = $0; model.panel = "preview" }
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
            .safeAreaInset(edge: .bottom) {
                if model.panel != "dialog" {
                    HStack {
                        Spacer()
                        Button("Close") { model.panel = nil }
                            .keyboardShortcut(.cancelAction)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("mac-sheet-close")
                    }.padding(.horizontal, 16).background(.bar)
                }
            }
            .formStyle(.grouped)
            .frame(width: min(600, max(480, size.width - 32)),
                   height: min(600, max(360, size.height - 40)))
            .id(state.context)
        }
        .modifier(InterfaceAppearance())
    }

}

struct CompanionEmptySessionView: View {
    let available: Bool
    let chooseFolder: () -> Void
    let openSessions: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.plus").font(.system(size: 32)).accessibilityHidden(true)
                Text("No session selected").font(.title2.bold())
                Text("Choose a Mac folder to start Pi, or open a saved session. You can also start a session from your paired iPhone.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Choose folder and start session", action: chooseFolder)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("mac-choose-folder")
                Button("Open saved session", action: openSessions)
                    .controlSize(.large).accessibilityIdentifier("mac-open-sessions")
            }
            .disabled(!available)
            .frame(maxWidth: 440).padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mac-empty-session")
    }
}
