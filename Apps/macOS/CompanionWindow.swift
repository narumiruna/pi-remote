import AppKit
import PiRemoteCore
import SwiftUI

struct CompanionWindow: View {
    @Bindable var model: CompanionModel
    @SceneStorage("macWorkspaceSidebarVisible") private var sidebarVisible = true
    @SceneStorage("macWorkspaceSidebarWidth") private var sidebarWidth = 240.0
    @SceneStorage("macWorkspaceInspectorWidth") private var inspectorWidth = 320.0
    @State private var section = "Chat"
    @State private var inspectorSection = "Files"
    @State private var removingWorkspace: String?
    @State private var remoteDetailsVisible = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(compact: geometry.size.width < 1100)
                Divider()
                HSplitView {
                    if sidebarVisible {
                        sidebar.frame(minWidth: 210, idealWidth: sidebarWidth, maxWidth: 320)
                            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { value in
                                if value >= 210, value <= 320, abs(sidebarWidth - value) > 1 { sidebarWidth = value }
                            }
                    }
                    VStack(spacing: 0) {
                        notices
                        detail
                    }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    if model.inspectorVisible {
                        inspector.frame(minWidth: 260, idealWidth: min(inspectorWidth, 320), maxWidth: 320)
                            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { value in
                                if value >= 260, value <= 320, abs(inspectorWidth - value) > 1 { inspectorWidth = value }
                            }
                    }
                }
            }
            .background(.white)
            .sheet(isPresented: Binding(get: { model.panel != nil }, set: { if !$0 { model.panel = nil } })) {
                sheet
                    .frame(width: min(600, max(480, geometry.size.width - 32)),
                           height: min(640, max(360, geometry.size.height - 40)))
            }
        }
        .preferredColorScheme(.light)
        .modifier(InterfaceAppearance())
        .modifier(EditorOfferPrompt(offer: $model.editorOffer, replace: model.acceptEditorOffer))
        .confirmationDialog("Send this instruction again?", isPresented: $model.confirmResend) {
            Button("Send again") { model.resend() }
        } message: { Text("The Mac may have accepted the previous action. Sending again can repeat file changes or external actions.") }
        .confirmationDialog("Remove workspace from the sidebar?", isPresented: Binding(
            get: { removingWorkspace != nil }, set: { if !$0 { removingWorkspace = nil } }
        )) {
            Button("Remove workspace", role: .destructive) {
                if let path = removingWorkspace { model.removeWorkspace(path) }
                removingWorkspace = nil
            }
        } message: { Text("This only removes the sidebar entry. Files and saved sessions are not deleted, and Pi work is not stopped.") }
        .onChange(of: model.state.context) { _, _ in
            section = "Chat"
            if model.panel == "commands" { model.panel = nil }
        }
    }

    private func toolbar(compact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Sidebar", systemImage: "sidebar.left") { sidebarVisible.toggle() }
                    .labelStyle(.iconOnly).keyboardShortcut("s", modifiers: [.command, .option])
                Text("Pi Remote for Mac").font(.headline).lineLimit(1)
                Spacer(minLength: 12)
                if !compact { status }
                if let active = model.state.selected, model.destination != .session(active) {
                    Button("Active session") { model.destination = .session(active) }
                }
                if model.state.working { Button("Stop", role: .destructive) { model.stopWork() }.help("Stop active Pi work and clear queued instructions. File changes are not undone.") }
                Button("New session", systemImage: "plus") {
                    if let path = model.selectedWorkspace { Task { await model.createSession(in: path) } }
                    else { model.panel = "directory" }
                }
                .disabled(model.state.working || model.openingSession || model.startupError != nil)
                .keyboardShortcut("n", modifiers: .command)
                Button("Inspector", systemImage: "sidebar.right") { model.inspectorVisible.toggle() }
                    .accessibilityIdentifier("mac-inspector-toggle")
                    .labelStyle(.iconOnly).keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Show or hide Files, Tools and Activity")
            }
            if compact { HStack { status; Spacer() } }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var status: some View {
        HStack(spacing: 16) {
            Button { remoteDetailsVisible.toggle() } label: {
                Label(model.remoteAccessSummary, systemImage: "network")
            }
            .accessibilityIdentifier("mac-remote-access")
            .help("Show listener and authenticated device status")
            .popover(isPresented: $remoteDetailsVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("iPhone access").font(.headline)
                    Text(model.serverStatus).accessibilityIdentifier("mac-remote-server-status")
                    if model.listening { Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled) }
                    Text(model.connectionStatus).accessibilityIdentifier("mac-remote-device-status")
                    Text("Local Pi work does not require remote access.").font(.caption)
                    HStack {
                        Button("Network settings") { remoteDetailsVisible = false; model.destination = .settings }
                        Button("Devices") { remoteDetailsVisible = false; model.destination = .devices }
                    }
                }.padding(16).frame(width: 310)
            }
            if !model.showingLoadedSession {
                Text(model.piStatus).accessibilityIdentifier("mac-session-status")
            }
        }.font(.caption)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.destination }, set: { destination in
            section = "Chat"
            if case .session(let id) = destination { Task { await model.openSession(id) } }
            else { model.destination = destination }
        })) {
            Label("Overview", systemImage: "house").tag(MacDestination.overview)
            Section {
                ForEach(model.workspaces) { workspace in
                    DisclosureGroup(isExpanded: Binding(
                        get: { model.expandedWorkspaces.contains(workspace.id) },
                        set: { model.setExpanded(workspace.id, expanded: $0) }
                    )) {
                        ForEach(workspace.sessions) { session in
                            Group {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: session.id == model.state.selected ? "circle.fill" : "circle")
                                            .font(.system(size: 7)).foregroundStyle(.secondary)
                                        Text(session.title.isEmpty ? String(session.id.uuidString.prefix(8)) : session.title).lineLimit(1)
                                    }
                                    HStack {
                                        Text(session.id == model.state.selected ? model.state.phase.capitalized : (session.interrupted ? "Needs review" : "Saved"))
                                        Spacer()
                                        Text(session.updated, style: .relative)
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }
                            .tag(MacDestination.session(session.id))
                            .accessibilityIdentifier("mac-session-" + session.id.uuidString)
                            .contextMenu {
                                Button("Open session") { Task { await model.openSession(session.id) } }
                                Button("Copy session ID") { model.copy(session.id.uuidString) }
                                if session.id == model.state.selected {
                                    Button("Session controls and rename") { model.destination = .session(session.id); inspectorSection = "Tools"; model.inspectorVisible = true }
                                    Button("History and fork options") { model.destination = .session(session.id); section = "History" }
                                        .disabled(model.state.working)
                                }
                            }
                        }
                        Button("New session", systemImage: "plus") { Task { await model.createSession(in: workspace.directory) } }
                            .disabled(model.state.working || model.openingSession)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.name).lineLimit(1)
                                if model.workspaces.filter({ $0.name == workspace.name }).count > 1 {
                                    Text(URL(fileURLWithPath: workspace.directory).deletingLastPathComponent().path)
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        } icon: { Image(systemName: "folder") }.help(workspace.directory)
                            .accessibilityIdentifier("mac-workspace-" + workspace.directory)
                    }
                    .tag(MacDestination.workspace(workspace.directory))
                    .contextMenu {
                        Button("New session") { Task { await model.createSession(in: workspace.directory) } }
                            .disabled(model.state.working || model.openingSession)
                        Button("Show in Finder") { model.revealWorkspace(workspace.directory) }
                        Button("Copy path") { model.copy(workspace.directory) }
                        Button("Remove workspace…", role: .destructive) { removingWorkspace = workspace.directory }
                    }
                }
                Button("Add workspace", systemImage: "folder.badge.plus") { model.panel = "workspace" }
                    .accessibilityIdentifier("mac-add-workspace")
            } header: { Text("Workspaces") }
            Section("Manage") {
                Button("Import session", systemImage: "square.and.arrow.down") { model.panel = "import" }
                    .disabled(model.state.working || model.openingSession)
                Label("Devices", systemImage: "iphone").tag(MacDestination.devices)
                Label("Settings", systemImage: "gearshape").tag(MacDestination.settings)
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).background(.white)
        .accessibilityIdentifier("mac-workspace-sidebar")
    }

    @ViewBuilder private var notices: some View {
        if let error = model.startupError { Text(error).textSelection(.enabled).padding(12) }
        if let error = model.draftSaveError { Text(error).font(.callout).padding(12) }
        if let fault = model.visibleFault {
            HStack(alignment: .top) {
                Label(fault.explanation, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                Spacer()
                Button(model.needsActionReview ? "Reviewed" : "Dismiss") { model.reviewedFault() }
            }.padding(12).background(.quaternary.opacity(0.4))
        }
        if let pending = model.pending {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow " + pending.device.name + "?").font(.headline)
                Text(pending.device.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                Text("This device can control Pi with your Mac permissions, including file changes and command execution.").font(.caption)
                HStack {
                    Button("Allow") { model.approve(pending.id) }.buttonStyle(.borderedProminent)
                    Button("Deny", role: .cancel) { model.deny(pending.id) }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.destination {
        case .devices: CompanionDevicesView(model: model)
        case .settings: CompanionConnectionSettings(model: model)
        case .workspace(let path): workspaceDetail(path)
        case .session(let id): sessionDetail(id)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your Mac, your Pi sessions").font(.title2.bold())
                    Text("Add a workspace, create a session and talk to Pi here. The server is only needed for iPhone access.").foregroundStyle(.secondary)
                    HStack {
                        Button("Add workspace", systemImage: "folder.badge.plus") { model.panel = "workspace" }.buttonStyle(.borderedProminent)
                        Button("New session") { model.panel = "directory" }.disabled(model.state.working || model.openingSession)
                    }
                    Divider()
                    CompanionServerControls(model: model)
                    Text("\(model.workspaces.count) workspaces · \(model.state.sessions.count) saved sessions").font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 700, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspaceDetail(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder").font(.title2.bold())
            Text(path).font(.callout.monospaced()).textSelection(.enabled)
            Text("Select a session in the sidebar, or start a new conversation in this folder.").foregroundStyle(.secondary)
            HStack {
                Button("New session", systemImage: "plus") { Task { await model.createSession(in: path) } }
                    .buttonStyle(.borderedProminent).disabled(model.state.working || model.openingSession)
                Button("Show in Finder") { model.revealWorkspace(path) }
            }
            if model.state.working { Text("Pi is working in another session. New sessions and activation wait until that work stops.").font(.caption) }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func sessionDetail(_ id: UUID) -> some View {
        if let session = model.state.sessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).font(.headline)
                        Text(session.directory).font(.caption.monospaced()).lineLimit(1).help(session.directory)
                    }
                    Spacer()
                    if id == model.state.selected {
                        VStack(alignment: .trailing) {
                            Text(model.piStatus).font(.caption).accessibilityIdentifier("mac-session-status")
                            if !model.state.model.isEmpty { Text(model.state.model + " · " + model.state.thinking).font(.caption2).foregroundStyle(.secondary) }
                        }
                    } else { Text("Saved · not loaded").font(.caption).foregroundStyle(.secondary) }
                }.padding(16)
                if id == model.state.selected {
                    Picker("Session view", selection: $section) {
                        Text("Chat").tag("Chat")
                        Text("History").tag("History").disabled(model.state.working)
                    }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12)
                    Divider()
                    switch section {
                    case "History": NavigationStack { HistoryView(request: model.scopedRequest(for: model.state), paged: true) { section = "Chat" } }.id(model.state.context)
                    default:
                        if ["unavailable", "interrupted"].contains(model.state.phase) {
                            HStack {
                                Text("Pi is not running. Saved output is retained; no instruction will be resent.").font(.caption)
                                Button("Open session") { Task { await model.openSession(id) } }.disabled(model.openingSession)
                            }.padding(12)
                        }
                        ConversationView(state: model.state, text: $model.text, delivery: $model.delivery, sending: model.sending,
                                         send: { model.send(context: model.state.context) }, stop: { model.stopWork() }, request: model.scopedRequest(for: model.state)) {
                            Button("Files", systemImage: "folder") { inspectorSection = "Files"; model.inspectorVisible = true }
                                .labelStyle(.iconOnly).help("Show files in the inspector").accessibilityIdentifier("mac-composer-files")
                            Button("Commands", systemImage: "slash.circle") { model.panel = "commands" }
                                .labelStyle(.iconOnly).help("Open Pi commands").accessibilityIdentifier("mac-composer-commands")
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle)
                        Text(model.openingSession ? "Opening session…" : "Open the saved conversation").font(.title3)
                        Text(model.state.working ? "Another session is working. Its process will not be interrupted. Stop it before activating this session." : "Pi restores this session from its saved file. Previous messages are not sent again.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Open session") { Task { await model.openSession(id) } }
                            .buttonStyle(.borderedProminent).disabled(model.state.working || model.openingSession)
                        if model.openingSession { ProgressView() }
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView("Session not found", systemImage: "bubble.left", description: Text("Select another saved session or add a workspace."))
        }
    }

    @ViewBuilder private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorSection) {
                Text("Files").tag("Files"); Text("Tools").tag("Tools"); Text("Activity").tag("Activity")
            }.pickerStyle(.segmented).padding(12).accessibilityIdentifier("mac-inspector-sections")
            Divider()
            switch inspectorSection {
            case "Tools":
                if case .session(let id) = model.destination, id == model.state.selected {
                    NavigationStack {
                        SessionControls(state: model.state, request: model.scopedRequest(for: model.state), closed: { model.destination = .overview }) { model.preview = $0; model.panel = "preview" }
                            .formStyle(.grouped)
                    }.id(model.state.context)
                } else { ContentUnavailableView("No loaded session", systemImage: "slider.horizontal.3", description: Text("Open a session to use its Pi controls.")) }
            case "Activity":
                List {
                    Text(model.piStatus).font(.headline)
                    if case .session(let id) = model.destination, id == model.state.selected {
                        ForEach(model.state.messages.filter { $0.role == "tool" }) { message in
                            DisclosureGroup {
                                Text(message.text).font(.caption.monospaced()).textSelection(.enabled)
                            } label: {
                                Label(DisplayLimit.text(message.text.components(separatedBy: "\n").first ?? "Tool", bytes: 128),
                                      systemImage: message.isError ? "exclamationmark.triangle" : (message.streaming ? "clock" : "checkmark.circle"))
                            }
                        }
                        if let error = model.state.error { Text(error.explanation) }
                        ForEach(Array(model.state.notices.enumerated()), id: \.offset) { _, value in Text(value).font(.caption) }
                    } else { Text("Activity is available for the loaded session.").foregroundStyle(.secondary) }
                }
            default:
                if let path = model.selectedWorkspace { files(path: path) }
                else { ContentUnavailableView("Choose a workspace", systemImage: "folder") }
            }
        }.background(.white)
    }

    private func files(path: String) -> some View {
        let state = model.state
        let attach: ((FilePreview) throws -> Void)? = {
            guard case .session(let id) = model.destination, id == state.selected else { return nil }
            return { preview in
                guard model.destination == .session(id) else { throw RemoteFault.conflict }
                try model.attachText(preview, context: state.context)
            }
        }()
        return DirectoryBrowser(selecting: false, request: model.scopedRequest(for: state), attach: attach,
                                pathEntry: true, initialPath: path, relativeTo: path, reveal: model.revealEntry) { _, _ in }
            .id(path + state.context.epoch.uuidString + (state.selected?.uuidString ?? ""))
    }

    private var sheet: some View {
        NavigationStack {
            let state = model.state
            switch model.panel {
            case "workspace":
                DirectoryBrowser(selecting: true, request: model.scopedRequest(for: state), selectionTitle: "Add workspace", pathEntry: true) { _, path in
                    try await model.addWorkspace(path: path); model.panel = nil
                }
            case "directory":
                DirectoryBrowser(selecting: true, request: model.scopedRequest(for: state), pathEntry: true) { id, path in
                    try await model.addWorkspace(path: path)
                    _ = try await model.scopedRequest(for: state)(.createSession(directory: id))
                    if let coordinator = model.coordinator, let selected = await coordinator.state().selected { model.destination = .session(selected) }
                    model.panel = nil
                }
            case "import": SessionImportView(request: model.scopedRequest(for: state), canChooseDirectory: true, canEnterPath: true) {
                model.panel = nil
                if let id = model.state.selected { model.destination = .session(id) }
            }
            case "dialog":
                if let dialog = state.dialogs.first {
                    ExtensionDialogView(dialog: dialog) { value, confirmed, cancelled in
                        Task { _ = try? await model.scopedRequest(for: state)(.answer(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled)) }
                    }.id(dialog.id)
                }
            case "commands": SessionCommandsView(state: state, request: model.scopedRequest(for: state))
            case "pairingQR": PairingQRView(code: model.code)
            case "preview": if let preview = model.preview { FilePreviewView(preview: preview) }
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .toolbar {
            if model.panel == "workspace" || model.panel == "directory" {
                ToolbarItem(placement: .primaryAction) {
                    if model.panel == "directory", !model.workspaces.isEmpty {
                        Menu("Recent workspaces") {
                            ForEach(model.workspaces.sorted {
                                ($0.sessions.first?.updated ?? .distantPast) > ($1.sessions.first?.updated ?? .distantPast)
                            }.prefix(10)) { workspace in
                                Button(workspace.directory) {
                                    Task { if await model.createSession(in: workspace.directory) { model.panel = nil } }
                                }
                            }
                        }.disabled(model.state.working || model.openingSession)
                    }
                    Button("Choose folder…") { model.chooseWorkspace(startSession: model.panel == "directory") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.panel != "dialog" {
                HStack { Spacer(); Button("Close") { model.panel = nil }.keyboardShortcut(.cancelAction) }
                    .padding(.horizontal, 16).background(.bar)
            }
        }
        .id(model.state.context)
    }
}
