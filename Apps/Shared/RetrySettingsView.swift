import PiRemoteCore
import SwiftUI

struct RetrySettingsView: View {
    let request: (SessionAction) async throws -> AppResult
    @State private var acknowledgment: Bool?
    @State private var pending: Bool?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Changes update Pi settings on the Mac and may affect future terminal sessions. Apply only while idle.").font(.caption)
                Text("Pi does not report the effective retry setting. Refresh cannot verify it.").font(.caption)
                if let error { Text(error) }
                Text(acknowledgment.map { "Last acknowledged request: " + ($0 ? "enabled" : "disabled") } ?? "No retry setting request acknowledged in this Pi process.")
                    .accessibilityIdentifier("retry-acknowledgment")
                Button("Enable automatic retry") { pending = true }.frame(minHeight: 44)
                Button("Disable automatic retry") { pending = false }.frame(minHeight: 44)
                if busy { ProgressView("Updating retry controls") }
                Button("Refresh settings") { Task { await load() } }.frame(minHeight: 44)
            }.frame(maxWidth: .infinity, alignment: .leading).padding().padding(.bottom, 44)
        }
        .disabled(busy)
        .navigationTitle("Automatic retry")
        .task { await load() }
        .alert("Update Pi settings on the Mac?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let enabled = pending {
                Button("Apply") { pending = nil; Task { await load(applying: enabled) } }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("This can change settings used by future terminal sessions. Cancelling makes no change. Acknowledgement is not read-back verification.") }
    }

    @MainActor private func load(applying enabled: Bool? = nil) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if let enabled { _ = try await request(.autoRetry(enabled: enabled)) }
            guard case .runtimeSettings(let value) = try await request(.runtimeSettings) else { throw RemoteFault.incompatiblePi }
            try Task.checkCancellation()
            acknowledgment = value.acknowledgedAutoRetry
        } catch { if !Task.isCancelled { self.error = (error as? RemoteFault ?? .unavailable).explanation } }
    }
}
