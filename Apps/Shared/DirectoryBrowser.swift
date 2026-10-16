import PiRemoteCore
import SwiftUI

struct DirectoryBrowser: View {
    var selecting: Bool
    var request: (SessionAction) async throws -> AppResult
    var selected: (UUID) async throws -> Void
    @State private var directory: UUID?
    @State private var browser = DirectoryBrowserModel()
    @State private var error: String?
    @State private var selectingSession = false
    private var page: DirectoryPage? { browser.page }
    private var loading: Bool { browser.loading || selectingSession }

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
            if let error = error ?? browser.fault?.explanation { Text(error).foregroundStyle(.red).padding() }
            List {
                if loading { ProgressView("Loading folders") }
                if !loading, let page {
                    if page.items.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
                    else if selecting, !page.items.contains(where: { $0.isDirectory || $0.fault != nil }) {
                        Text("No subfolders on this page.").foregroundStyle(.secondary)
                    }
                }
                if error != nil || browser.fault != nil {
                    Button("Retry") { Task { error = nil; await browser.retry(request: request) } }.disabled(loading)
                }
                if !browser.previousPages.isEmpty {
                    Button("Previous page") { browser.previous() }.frame(minHeight: 44).disabled(loading)
                }
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
                        Button { Task { await browser.openPreview(item.id, request: request) } } label: { Label(item.name, systemImage: "doc") }
                            .frame(minHeight: 44)
                    }
                }
                if page?.next != nil {
                    Button("Next page") { Task { await browser.next(request: request) } }.frame(minHeight: 44).disabled(loading)
                }
            }
            .disabled(loading)
            if selecting {
                Button("Start Pi Here") {
                    if let id = page?.id {
                        Task {
                            selectingSession = true
                            defer { selectingSession = false }
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
        .task(id: directory) { error = nil; await browser.open(directory, request: request) }
        .sheet(isPresented: Binding(get: { browser.preview != nil }, set: { if !$0 { browser.preview = nil } })) {
            if let preview = browser.preview { FilePreviewView(preview: preview) }
        }
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
