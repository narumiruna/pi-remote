import PiRemoteCore
import SwiftUI

struct RuntimeSettingsView: View {
    let request: (SessionAction) async throws -> AppResult
    @State private var settings: RuntimeSettings?
    @State private var pending: SessionAction?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Text("Changes update Pi settings on the Mac and may affect future terminal sessions. Apply only while idle.").font(.caption)
            if let error { Text(error) }
            if let settings {
                Picker("Steering delivery", selection: Binding(get: { settings.steeringMode }, set: { pending = .queueMode(kind: .steering, mode: $0) })) { modes }.pickerStyle(.menu)
                Picker("Follow-up delivery", selection: Binding(get: { settings.followUpMode }, set: { pending = .queueMode(kind: .followUp, mode: $0) })) { modes }.pickerStyle(.menu)
                Toggle("Automatic compaction", isOn: Binding(get: { settings.autoCompactionEnabled }, set: { pending = .autoCompaction(enabled: $0) }))
            }
            if busy { ProgressView("Updating settings") }
            Button("Refresh settings") { Task { await load() } }.frame(minHeight: 44)
        }
        .disabled(busy)
        .navigationTitle("Pi runtime settings")
        .task { await load() }
        .alert("Update Pi settings on the Mac?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let action = pending {
                Button("Apply") { pending = nil; Task { await apply(action) } }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("This can change settings used by future terminal sessions. Cancelling makes no change.") }
    }

    private var modes: some View {
        Group {
            Text("All queued messages").tag(QueueMode.all)
            Text("One at a time").tag(QueueMode.oneAtATime)
        }
    }
    @MainActor private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await refresh() }
        catch { if !Task.isCancelled { self.error = (error as? RemoteFault ?? .unavailable).explanation } }
    }
    @MainActor private func refresh() async throws {
        guard case .runtimeSettings(let value) = try await request(.runtimeSettings) else { throw RemoteFault.incompatiblePi }
        try Task.checkCancellation()
        settings = value
    }
    @MainActor private func apply(_ action: SessionAction) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { _ = try await request(action); try await refresh() }
        catch {
            if !Task.isCancelled {
                self.error = error as? RemoteFault == .conflict
                    ? "Pi did not confirm the change. Refresh settings and check project overrides on the Mac."
                    : (error as? RemoteFault ?? .unavailable).explanation
            }
        }
    }
}
