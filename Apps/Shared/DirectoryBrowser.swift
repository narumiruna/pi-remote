import PiRemoteCore
import SwiftUI

struct DirectoryBrowser: View {
    var selecting: Bool
    var request: (SessionAction) async throws -> AppResult
    var selected: (UUID) async throws -> Void
    @State private var directory: UUID?
    @State private var page: DirectoryPage?
    @State private var error: String?
    @State private var loading = false
    @State private var preview: FilePreview?

    var body: some View {
        VStack(spacing: 0) {
            if let page {
                HStack {
                    Button("Parent folder", systemImage: "arrow.up") { directory = page.parent }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(page.parent == nil || loading)
                    Text(page.path).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal)
            }
            if let error { Text(error).foregroundStyle(.red).padding() }
            List {
                if loading { ProgressView("Loading folders") }
                if !loading, let page {
                    if page.items.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
                    else if selecting, !page.items.contains(where: { $0.isDirectory || $0.fault != nil }) {
                        Text("No subfolders on this page.").foregroundStyle(.secondary)
                    }
                }
                if error != nil { Button("Retry") { Task { await load(cursor: nil) } }.disabled(loading) }
                ForEach(Array((page?.items ?? []).enumerated()), id: \.offset) { _, item in
                    if let fault = item.fault {
                        VStack(alignment: .leading) {
                            Label(item.name, systemImage: "exclamationmark.triangle")
                            Text(fault.explanation).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    } else if item.isDirectory {
                        Button { directory = item.id } label: { Label(item.name, systemImage: "folder") }
                            .frame(minHeight: 44)
                    } else if !selecting {
                        Button { Task { await open(item.id) } } label: { Label(item.name, systemImage: "doc") }
                            .frame(minHeight: 44)
                    }
                }
                if let next = page?.next { Button("Load more") { Task { await load(cursor: next) } }.disabled(loading) }
            }
            if selecting {
                Button("Start Pi Here") {
                    if let id = page?.id {
                        Task {
                            loading = true
                            defer { loading = false }
                            do { try await selected(id) }
                            catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                        }
                    }
                }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44).padding()
                    .disabled(loading || page == nil)
            }
        }
        .navigationTitle(selecting ? "Choose a Mac folder" : "Mac files")
        .task(id: directory) { await load(cursor: nil) }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview { FilePreviewView(preview: preview) }
        }
    }

    @MainActor private func load(cursor: UUID?) async {
        loading = true; error = nil
        if cursor == nil { page = nil }
        let intended = directory
        defer { loading = false }
        do {
            guard case .directories(var value) = try await request(.directories(id: directory, cursor: cursor)), intended == directory else { return }
            if cursor != nil, let old = page { value.items = old.items + value.items }
            page = value
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
    @MainActor private func open(_ id: UUID) async {
        do { if case .preview(let value) = try await request(.preview(id: id)) { preview = value } }
        catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}

struct FilePreviewView: View {
    let preview: FilePreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading) {
                    if preview.truncated { Text("Preview truncated at the display limit.").foregroundStyle(.secondary) }
                    Text(preview.text.isEmpty ? "No changes or content." : preview.text)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.padding()
            }
            .navigationTitle(preview.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ExtensionDialogView: View {
    let dialog: ExtensionDialog
    let answer: (String?, Bool?, Bool) -> Void
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dialog.title).font(.headline)
            if !dialog.message.isEmpty { Text(dialog.message) }
            switch dialog.method {
            case "select":
                ScrollView { ForEach(dialog.options, id: \.self) { option in Button(option) { answer(option, nil, false) }.frame(minHeight: 44) } }
            case "confirm":
                Button("Confirm") { answer(nil, true, false) }.buttonStyle(.borderedProminent).frame(minHeight: 44)
            case "input", "editor":
                TextEditor(text: $value).frame(minHeight: 120)
                Button("Submit") { answer(value, nil, false) }.buttonStyle(.borderedProminent).frame(minHeight: 44)
            default: Text("This dialog cannot be displayed safely. Cancel it on this device.")
            }
            Button("Cancel", role: .cancel) { answer(nil, nil, true) }.frame(minHeight: 44)
        }
        .padding(24).onAppear { value = dialog.text }
        .interactiveDismissDisabled()
    }
}
