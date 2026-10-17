import AppKit
import PiRemoteHost
import SwiftUI

/// The normal startup path. Maintenance controls stay in Connection settings.
struct CompanionServerControls: View {
    @Bindable var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.serverStatus).font(.headline).accessibilityIdentifier("mac-server-status")
            if model.listening {
                Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("mac-server-endpoint")
            } else {
                Picker("Listen address", selection: $model.address) {
                    ForEach(model.addresses) { Text($0.address + " · " + $0.name).tag($0.address) }
                }.disabled(model.starting)
            }
            HStack {
                if model.listening {
                    Button("Pair iPhone") { model.openPairing() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("mac-pair-iphone")
                    Button("Stop server") { model.stopNetwork() }
                        .help("Disconnects phones. Pi work continues on this Mac.")
                } else {
                    Button(model.starting ? "Please wait…" : "Start server") { model.startNetwork() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("mac-start-server")
                    Button("Pair iPhone") { model.openPairing() }
                        .disabled(true).accessibilityIdentifier("mac-pair-iphone")
                }
            }
            .controlSize(.large)
            .disabled(model.starting || model.startupError != nil)
            Text(model.listening ? "On your iPhone, open Connections → Pair a Mac. This Mac must approve new devices." : "Start the server to pair your iPhone. Local Pi sessions do not require the server.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CompanionConnectionSettings: View {
    @Bindable var model: CompanionModel
    @State private var advanced = false
    @State private var resetIdentity = false
    @State private var revokeID: UUID?

    var body: some View {
        Form {
            Section("Server") {
                Text(model.serverStatus)
                Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled)
                Text("To change the listen address, stop the server and select an address in the main window. Stopping the server disconnects phones but does not stop Pi work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.code.isEmpty {
                Section("Pairing") {
                    Text("Pairing code · expires in two minutes").font(.caption)
                    Button("Show pairing QR code") { model.panel = "pairingQR" }
                    Button("Copy pairing code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.code, forType: .string)
                    }
                }
            }
            Section("Paired devices") {
                Text("These devices have saved access. Pairing does not indicate a live connection; live device connection status is not available here.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.devices.isEmpty { Text("No paired devices") }
                ForEach(model.devices) { device in
                    DisclosureGroup {
                        Text("Device ID: " + device.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Revoke access", role: .destructive) { revokeID = device.id }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                            Text("Paired · access allowed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Pi and folder access") {
                LabeledContent("Pi executable") {
                    Text(model.piPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Choose Pi executable") { model.chooseExecutable() }.disabled(model.state.working)
                Button("Folder access") { model.grantFolderAccess() }
                Text("Pi runs with your Mac permissions. Folder selection is not a sandbox for Pi tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Text("Replacing the connection identity revokes every paired device. All phones must pair again. Pi and saved sessions remain on this Mac.")
                        .font(.caption)
                    Button("Replace connection identity", role: .destructive) { resetIdentity = true }
                        .disabled(model.starting)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection settings")
        .confirmationDialog("Replace this Mac's connection identity?", isPresented: $resetIdentity) {
            Button("Revoke devices and replace identity", role: .destructive) { model.resetIdentity() }
        } message: { Text("All phones must pair again. Pi and saved sessions will remain on this Mac.") }
        .confirmationDialog("Revoke this device's access?", isPresented: Binding(
            get: { revokeID != nil }, set: { if !$0 { revokeID = nil } }
        )) {
            Button("Revoke access", role: .destructive) {
                if let id = revokeID { model.revoke(id) }
                revokeID = nil
            }
        } message: { Text("This device will be disconnected and must pair again before it can control Pi. Pi work will continue on this Mac.") }
    }
}
