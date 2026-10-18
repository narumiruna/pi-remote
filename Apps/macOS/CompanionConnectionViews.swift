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
                    Button("Stop iPhone access") { model.stopNetwork() }
                } else {
                    Button(model.starting ? "Please wait…" : "Start iPhone access") { model.startNetwork() }.buttonStyle(.borderedProminent)
                    Button("iPhone access settings") { model.destination = .settings }
                }
            }.disabled(model.starting || model.startupError != nil || (!model.listening && model.address.isEmpty))
            Text("iPhone access is optional. Local Pi sessions work without it.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CompanionConnectionSettings: View {
    @Bindable var model: CompanionModel
    let openSessionControls: () -> Void
    @State private var advanced = false
    @State private var resetIdentity = false

    var body: some View {
        Form {
            Section("Pi and folder access") {
                LabeledContent("Pi version", value: model.state.piVersion == "Not running" ? "Not checked" : model.state.piVersion)
                    .background(MacDebugPageScrollMarker())
                if model.state.capabilities.contains("pi-release-notes") {
                    Button("Pi changelog") { model.panel = "changelog" }
                        .accessibilityIdentifier("mac-settings-pi-changelog")
                }
                LabeledContent("Pi executable") {
                    Text(model.piPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Choose Pi executable") { model.chooseExecutable() }.disabled(!model.canChooseExecutable)
                    .accessibilityIdentifier("mac-choose-pi-executable")
                Text(model.executableChangeGuidance).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac-executable-guidance")
                if let error = model.executableSelectionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("mac-executable-selection-error")
                }
                if model.executableSessionLoaded, model.state.selected != nil {
                    Button("Loaded session controls", action: openSessionControls)
                        .accessibilityIdentifier("mac-executable-session-controls")
                }
                Button("Folder access") { model.grantFolderAccess() }
                Text("Pi runs with your Mac permissions. Workspaces organize sessions; they are not a sandbox for Pi tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iPhone access (optional)") {
                Text(model.serverStatus).accessibilityIdentifier("mac-settings-access-status")
                Button("Devices") { model.destination = .devices }
                    .accessibilityIdentifier("mac-settings-devices")
                if model.addresses.isEmpty {
                    Text("No local address is available. Connect to a private network or Tailscale, then refresh addresses.")
                        .accessibilityIdentifier("mac-settings-no-address")
                } else {
                    Picker("Listen address", selection: $model.address) {
                        ForEach(model.addresses) { Text($0.address + " · " + $0.name).tag($0.address) }
                    }.disabled(model.listening || model.starting)
                }
                Button("Refresh addresses") { model.refreshListenAddresses() }
                    .disabled(model.listening || model.starting)
                    .accessibilityIdentifier("mac-refresh-addresses")
                if model.listening { Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled) }
                Button(model.listening ? "Stop iPhone access" : "Start iPhone access") {
                    if model.listening { model.stopNetwork() } else { model.startNetwork() }
                }.disabled(model.starting || model.startupError != nil || (!model.listening && model.address.isEmpty))
                    .accessibilityIdentifier("mac-settings-access-toggle")
                Text("Local Pi sessions do not require iPhone access. Stopping access disconnects phones but does not stop Pi work.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Refreshing addresses keeps paired devices and the connection identity. Stop iPhone access before changing its address. Certificate checks still apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MacDebugSettings(model: model)
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Text("Replacing the connection identity revokes every paired device. All phones must pair again. Pi and saved sessions remain on this Mac.")
                        .font(.caption)
                    Button("Replace connection identity", role: .destructive) { resetIdentity = true }.disabled(model.starting)
                }
            }
        }.formStyle(.grouped).navigationTitle("Settings")
        .onAppear { model.refreshListenAddresses() }
        .confirmationDialog("Replace this Mac's connection identity?", isPresented: $resetIdentity) {
            Button("Revoke devices and replace identity", role: .destructive) { model.resetIdentity() }
        } message: { Text("All phones must pair again. Pi and saved sessions will remain on this Mac.") }
    }
}

enum MacDeviceIdentity {
    static func label(for device: PairedDevice, in devices: [PairedDevice]) -> String {
        guard devices.contains(where: { $0.id != device.id && $0.name == device.name }) else { return device.name }
        return device.name + " · " + device.id.uuidString
    }
}

struct MacDeviceRevocationConsent {
    private(set) var device: PairedDevice?

    init(_ device: PairedDevice? = nil) { self.device = device }

    mutating func cancel() { device = nil }

    static func message(for device: PairedDevice) -> String {
        "Revoke access for \(device.name) (Device ID: \(device.id.uuidString))? This device will be disconnected and must pair again before it can control Pi. Pi work will continue on this Mac."
    }

    @MainActor mutating func confirm(in model: CompanionModel) {
        let captured = device
        cancel()
        guard let captured, model.devices.contains(captured) else { return }
        model.revoke(captured.id)
    }
}

struct CompanionDevicesView: View {
    @Bindable var model: CompanionModel
    @State private var revocation = MacDeviceRevocationConsent()

    var body: some View {
        Form {
            Section("iPhone access") {
                Text(model.connectionStatus).font(.headline).background(MacDebugPageScrollMarker())
                if model.listening {
                    Button("Pair iPhone") { model.openPairing() }.buttonStyle(.borderedProminent)
                } else {
                    Text("Start iPhone access in Settings to pair an iPhone. Local Pi use does not require pairing.")
                    Button("iPhone access settings") { model.destination = .settings }
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
                        Button("Revoke access", role: .destructive) { revocation = MacDeviceRevocationConsent(device) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MacDeviceIdentity.label(for: device, in: model.devices))
                            Text(model.connectedDevices.contains(device.id) ? "Connected" : "Paired · not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Devices")
        .confirmationDialog("Revoke device access?", isPresented: Binding(
            get: { revocation.device != nil }, set: { if !$0 { revocation.cancel() } }
        ), titleVisibility: .visible, presenting: revocation.device) { device in
            Button("Revoke access", role: .destructive) {
                // Use the displayed snapshot even if dismissal clears the pending state first.
                var captured = MacDeviceRevocationConsent(device)
                captured.confirm(in: model)
                revocation.cancel()
            }.disabled(!model.devices.contains(device))
            Button("Cancel", role: .cancel) { revocation.cancel() }
        } message: { device in Text(MacDeviceRevocationConsent.message(for: device)) }
    }
}
