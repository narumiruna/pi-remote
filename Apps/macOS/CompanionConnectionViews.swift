import AppKit
import PiRemoteHost
import SwiftUI

struct CompanionServerControls: View {
    @Bindable var model: CompanionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.serverStatus).font(.headline).accessibilityIdentifier("mac-server-status")
            if model.listening {
                Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("mac-server-endpoint")
            }
            HStack {
                if model.listening {
                    Button("Pair iPhone") { model.openPairing() }.buttonStyle(.borderedProminent)
                    Button("Stop server") { model.stopNetwork() }
                } else {
                    Button(model.starting ? "Please wait…" : "Start server") { model.startNetwork() }.buttonStyle(.borderedProminent)
                    Button("Network settings") { model.destination = .settings }
                }
            }.disabled(model.starting || model.startupError != nil)
            Text("The server is only needed for iPhone access. Local Pi sessions work without it.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CompanionConnectionSettings: View {
    @Bindable var model: CompanionModel
    @State private var advanced = false
    @State private var resetIdentity = false

    var body: some View {
        Form {
            Section("Network") {
                Text(model.serverStatus)
                Picker("Listen address", selection: $model.address) {
                    ForEach(model.addresses) { Text($0.address + " · " + $0.name).tag($0.address) }
                }.disabled(model.listening || model.starting)
                if model.listening { Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled) }
                Button(model.listening ? "Stop server" : "Start server") {
                    if model.listening { model.stopNetwork() } else { model.startNetwork() }
                }.disabled(model.starting || model.startupError != nil)
                Text("The server is optional for local use. Stopping it disconnects phones but does not stop Pi work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pi and folder access") {
                LabeledContent("Pi executable") {
                    Text(model.piPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Choose Pi executable") { model.chooseExecutable() }.disabled(model.state.working)
                Button("Folder access") { model.grantFolderAccess() }
                Text("Pi runs with your Mac permissions. Workspaces organize sessions; they are not a sandbox for Pi tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Text("Replacing the connection identity revokes every paired device. All phones must pair again. Pi and saved sessions remain on this Mac.")
                        .font(.caption)
                    Button("Replace connection identity", role: .destructive) { resetIdentity = true }.disabled(model.starting)
                }
            }
        }.formStyle(.grouped).navigationTitle("Settings")
        .confirmationDialog("Replace this Mac's connection identity?", isPresented: $resetIdentity) {
            Button("Revoke devices and replace identity", role: .destructive) { model.resetIdentity() }
        } message: { Text("All phones must pair again. Pi and saved sessions will remain on this Mac.") }
    }
}

struct CompanionDevicesView: View {
    @Bindable var model: CompanionModel
    @State private var revokeID: UUID?

    var body: some View {
        Form {
            Section("iPhone access") {
                Text(model.connectionStatus).font(.headline)
                if model.listening {
                    Button("Pair iPhone") { model.openPairing() }.buttonStyle(.borderedProminent)
                } else {
                    Text("Start the server in Settings to pair an iPhone. Local Pi use does not require pairing.")
                    Button("Open network settings") { model.destination = .settings }
                }
                if !model.code.isEmpty {
                    Text("Pairing code · expires in two minutes").font(.caption)
                    Button("Show pairing QR code") { model.panel = "pairingQR" }
                    Button("Copy pairing code") {
                        NSPasteboard.general.prepareForNewContents(with: [.currentHostOnly])
                        NSPasteboard.general.setString(model.code, forType: .string)
                    }
                }
            }
            Section("Paired devices") {
                if model.devices.isEmpty { Text("No paired devices") }
                ForEach(model.devices) { device in
                    DisclosureGroup {
                        Text("Device ID: " + device.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Revoke access", role: .destructive) { revokeID = device.id }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                            Text(model.connectedDevices.contains(device.id) ? "Connected" : "Paired · not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Devices")
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
