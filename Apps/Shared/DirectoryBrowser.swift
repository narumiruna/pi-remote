import PiRemoteCore
import SwiftUI

struct DirectoryBrowser: View {
    var selecting: Bool
    var request: (SessionAction) async throws -> AppResult
    var attach: ((FilePreview) throws -> Void)? = nil
    var selectionTitle = "Start Pi Here"
    var selected: (UUID, String) async throws -> Void
    @State private var directory: UUID?
    @State private var browser = DirectoryBrowserModel()
    @State private var error: String?
    @State private var selectingSession = false
    @State private var pathStartsClipped = false
    private var page: DirectoryPage? { browser.page }
    private var loading: Bool { browser.loading || selectingSession }

    var body: some View {
        VStack(spacing: 0) {
            if let page {
                HStack {
                    Button { directory = page.parent } label: {
                        Label("Parent folder", systemImage: "arrow.up").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }.disabled(page.parent == nil || loading)
                    HStack(spacing: 0) {
                        Text("…").font(.caption.monospaced()).opacity(pathStartsClipped ? 1 : 0).accessibilityHidden(true)
                        ScrollView(.horizontal) {
                            Text(page.path).font(.caption.monospaced()).fixedSize()
                                .accessibilityHint("Mac folder path. Scroll horizontally to read the full path.")
                        }.defaultScrollAnchor(.trailing).id(page.id)
                            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x + $0.contentInsets.leading > 1 } action: { _, clipped in
                                pathStartsClipped = clipped
                            }
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal)
            }
            if let error = error ?? browser.fault?.explanation { Text(error).foregroundStyle(.primary).padding() }
            List {
                if loading { ProgressView("Loading folders") }
                if !loading, let page {
                    if page.items.isEmpty { Text("This folder is empty.").foregroundStyle(.primary.opacity(0.75)) }
                    else if selecting, !page.items.contains(where: { $0.isDirectory || $0.fault != nil }) {
                        Text("No subfolders on this page.").foregroundStyle(.primary.opacity(0.75))
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
                            Text(fault.explanation).font(.caption).foregroundStyle(.primary.opacity(0.75))
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
                Button {
                    if let page {
                        Task {
                            selectingSession = true
                            defer { selectingSession = false }
                            do { try await selected(page.id, page.path) }
                            catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                        }
                    }
                } label: { Text(selectionTitle).frame(minHeight: 44) }
                    .buttonStyle(.borderedProminent).foregroundStyle(.background).padding()
                    .disabled(loading || page == nil)
            }
        }
        .navigationTitle(selecting ? "Choose a Mac folder" : "Mac files")
        .task(id: directory) { error = nil; await browser.open(directory, request: request) }
        .sheet(isPresented: Binding(get: { browser.preview != nil }, set: { if !$0 { browser.preview = nil } })) {
            if let preview = browser.preview { FilePreviewView(preview: preview, request: request, attach: attach) }
        }
    }
}

struct FilePreviewView: View {
    let preview: FilePreview
    var request: ((SessionAction) async throws -> AppResult)? = nil
    var attach: ((FilePreview) throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading) {
                    if preview.truncated { Text("Preview truncated at the display limit.").foregroundStyle(.primary.opacity(0.75)) }
                    if let images = preview.images { OutputImageList(images: images, request: request) }
                    Text(preview.text.isEmpty ? "No changes or content." : preview.text)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.padding()
            }
            .navigationTitle(preview.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                VStack {
                    if let error { Text(error).font(.callout).padding(.horizontal) }
                    HStack {
                        if let attach {
                            Button {
                                do { try attach(preview); dismiss() }
                                catch {
                                    self.error = error as? RemoteFault == .tooLarge
                                        ? "This attachment does not fit the 256 KiB prompt budget. Shorten the draft or copy a smaller selection."
                                        : (error as? RemoteFault ?? .unavailable).explanation
                                }
                            } label: { Text(preview.truncated ? "Attach shown text" : "Attach text").frame(maxWidth: .infinity, minHeight: 44) }
                                .buttonStyle(.borderedProminent).foregroundStyle(.background)
                        }
                        Button { dismiss() } label: { Text("Done").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.bordered)
                    }.padding()
                }.background(.background)
            }
        }
    }
}

struct ExtensionDialogView: View {
    let dialog: ExtensionDialog
    let answer: (String?, Bool?, Bool) -> Void
    @State private var value = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !dialog.message.isEmpty { Text(dialog.message) }
                switch dialog.method {
                case "select":
                    ForEach(dialog.options, id: \.self) { option in
                        Button { answer(option, nil, false) } label: {
                            Text(option).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                case "input", "editor":
                    TextEditor(text: $value).frame(height: 160).accessibilityLabel("Dialog text")
                case "confirm": EmptyView()
                default: Text("This dialog cannot be displayed safely. Cancel it on this device.")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if dialog.method == "confirm" {
                    Button { answer(nil, true, false) } label: { Text("Confirm").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.background)
                } else if dialog.method == "input" || dialog.method == "editor" {
                    Button { answer(value, nil, false) } label: { Text("Submit").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.background)
                }
                Button(role: .cancel) { answer(nil, nil, true) } label: { Text("Cancel").frame(minHeight: 44) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.bar)
        }
        .navigationTitle(dialog.title)
        .onAppear { value = dialog.text }.interactiveDismissDisabled()
    }
}
