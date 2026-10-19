import PiRemoteCore
import SwiftUI

#if os(iOS)
private let directoryControlMinimum: CGFloat? = 44
#else
private let directoryControlMinimum: CGFloat? = nil
#endif

#if os(macOS)
private let directoryHostTerm = "Mac"
#else
private let directoryHostTerm = "host"
#endif

struct DirectoryBrowser: View {
    var selecting: Bool
    var request: (SessionAction) async throws -> AppResult
    var attach: ((FilePreview) throws -> Void)? = nil
    var selectionTitle = "Start Pi Here"
    var pathEntry = false
    var initialPath: String? = nil
    var relativeTo: String? = nil
    var reveal: ((UUID, Bool) -> Void)? = nil
    var selected: (UUID, String) async throws -> Void
    @Environment(\.clipboardWriter) private var copy
    @State private var typedPath = ""
    @FocusState private var editingPath: Bool
    @State private var browser = DirectoryBrowserModel()
    @State private var error: String?
    @State private var selectingSession = false
    @State private var pathStartsClipped = false
    @State private var showingPathEditor = false
    #if os(macOS)
    @State private var showsHiddenFiles = false
    @State private var showsFullPath = false
    @State private var highlightedItem: String?
    #endif
    private var showsPathEditor: Bool {
        #if os(macOS)
        pathEntry && showingPathEditor
        #else
        pathEntry
        #endif
    }
    private var page: DirectoryPage? { browser.page }
    private var loading: Bool { browser.loading || selectingSession }
    private var visibleItems: [DirectoryItem] {
        let items = page?.items ?? []
        #if os(macOS)
        // Keep access errors visible, including errors for hidden entries.
        if !selecting && !showsHiddenFiles {
            return items.filter { !$0.name.hasPrefix(".") || $0.fault != nil }
        }
        #endif
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            folderNavigation
            #endif
            if showsPathEditor {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField(directoryHostTerm.capitalized + " folder path", text: $typedPath, prompt: Text("~/src/project"))
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                            .autocorrectionDisabled().focused($editingPath)
                            .accessibilityIdentifier("mac-folder-path")
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.go)
                            #endif
                            .onSubmit { openPath() }
                        Button(action: openPath) { Text("Go").frame(minWidth: directoryControlMinimum, minHeight: directoryControlMinimum) }
                            .disabled(loading || typedPath.isEmpty || typedPath.utf8.count > 4_096)
                            .accessibilityIdentifier("mac-folder-go")
                            .accessibilityHint("Open this folder without starting Pi. Review the resolved path before selecting it.")
                    }
                    Text("Absolute " + directoryHostTerm + " path or ~/folder")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if typedPath.utf8.count > 4_096 {
                        Text("The path exceeds the 4 KiB limit.").font(.caption)
                    }
                }.padding(.horizontal).padding(.top, 8)
            }
            #if os(iOS)
            if let page {
                HStack {
                    Button { openDirectory(page.parent) } label: {
                        Label("Parent folder", systemImage: "arrow.up").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }.disabled(page.parent == nil || loading)
                        .accessibilityIdentifier("mac-folder-parent")
                    HStack(spacing: 0) {
                        Text("…").font(.caption.monospaced()).opacity(pathStartsClipped ? 1 : 0).accessibilityHidden(true)
                        ScrollView(.horizontal) {
                            Text(page.path).font(.caption.monospaced()).fixedSize()
                                .accessibilityHint(directoryHostTerm.capitalized + " folder path. Scroll horizontally to read the full path.")
                        }.defaultScrollAnchor(.trailing).id(page.id)
                            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x + $0.contentInsets.leading > 1 } action: { _, clipped in
                                pathStartsClipped = clipped
                            }
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal)
            }
            #endif
            #if os(macOS)
            List(selection: $highlightedItem) { directoryContents }
                .buttonStyle(.plain)
                .listStyle(.inset)
                // New pages and filters start at the top, including hidden-only pages.
                .id(visibleItems.map(\.name))
                .disabled(loading)
                .onKeyPress(.return) {
                    guard !loading, let item = visibleItems.first(where: { $0.name == highlightedItem }),
                          item.fault == nil, item.isDirectory || !selecting else { return .ignored }
                    openItem(item)
                    return .handled
                }
            #else
            List { directoryContents }
                .disabled(loading)
            #endif
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
                } label: { Text(selectionTitle).frame(minHeight: directoryControlMinimum) }
                    .buttonStyle(.borderedProminent).foregroundStyle(.background).padding()
                    .disabled(loading || page == nil || (pathEntry && typedPath != page?.path))
                    .accessibilityIdentifier("mac-folder-select")
            }
        }
        .navigationTitle(selecting ? "Choose a " + directoryHostTerm + " folder" : directoryHostTerm.capitalized + " files")
        .task {
            if let initialPath { await browser.open(path: initialPath, request: request) }
            else { await browser.open(nil, request: request) }
        }
        .onChange(of: page?.path) { _, value in
            if let value { typedPath = value }
            #if os(macOS)
            highlightedItem = nil
            #endif
        }
        .sheet(isPresented: Binding(get: { browser.preview != nil }, set: { if !$0 { browser.preview = nil } })) {
            if let preview = browser.preview { FilePreviewView(preview: preview, request: request, attach: attach) }
        }
    }

    @ViewBuilder
    private var directoryContents: some View {
        if let error = error ?? browser.fault?.explanation {
            Text(error).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("folder-error")
        }
        if loading { ProgressView("Loading folders") }
        if !loading, let page {
            if page.items.isEmpty { Text("This folder is empty.").foregroundStyle(.primary.opacity(0.75)) }
            else if visibleItems.isEmpty {
                Text("No visible files or folders on this page. Show hidden files in More actions.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac-folder-filtered-empty")
            } else if selecting, !page.items.contains(where: { $0.isDirectory || $0.fault != nil }) {
                Text("No subfolders on this page.").foregroundStyle(.primary.opacity(0.75))
            }
        }
        if error != nil || browser.fault != nil {
            Button("Retry") { Task { error = nil; await browser.retry(request: request) } }.disabled(loading)
                .accessibilityIdentifier("mac-folder-retry")
        }
        if !browser.previousPages.isEmpty {
            Button("Previous page") { browser.previous() }.frame(minHeight: directoryControlMinimum).disabled(loading)
                .accessibilityIdentifier("mac-folder-previous-page")
        }
        ForEach(visibleItems, id: \.name) { item in
            Group {
                if let fault = item.fault {
                    VStack(alignment: .leading) {
                        Label(item.name, systemImage: "exclamationmark.triangle")
                        Text(fault.explanation).font(.caption).foregroundStyle(.primary.opacity(0.75))
                    }.frame(minHeight: directoryControlMinimum)
                } else if item.isDirectory {
                    Button { openItem(item) } label: { itemLabel(item, systemImage: "folder") }
                        .frame(minHeight: directoryControlMinimum)
                        .accessibilityIdentifier("mac-folder-row-\(item.id)")
                } else if !selecting {
                    Button { openItem(item) } label: { itemLabel(item, systemImage: "doc") }
                        .frame(minHeight: directoryControlMinimum)
                        .accessibilityIdentifier("mac-file-row-\(item.id)")
                }
            }
            .tag(item.name)
            .contextMenu {
                if item.fault == nil, let page {
                    let full = URL(fileURLWithPath: page.path).appendingPathComponent(item.name).path
                    let prefix = relativeTo.map { $0 == "/" ? "/" : $0 + "/" }
                    let relative = prefix.flatMap { full.hasPrefix($0) ? String(full.dropFirst($0.count)) : nil }
                    Button(relative == nil ? "Copy path" : "Copy relative path") {
                        do { try copy(relative ?? full) }
                        catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                    }
                    if let reveal { Button("Show in Finder") { reveal(item.id, item.isDirectory) } }
                }
            }
        }
        if page?.next != nil {
            Button("Next page") { Task { await browser.next(request: request) } }.frame(minHeight: directoryControlMinimum).disabled(loading)
                .accessibilityIdentifier("mac-folder-next-page")
        }
    }

    private func openItem(_ item: DirectoryItem) {
        if item.isDirectory { openDirectory(item.id) }
        else {
            #if os(macOS)
            highlightedItem = item.name
            #endif
            Task { await browser.openPreview(item.id, request: request) }
        }
    }

    private func itemLabel(_ item: DirectoryItem, systemImage: String) -> some View {
        #if os(macOS)
        Label(item.name, systemImage: systemImage)
            .lineLimit(1).truncationMode(.middle)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        #else
        Label(item.name, systemImage: systemImage)
        #endif
    }

    #if os(macOS)
    private var folderNavigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page {
                if selecting {
                    HStack {
                        parentButton(page)
                        breadcrumb(page)
                    }
                    HStack {
                        copyPathButton(page.path)
                        editPathButton
                    }
                    Text("Resolved " + directoryHostTerm + " folder").font(.caption).foregroundStyle(.secondary)
                    canonicalPath(page.path)
                } else {
                    HStack(spacing: 6) {
                        parentButton(page)
                        breadcrumb(page)
                        editPathButton.fixedSize()
                        Menu {
                            copyPathButton(page.path)
                            Toggle("Show hidden files", isOn: $showsHiddenFiles)
                                .accessibilityIdentifier("mac-folder-show-hidden")
                            Toggle("Full path", isOn: $showsFullPath)
                                .accessibilityIdentifier("mac-folder-path-details")
                        } label: {
                            Label("More actions", systemImage: "ellipsis").labelStyle(.iconOnly)
                                .accessibilityLabel("More actions")
                                .accessibilityIdentifier("mac-folder-more-actions")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More actions")
                        .accessibilityLabel("More actions")
                        .accessibilityIdentifier("mac-folder-more-actions")
                    }
                    .controlSize(.small)
                    if showsFullPath { canonicalPath(page.path) }
                }
            } else {
                editPathButton
            }
        }
        .padding(.horizontal).padding(.top, 8)
    }

    private func parentButton(_ page: DirectoryPage) -> some View {
        Button { openDirectory(page.parent) } label: {
            Label("Parent folder", systemImage: "arrow.up").labelStyle(.iconOnly)
        }
        .disabled(page.parent == nil || loading)
        .accessibilityIdentifier("mac-folder-parent")
    }

    private func breadcrumb(_ page: DirectoryPage) -> some View {
        Menu {
            ForEach(ancestorPaths(page.path), id: \.self) { path in
                Button(path) { openResolvedPath(path) }
                    .disabled(!pathEntry || loading)
            }
        } label: {
            Label(page.path == "/" ? "/" : URL(fileURLWithPath: page.path).lastPathComponent,
                  systemImage: "folder")
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Resolved folder")
                .accessibilityValue(page.path)
                .accessibilityIdentifier("mac-folder-breadcrumb")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(loading)
        .accessibilityLabel("Resolved folder")
        .accessibilityValue(page.path)
        .accessibilityIdentifier("mac-folder-breadcrumb")
    }

    private func copyPathButton(_ path: String) -> some View {
        Button("Copy full path") {
            do { try copy(path) }
            catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
        }
        .accessibilityIdentifier("mac-folder-copy-path")
    }

    @ViewBuilder
    private var editPathButton: some View {
        if pathEntry {
            Button {
                showingPathEditor.toggle()
                editingPath = showingPathEditor
            } label: {
                if selecting { Text(showingPathEditor ? "Hide path" : "Edit path") }
                else {
                    Label(showingPathEditor ? "Hide path" : "Edit path", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
            }
            .accessibilityLabel(showingPathEditor ? "Hide path" : "Edit path")
            .disabled(loading || (showingPathEditor && typedPath != page?.path))
            .help("Edit the folder path. Resolve an edited path with Go before hiding it.")
            .accessibilityIdentifier("mac-folder-edit-path")
        }
    }

    private func canonicalPath(_ path: String) -> some View {
        ScrollView(.horizontal) {
            Text(path).font(.caption.monospaced()).textSelection(.enabled).fixedSize()
                .accessibilityIdentifier("mac-folder-canonical-path")
                .accessibilityHint("Scroll horizontally to read the full canonical path.")
        }
        .frame(height: 24)
    }

    private func ancestorPaths(_ path: String) -> [String] {
        var paths = [path]
        var current = path
        while current != "/" {
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
            guard parent != current, !parent.isEmpty else { break }
            paths.append(parent)
            current = parent
        }
        return Array(paths.reversed())
    }

    private func openResolvedPath(_ path: String) {
        guard !loading, pathEntry else { return }
        editingPath = false; error = nil
        Task { await browser.open(path: path, request: request) }
    }
    #endif

    private func openDirectory(_ id: UUID?) {
        guard !loading else { return }
        editingPath = false; error = nil
        Task { await browser.open(id, request: request) }
    }

    private func openPath() {
        guard !loading, !typedPath.isEmpty, typedPath.utf8.count <= 4_096 else { return }
        editingPath = false; error = nil
        let path = typedPath
        Task { await browser.open(path: path, request: request) }
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
                            } label: { Text(preview.truncated ? "Attach shown text" : "Attach text").frame(maxWidth: .infinity, minHeight: directoryControlMinimum) }
                                .buttonStyle(.borderedProminent).foregroundStyle(.background)
                                .accessibilityIdentifier("file-preview-attach")
                        }
                        Button { dismiss() } label: { Text("Done").frame(minWidth: directoryControlMinimum, minHeight: directoryControlMinimum) }.buttonStyle(.bordered)
                            .accessibilityIdentifier("file-preview-done")
                    }.padding()
                }.background(.background)
            }
        }
    }
}

struct ExtensionDialogView: View {
    let dialog: ExtensionDialog
    var available = true
    var sending = false
    var fault: RemoteFault? = nil
    var connecting = false
    var close: (() -> Void)? = nil
    var reconnect: (() -> Void)? = nil
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
                            Text(option).frame(maxWidth: .infinity, minHeight: directoryControlMinimum, alignment: .leading)
                        }
                        .accessibilityIdentifier("extension-dialog-option-\(option)")
                        .disabled(!available || sending)
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
                if let fault {
                    Label("Answer failed: " + fault.title, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("extension-dialog-error")
                    Text(fault.explanation).font(.caption)
                }
                if !available {
                    Text("Disconnected. The request stays pending on the " + directoryHostTerm + ". Reconnect before answering.").font(.caption)
                    if let reconnect {
                        Button(action: reconnect) { Text(connecting ? "Connecting…" : "Reconnect").frame(minHeight: directoryControlMinimum) }
                            .disabled(connecting).accessibilityIdentifier("extension-dialog-reconnect")
                    }
                }
                if sending { Text("Sending answer…").font(.caption) }
                if dialog.method == "confirm" {
                    Button { answer(nil, true, false) } label: { Text("Confirm").frame(minHeight: directoryControlMinimum) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.background)
                        .accessibilityIdentifier("extension-dialog-confirm")
                        .disabled(!available || sending)
                } else if dialog.method == "input" || dialog.method == "editor" {
                    Button { answer(value, nil, false) } label: { Text("Submit").frame(minHeight: directoryControlMinimum) }
                        .buttonStyle(.borderedProminent).foregroundStyle(.background)
                        .accessibilityIdentifier("extension-dialog-submit")
                        .disabled(!available || sending)
                }
                Button(role: .cancel) { answer(nil, nil, true) } label: { Text("Cancel").frame(minHeight: directoryControlMinimum) }
                    .accessibilityIdentifier("extension-dialog-cancel")
                    .accessibilityHint("Cancel this request on the " + directoryHostTerm + ".")
                    .disabled(!available || sending)
                if let close {
                    Button(action: close) { Text("Close").frame(minHeight: directoryControlMinimum) }
                        .accessibilityHint("Close on this iPhone only. This does not answer or cancel the request on the " + directoryHostTerm + ".")
                        .accessibilityIdentifier("extension-dialog-close")
                    Text("Close leaves this request pending on the " + directoryHostTerm + ".").font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.bar)
        }
        .navigationTitle(dialog.title)
        .onAppear { value = dialog.text }.interactiveDismissDisabled()
    }
}
