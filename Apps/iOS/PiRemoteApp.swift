import PhotosUI
import ImageIO
import UIKit
import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PiRemoteApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: model)
                .onChange(of: scenePhase, initial: true) { _, phase in model.scene(phase) }
        }
    }
}

struct PhoneRoot: View {
    @Bindable var model: PhoneModel
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    var body: some View {
        Group {
            if model.locked || model.covered {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield").font(.largeTitle).accessibilityHidden(true)
                    Text("Pi Remote").font(.title)
                    if let error = model.authError { Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Button(model.unlocking ? "Authenticating…" : "Unlock") { model.unlock() }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(model.unlocking)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            } else {
                NavigationStack {
                    VStack(spacing: 0) {
                        if let fault = model.fault ?? model.state?.error {
                            HStack {
                                Text(fault.explanation).font(.caption)
                                Spacer()
                                Button(model.needsActionReview ? "Reviewed" : "Dismiss") { model.reviewedFault() }
                            }.padding(12)
                        }
                        if let state = model.state {
                            if let session = state.sessions.first(where: { $0.id == state.selected }) {
                                HStack {
                                    Text(session.directory).font(.caption.monospaced()).lineLimit(1)
                                        .accessibilityLabel("Working directory: " + session.directory)
                                    Spacer()
                                    Text(model.connected ? state.phase.capitalized : "Disconnected").font(.caption)
                                }.padding(.horizontal)
                            }
                            if model.image != nil {
                                HStack { Label("Image attached", systemImage: "photo"); Button("Remove") { model.image = nil; photo = nil } }.font(.caption).padding(.horizontal)
                            }
                            ConversationView(state: state, text: $model.text, delivery: $model.delivery, sending: model.sending, send: model.send, stop: model.stop) {
                                Menu {
                                    PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                                    Button("Text file") { importing = true }
                                } label: { Label("Attach", systemImage: "plus").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                            }.disabled(!model.connected)
                        } else {
                            ContentUnavailableView("Connect to your Mac", systemImage: "network",
                                                   description: Text("Start Pi Remote for Mac, then pair or select a saved connection."))
                            Button(model.connecting ? "Connecting…" : "Reconnect") { model.connect() }.disabled(model.connecting)
                            Button("Connections") { model.panel = "connections" }.frame(minHeight: 44)
                        }
                    }
                    .navigationTitle(model.state?.sessions.first(where: { $0.id == model.state?.selected })?.title ?? "Pi Remote")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Sessions", systemImage: "sidebar.left") { model.panel = "sessions" }.labelStyle(.iconOnly).disabled(!model.connected) }
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
        .sheet(isPresented: Binding(get: { model.panel != nil && !model.locked && !model.covered }, set: { if !$0 { model.panel = nil } })) {
            NavigationStack {
                sheet
                    .toolbar {
                        if model.panel != "dialog" { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.panel = nil } } }
                    }
            }
        }
        .confirmationDialog("Send this instruction again?", isPresented: $model.confirmResend) {
            Button("Send again") { model.resend() }
        } message: { Text("The previous action has an unknown outcome. Sending again can repeat file changes or external actions. Check the session first.") }
        .onChange(of: photo) { _, item in
            guard let item else { return }
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
                    guard !model.locked, photo == item else { return }
                    model.image = ImageAttachment(data: jpeg, mimeType: "image/jpeg")
                } catch { model.fault = .tooLarge }
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
                guard !model.locked, !model.covered else { throw RemoteFault.cancelled }
                model.text += "\n\nFile: " + url.lastPathComponent + "\n```\n" + content + "\n```"
            } catch { model.fault = error as? RemoteFault ?? .permissionDenied }
        }
    }

    @ViewBuilder private var sheet: some View {
        switch model.panel {
        case "connections": ConnectionsView(model: model)
        case "pair": PairingView(model: model)
        case "sessions":
            if let state = model.state { SessionListView(state: state, request: model.request, newSession: { model.panel = "directory" }, selected: { model.panel = nil }) }
        case "directory":
            DirectoryBrowser(selecting: true, request: model.request) { id in
                _ = try await model.request(.createSession(directory: id)); model.panel = nil
            }
        case "files": DirectoryBrowser(selecting: false, request: model.request) { _ in }
        case "controls":
            if let state = model.state { SessionControls(state: state, request: model.request) { model.preview = $0; model.panel = "preview" } }
        case "history": HistoryView(request: model.request) { model.panel = nil }
        case "preview": if let value = model.preview { FilePreviewView(preview: value) }
        case "dialog":
            if let dialog = model.state?.dialogs.first {
                ExtensionDialogView(dialog: dialog) { value, confirmed, cancelled in
                    Task { do { _ = try await model.request(.answer(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled)) } catch {} }
                }.id(dialog.id)
            }
        default: EmptyView()
        }
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
                    Text(mac.url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button("Edit address") { editing = mac; address = mac.url.absoluteString }
                        Spacer()
                        Button("Forget", role: .destructive) { model.forget(mac) }
                    }
                }
            }
        }
        .navigationTitle("Mac connections")
        .alert("Server address", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("wss://address:7443/", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") { if let mac = editing { model.updateURL(address, mac: mac) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: { Text("The pinned certificate must be valid for the new address. A private network does not replace device authentication.") }
    }
}

struct PairingView: View {
    @Bindable var model: PhoneModel
    var body: some View {
        Form {
            Text("On your Mac, start the listener and open a two-minute pairing window. Copy the pairing code, then paste it here.")
            TextEditor(text: $model.pairingText).frame(minHeight: 100).font(.caption.monospaced()).autocorrectionDisabled()
            Text("Trust only a code copied from your own Mac. Pairing gives this device Pi control with the Mac user's file and command permissions.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Device ID: " + model.device.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            if let info = model.pairingInfo { Text(info) }
            if let fault = model.fault { Text(fault.explanation).foregroundStyle(.red) }
            Button(model.pairing ? "Waiting for Mac approval…" : "Request pairing") { model.pair() }
                .disabled(model.pairing || model.pairingText.isEmpty).frame(minHeight: 44)
        }.navigationTitle("Pair with Mac")
    }
}
