import PhotosUI
import ImageIO
import UIKit
import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct PhoneRoot: View {
    @Bindable var model: PhoneModel
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var pickingPhoto = false
    @State private var attachmentScope: PhoneModel.ContentScope?
    var body: some View {
        Group {
            if model.locked || model.covered {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield").font(.largeTitle).accessibilityHidden(true)
                    Text("Pi Remote").font(.title)
                    if let error = model.authError { Text(error).foregroundStyle(.primary.opacity(0.75)).multilineTextAlignment(.center) }
                    Button { model.unlock() } label: {
                        Text(model.unlocking ? "Authenticating…" : "Unlock").frame(minHeight: 44)
                    }.buttonStyle(.borderedProminent).foregroundStyle(.background).disabled(model.unlocking)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            } else {
                NavigationStack {
                    VStack(spacing: 0) {
                        if let fault = model.visibleFault {
                            HStack(alignment: .top, spacing: 12) {
                                Button { model.panel = "recovery" } label: {
                                    Label(fault.title, systemImage: "exclamationmark.triangle")
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(fault.title)
                                    .accessibilityHint("Show recovery instructions. " + fault.explanation)
                                Spacer(minLength: 0)
                                Button { model.reviewedFault() } label: {
                                    Text(model.needsActionReview ? "Reviewed" : "Dismiss").frame(minWidth: 44, minHeight: 44)
                                }
                            }.font(.caption).padding(12)
                        }
                        if let state = model.state {
                            if !model.connected {
                                HStack {
                                    Text("Disconnected · Cached conversation").font(.caption)
                                    Spacer()
                                    reconnectButton
                                }.padding(.horizontal)
                            }
                            if let dialog = model.pendingDialog {
                                Button { model.reopenDialog() } label: {
                                    Label("Pending request: " + dialog.title, systemImage: "questionmark.bubble")
                                        .frame(minHeight: 44)
                                }.accessibilityIdentifier("reopen-extension-dialog")
                            }
                            if model.image != nil {
                                HStack { Label("Image attached", systemImage: "photo"); Button("Remove") { model.image = nil; photo = nil } }.font(.caption).padding(.horizontal)
                            }
                            ConversationView(state: state, text: $model.text, delivery: $model.delivery, sending: model.sending, remoteAvailable: model.connected, hasAttachment: model.image != nil,
                                             send: { model.send(context: state.context) },
                                             stop: { Task { _ = try? await model.scopedRequest(for: state)(.stop) } },
                                             request: model.connected ? model.scopedRequest(for: state) : nil) {
                                Menu {
                                    Button("Photo", systemImage: "photo") { attachmentScope = model.contentScope; pickingPhoto = true }
                                    Button("Text file") { attachmentScope = model.contentScope; importing = true }
                                } label: { Label("Attach", systemImage: "plus").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                                    .accessibilityLabel("Attach")
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 16) {
                                    ContentUnavailableView("Connect to your Mac", systemImage: "network",
                                                           description: Text("Start Pi Remote for Mac, then pair or select a saved connection."))
                                    reconnectButton
                                    Button { model.panel = "connections" } label: { Text("Connections").frame(minHeight: 44) }
                                }.padding(.bottom, 24)
                            }
                        }
                    }
                    .navigationTitle(model.state?.sessions.first(where: { $0.id == model.state?.selected })?.title ?? "Pi Remote")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            if let state = model.state,
                               let session = state.sessions.first(where: { $0.id == state.selected }) {
                                PhoneConversationTitle(title: session.title, directory: session.directory,
                                                       status: model.connected ? state.phase.capitalized : "Disconnected")
                            }
                        }
                        ToolbarItem(placement: .topBarLeading) { Button("Spaces", systemImage: "square.grid.2x2") { model.panel = "sessions" }.labelStyle(.iconOnly).accessibilityLabel("Spaces").disabled(!model.connected) }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Session controls") { model.panel = "controls" }.disabled(!model.connected)
                                Button("History") { model.panel = "history" }.disabled(!model.connected || model.state?.working == true)
                                Button("Mac files") { model.panel = "files" }.disabled(!model.connected)
                                Button("Connections") { model.panel = "connections" }
                                Button("Lock", systemImage: "lock") { model.lock() }
                                Text(model.connected ? (model.state?.phase ?? "Connected") : "Disconnected")
                            } label: { Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                        }
                    }
                }.privacySensitive()
            }
        }
        .sheet(isPresented: Binding(get: { model.panel != nil && !model.locked && !model.covered }, set: { if !$0 { model.closePanel() } })) {
            NavigationStack {
                sheet
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if model.panel != "dialog" {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { model.panel = nil } label: {
                                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel("Close")
                                    .accessibilityShowsLargeContentViewer { Label("Close", systemImage: "xmark") }
                            }
                        }
                    }
            }
        }
        .modifier(EditorOfferPrompt(offer: $model.editorOffer, replace: model.acceptEditorOffer))
        .confirmationDialog("Send this prompt again?", isPresented: $model.confirmResend) {
            Button("Send again") { model.resend() }
        } message: { Text("The previous action has an unknown outcome. Sending again can repeat file changes or external actions. Check the session first.") }
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: model.locked) { _, locked in
            if locked { pickingPhoto = false; importing = false; photo = nil; attachmentScope = nil }
        }
        .onChange(of: photo) { _, item in
            guard let item, let scope = attachmentScope else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), data.count <= 32 * 1_024 * 1_024,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2_048,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary),
                          let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8), jpeg.count <= 2 * 1_024 * 1_024 else { throw RemoteFault.tooLarge }
                    guard !model.locked, photo == item, model.contentScope == scope else { return }
                    model.image = ImageAttachment(data: jpeg, mimeType: "image/jpeg")
                } catch { if !model.locked, model.contentScope == scope { model.fault = .tooLarge } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .sourceCode, .json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 256 * 1_024 + 1) ?? Data()
                guard data.count <= 256 * 1_024, let content = String(data: data, encoding: .utf8) else { throw RemoteFault.tooLarge }
                guard !model.locked, !model.covered, attachmentScope == model.contentScope else { throw RemoteFault.cancelled }
                model.text = try TextAttachment.append(FilePreview(name: url.lastPathComponent, text: content, truncated: false), to: model.text)
            } catch let error as CocoaError where error.code == .userCancelled {
                // Cancelling a picker is not a file-access failure.
            } catch {
                if !model.locked, attachmentScope == model.contentScope, error as? RemoteFault != .cancelled {
                    model.fault = error as? RemoteFault ?? .permissionDenied
                }
            }
        }
        .modifier(InterfaceAppearance())
    }

    private var reconnectButton: some View {
        Button { model.connect() } label: {
            Text(model.connecting ? "Connecting…" : "Reconnect").frame(minHeight: 44)
        }.disabled(model.connecting || model.selectedMac == nil)
            .accessibilityIdentifier("reconnect")
    }

    @ViewBuilder private var sheet: some View {
        if model.panel == "connections" { ConnectionsView(model: model) }
        else if model.panel == "pair" { PairingView(model: model) }
        else if model.panel == "recovery", let fault = model.visibleFault {
            ScrollView { Text(fault.explanation).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                .navigationTitle(fault.title)
        }
        else if let state = model.state {
            let request = model.scopedRequest(for: state)
            let scope = model.contentScope
            Group {
                switch model.panel {
                case "sessions": SpaceListView(state: state, request: request, newSession: { model.panel = "directory" }, selected: { model.panel = nil })
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
                case "preview": if let value = model.preview { FilePreviewView(preview: value) }
                case "dialog":
                    if let dialog = model.pendingDialog {
                        ExtensionDialogView(dialog: dialog, available: model.connected, sending: model.dialogSending,
                                            fault: model.dialogFault, connecting: model.connecting,
                                            close: { model.closePanel() }, reconnect: { model.connect() }) { value, confirmed, cancelled in
                            model.answerDialog(dialog, in: state, scope: scope, value: value, confirmed: confirmed, cancelled: cancelled)
                        }.id(dialog.id)
                    }
                default: EmptyView()
                }
            }.id(state.context)
        }
    }
}

private struct PhoneConversationTitle: View {
    let title: String
    let directory: String
    let status: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: directory).lastPathComponent).lineLimit(1)
                    .accessibilityHint("Working directory: " + directory + ". Open Session controls for the full path.")
                Text("·").accessibilityHidden(true)
                Text(status).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("phone-session-header")
    }
}

struct ConnectionsView: View {
    @Bindable var model: PhoneModel
    @State private var address = ""
    @State private var editing: SavedMac?
    var body: some View {
        List {
            Button("Pair a Mac", systemImage: "plus") { model.panel = "pair" }.frame(minHeight: 44)
            ForEach(model.saved) { mac in
                VStack(alignment: .leading, spacing: 8) {
                    Button(mac.name) { model.chooseMac(mac.id); model.panel = nil }.frame(minHeight: 44)
                    Text(mac.url.absoluteString).font(.caption.monospaced()).foregroundStyle(.primary.opacity(0.75))
                        .accessibilityLabel("Server address").accessibilityValue(mac.url.absoluteString)
                    HStack {
                        Button { editing = mac; address = mac.url.absoluteString } label: { Text("Edit address").frame(minWidth: 44, minHeight: 44) }
                        Spacer()
                        Button(role: .destructive) { model.requestForget(mac) } label: { Text("Forget").foregroundStyle(Color.primary).frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Mac connections")
        .alert("Forget " + (model.macToForget?.name ?? "Mac") + "?",
               isPresented: Binding(get: { model.macToForget != nil }, set: { if !$0 { model.macToForget = nil } })) {
            Button("Forget Mac", role: .destructive) { model.confirmForget() }
            Button("Cancel", role: .cancel) { model.macToForget = nil }
        } message: {
            Text("This disconnects this iPhone from this Mac, if connected, and deletes its saved credentials for this Mac. Pair again to reconnect. It does not revoke this iPhone on the Mac. To revoke access, use Devices on the Mac.")
        }
        .alert("Server address", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("wss://address:7443/", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") { if let mac = editing { model.updateURL(address, mac: mac) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: { Text("The pinned certificate must be valid for the new address. A private network does not replace device authentication.") }
    }
}

struct PairingView: View {
    @Bindable var model: PhoneModel
    @State private var scanning = false
    @State private var scanScope: PhoneModel.ContentScope?

    var body: some View {
        Form {
            Text("In Pi Remote for Mac, select Start iPhone access, then Pair iPhone to show a pairing QR code. The code expires in two minutes.")
            Button("Scan QR code", systemImage: "qrcode.viewfinder") {
                scanScope = model.contentScope
                scanning = true
            }.frame(minHeight: 44).disabled(model.pairing)
            DisclosureGroup("Paste pairing code instead") {
                TextEditor(text: $model.pairingText).frame(minHeight: 100).font(.caption.monospaced()).autocorrectionDisabled()
            }
            if let code = try? PairingCode.decode(model.pairingText) {
                Section("Mac to pair") {
                    Text(code.name)
                    Text(code.url.absoluteString).font(.caption.monospaced())
                    Text("Check that this is your Mac before requesting pairing.").font(.caption)
                }
            }
            Text("Trust only a code scanned or copied from your own Mac. Pairing gives this device Pi control with the Mac user's file and command permissions.")
                .font(.caption).foregroundStyle(.primary.opacity(0.75))
            Text("Device ID: " + model.device.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            if let info = model.pairingInfo { Text(info) }
            if let fault = model.fault { Text(fault.explanation).foregroundStyle(.primary) }
            Button(model.pairing ? "Waiting for Mac approval…" : "Request pairing") { model.pair() }
                .disabled(model.pairing || model.pairingText.isEmpty).frame(minHeight: 44)
        }
        .navigationTitle("Pair with Mac")
        .fullScreenCover(isPresented: $scanning) {
            PairingScanner { text in
                guard scanning, let scanScope else { return }
                _ = model.acceptPairingScan(text, scope: scanScope)
                scanning = false
                self.scanScope = nil
            }
        }
        .onChange(of: model.locked) { _, locked in
            if locked { scanning = false; scanScope = nil }
        }
        .onChange(of: model.panel) { _, panel in
            if panel != "pair" { scanning = false; scanScope = nil }
        }
    }
}
