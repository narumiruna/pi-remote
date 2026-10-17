import PiRemoteCore
import SwiftUI

/// Read-only inspection. Fork is a separate explicit action revalidated by the host.
struct SessionTreeView: View {
    let request: (SessionAction) async throws -> AppResult
    let forked: () -> Void
    @State private var page = SessionTreePage(items: [], leafID: nil, next: nil)
    @State private var earlier: [SessionTreePage] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var preview: FilePreview?

    var body: some View {
        List {
            Section {
                Text("Read-only tree inspection. Fork options come from Pi and can include abandoned branches. Empty-text and image-only messages are not fork options.")
                    .font(.caption)
                Text(loaded ? (page.leafID.map { "Active leaf in snapshot: " + $0 } ?? "No active leaf in snapshot") : "Active leaf not loaded")
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("session-tree-leaf")
                if let error { Text(error).accessibilityIdentifier("session-tree-error") }
                if loading { ProgressView("Loading session tree") }
                Button("Reload tree") { Task { earlier = []; await load(nil) } }
                    .frame(minHeight: 44).disabled(loading)
                if !earlier.isEmpty {
                    Button("Previous tree page") { page = earlier.removeLast() }
                        .frame(minHeight: 44).disabled(loading)
                }
            }
            ForEach(page.items) { item in
                Section {
                    let node = item.node
                    Text(node.kind + " · " + node.id).font(.caption.monospaced()).textSelection(.enabled)
                    if node.id == page.leafID { Text("Active leaf").font(.headline) }
                    Text(node.parentID.map { "Parent: " + $0 } ?? "Root entry")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let label = node.label {
                        Text("Label: " + label).textSelection(.enabled)
                        if let timestamp = node.labelTimestamp {
                            Text("Label timestamp: " + timestamp).font(.caption.monospaced()).textSelection(.enabled)
                        } else { Text("Label timestamp unavailable").font(.caption) }
                    }
                    if !node.text.isEmpty { Text(node.text).textSelection(.enabled) }
                    if node.truncated { Text("Text preview is partial. Read the entry for more.").font(.caption) }
                    if let token = item.preview {
                        Button("Read entry") { Task { await read(token) } }
                            .frame(minHeight: 44).disabled(loading)
                    }
                    if node.canFork {
                        Button("Fork from this message") { Task { await fork(node.id) } }
                            .frame(minHeight: 44).disabled(loading)
                    }
                }
            }
            if let next = page.next {
                Button("Next tree page") { Task { await load(next) } }
                    .frame(minHeight: 44).disabled(loading)
            }
        }
        .navigationTitle("Session tree")
        .task { await load(nil) }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview { FilePreviewView(preview: preview, request: request) }
        }
    }

    @MainActor private func load(_ cursor: UUID?) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard case .sessionTree(let value) = try await request(.sessionTree(cursor: cursor)) else {
                throw RemoteFault.incompatiblePi
            }
            if cursor != nil { earlier.append(page); earlier = Array(earlier.suffix(8)) }
            page = value; loaded = true
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }

    @MainActor private func read(_ token: UUID) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard case .preview(let value) = try await request(.historyEntry(id: token)) else { throw RemoteFault.incompatiblePi }
            preview = value
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }

    @MainActor private func fork(_ id: String) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { _ = try await request(.fork(entry: id)); forked() }
        catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
