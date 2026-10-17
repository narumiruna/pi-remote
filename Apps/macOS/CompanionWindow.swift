import AppKit
import PiRemoteCore
import SwiftUI

struct CompanionWindow: View {
    @Bindable var model: CompanionModel
    @SceneStorage("macWorkspaceSidebarVisible") private var sidebarVisible = true
    @SceneStorage("macWorkspaceSidebarWidth") private var sidebarWidth = 240.0
    @SceneStorage("macWorkspaceInspectorWidth") private var inspectorWidth = 320.0
    @State private var inspectorSection = "Files"
    @State private var removingWorkspace: String?
    @State private var remoteDetailsVisible = false
    @State private var renamingSession: UUID?

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
            if let panel = model.panel, ["commands", "rename", "resume", "tree", "history"].contains(panel) { model.panel = nil }
            renamingSession = nil
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 12) {
                Button("Sidebar", systemImage: "sidebar.left") { sidebarVisible.toggle() }
                    .labelStyle(.iconOnly).keyboardShortcut("s", modifiers: [.command, .option])
                if !compact { Text("Pi Remote for Mac").font(.headline).lineLimit(1) }
                Spacer(minLength: 8)
                status
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
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var status: some View {
        HStack(spacing: 16) {
            Button { remoteDetailsVisible.toggle() } label: {
                Label(model.listening ? "iPhone access on" : (model.starting ? "iPhone access updating" : "iPhone access off"), systemImage: "iphone")
            }
            .accessibilityIdentifier("mac-remote-access")
            .help("Show listener and authenticated device status")
            .popover(isPresented: $remoteDetailsVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("iPhone access").font(.headline)
                    Text(model.serverStatus).accessibilityIdentifier("mac-remote-server-status")
                    if model.listening { Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled) }
                    Text(model.connectionStatus).accessibilityIdentifier("mac-remote-device-status")
                    Text("Remote access is optional. It only controls iPhone connections; local Pi sessions work without it.").font(.caption)
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

    private var sidebarSelection: Binding<MacDestination?> {
        Binding(get: { model.destination }, set: { destination in
            if case .session(let id) = destination { Task { await model.openSession(id) } }
            else { model.destination = destination }
        })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Label("Overview", systemImage: "house").tag(MacDestination.overview)
                Section {
                    ForEach(model.workspaces) { workspace in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expandedWorkspaces.contains(workspace.id) },
                            set: { model.setExpanded(workspace.id, expanded: $0) }
                        )) {
                            ForEach(workspace.sessions) { session in
                                sessionRow(session)
                                    .tag(MacDestination.session(session.id))
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name).fontWeight(.medium).lineLimit(1)
                                    if model.workspaces.filter({ $0.name == workspace.name }).count > 1 {
                                        Text(URL(fileURLWithPath: workspace.directory).deletingLastPathComponent().path)
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            } icon: { Image(systemName: "folder") }
                                .help(workspace.directory)
                                .accessibilityIdentifier("mac-workspace-" + workspace.directory)
                        }
                        .tag(MacDestination.workspace(workspace.directory))
                        .contextMenu {
                            Button("New session") { Task { await model.createSession(in: workspace.directory) } }
                                .disabled(model.state.working || model.openingSession || model.startupError != nil)
                            Button("Show in Finder") { model.revealWorkspace(workspace.directory) }
                            Button("Copy path") { model.copy(workspace.directory) }
                            Button("Remove workspace…", role: .destructive) { removingWorkspace = workspace.directory }
                        }
                    }
                } header: {
                    HStack {
                        Text("Workspaces")
                        Spacer()
                        Menu {
                            Button("New session") {
                                if let path = model.selectedWorkspace { Task { await model.createSession(in: path) } }
                                else { model.panel = "directory" }
                            }.disabled(model.state.working || model.openingSession || model.startupError != nil)
                            Button("Add workspace…") { model.panel = "workspace" }
                                .accessibilityIdentifier("mac-add-workspace")
                            Divider()
                            Button("Import session…") { model.panel = "import" }
                                .disabled(model.state.working || model.openingSession)
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Workspace actions").accessibilityIdentifier("mac-workspace-actions")
                        .help("New session, add workspace or import session")
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            Divider()
            List(selection: sidebarSelection) {
                Section("Devices & Settings") {
                    Label("Devices", systemImage: "iphone").tag(MacDestination.devices)
                    Label("Settings", systemImage: "gearshape").tag(MacDestination.settings)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden).frame(height: 116)
        }
        .background(.white).accessibilityIdentifier("mac-workspace-sidebar")
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        let context = model.state.context
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: session.id == model.state.selected ? "circle.fill" : "circle")
                    .font(.system(size: 6)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.displayName(for: session)).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Text(session.id == model.state.selected ? model.state.phase.capitalized : (session.interrupted ? "Needs review" : "Saved"))
                Spacer(minLength: 4)
                Text(session.updated, style: .relative)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(model.fullDisplayName(for: session) + "\n" + session.directory + "\nSession " + session.id.uuidString)
        .accessibilityIdentifier("mac-session-" + session.id.uuidString)
        .contextMenu {
            Button("Open session") { Task { await model.openSession(session.id) } }
                .disabled(model.openingSession)
            Button("Rename…") { beginRename(session.id) }
                .disabled(!canRename(session.id))
            Button("Copy session ID") { model.copy(session.id.uuidString) }
            if session.id == model.state.selected {
                Button("Session controls") { model.destination = .session(session.id); showInspector("Tools") }
                Button("History and fork options") { showSessionWorkflow(.history, session: session, context: context) }
                    .disabled(model.state.working)
            }
        }
    }

    private func canRename(_ id: UUID) -> Bool {
        id == model.state.selected && model.state.phase == "idle" && !model.openingSession
    }

    private func beginRename(_ id: UUID) {
        guard canRename(id) else { return }
        renamingSession = id
        model.panel = "rename"
    }

    private func showInspector(_ tab: String) {
        inspectorSection = tab
        model.inspectorVisible = true
    }

    @ViewBuilder private var notices: some View {
        if let error = model.startupError { Text(error).textSelection(.enabled).padding(12) }
        if let error = model.draftSaveError { Text(error).font(.callout).padding(12) }
        if let error = model.composerError {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { model.composerError = nil }
            }.padding(12).accessibilityIdentifier("mac-composer-error")
        }
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
                    Text(model.workspaces.isEmpty ? "Start with a workspace" : "Choose a session").font(.title2.bold())
                    Text(model.workspaces.isEmpty
                         ? "Add a Mac folder, then use New session in the toolbar. Pi works locally without a server or iPhone."
                         : "Expand a workspace in the sidebar to open a saved conversation, or use New session in the toolbar.").foregroundStyle(.secondary)
                    HStack {
                        Button("Add workspace", systemImage: "folder.badge.plus") { model.panel = "workspace" }.buttonStyle(.borderedProminent)
                    }
                    Divider()
                    DisclosureGroup("iPhone access (optional)") { CompanionServerControls(model: model) }
                    Text("\(model.workspaces.count) workspaces · \(model.state.sessions.count) saved sessions").font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 700, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspaceDetail(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder").font(.title2.bold())
            Text(path).font(.callout.monospaced()).textSelection(.enabled)
            let count = model.state.sessions.filter { $0.directory == path }.count
            Text(count == 0 ? "No sessions in this workspace" : "\(count) saved session\(count == 1 ? "" : "s")")
                .font(.headline)
            Text(count == 0
                 ? "Use New session in the toolbar to start a conversation in this folder."
                 : "Expand this workspace in the sidebar to open a session. Use New session in the toolbar for a new conversation.")
                .foregroundStyle(.secondary)
            Button("Show in Finder") { model.revealWorkspace(path) }
            if model.state.working { Text("Pi is working in another session. New sessions and activation wait until that work stops.").font(.caption) }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func sessionDetail(_ id: UUID) -> some View {
        if let session = model.state.sessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                sessionHeader(session)
                Divider()
                if id == model.state.selected {
                    if ["unavailable", "interrupted"].contains(model.state.phase) {
                        HStack {
                            Text("Pi is not running. Use /resume to choose a session, or open this one. No instruction will be resent.").font(.caption)
                            Button("Open session") { Task { await model.openSession(id) } }.disabled(model.openingSession)
                        }.padding(12)
                    }
                    if model.openingSession {
                        ProgressView("Opening session…").frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("mac-session-loading")
                    } else {
                        let displayedState = model.state
                        ConversationView(state: displayedState, text: $model.text, delivery: $model.delivery, sending: model.sending,
                                         send: { model.send(context: displayedState.context) }, stop: { model.stopWork() }, request: model.scopedRequest(for: displayedState)) {
                            Button("Files", systemImage: "folder") { showInspector("Files") }
                                .help("Browse files and attach text from a file preview").accessibilityIdentifier("mac-composer-files")
                            Button("Commands", systemImage: "slash.circle") { model.panel = "commands" }
                                .help("Open Pi commands").accessibilityIdentifier("mac-composer-commands")
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

    private func sessionHeader(_ session: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.displayName(for: session)).font(.title3.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    .help(model.fullDisplayName(for: session))
                    .accessibilityIdentifier("mac-session-heading")
                Spacer(minLength: 0)
                if session.id == model.state.selected {
                    Text(model.openingSession ? "Opening Pi session…" : model.piStatus).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("mac-session-status")
                    sessionActions(session)
                } else {
                    Text(model.openingSession ? "Opening…" : "Saved · not loaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            let workspace = URL(fileURLWithPath: session.directory).lastPathComponent
            let configuration = session.id == model.state.selected && !model.state.model.isEmpty
                ? " / " + model.state.model + (model.state.thinking.isEmpty ? "" : " · " + model.state.thinking) : ""
            Text((workspace.isEmpty ? "/" : workspace) + configuration)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(session.directory + configuration).accessibilityIdentifier("mac-session-metadata")
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private func showSessionWorkflow(_ command: MacNativeSlashCommand, session: SessionInfo, context: SessionContext) {
        guard model.state.context == context, model.state.selected == session.id else { model.fault = .conflict; return }
        guard let option = MacSlashCommands.options(in: model.state).first(where: { $0.native == command }), option.isEnabled(in: model.state) else {
            model.composerError = "This session action is not available in the current state."
            return
        }
        model.destination = .session(session.id)
        model.panel = command.rawValue
    }

    private func sessionActions(_ session: SessionInfo) -> some View {
        let context = model.state.context
        let commands = MacSlashCommands.options(in: model.state)
        return Menu {
            Button("Session controls") { showInspector("Tools") }
            Button("Rename…") { beginRename(session.id) }.disabled(!canRename(session.id))
            Button("Resume session…") { showSessionWorkflow(.resume, session: session, context: context) }
                .disabled(commands.first { $0.native == .resume }?.isEnabled(in: model.state) != true)
            Button("Session tree") { showSessionWorkflow(.tree, session: session, context: context) }
                .disabled(commands.first { $0.native == .tree }?.isEnabled(in: model.state) != true)
            Button("History") { showSessionWorkflow(.history, session: session, context: context) }
                .disabled(commands.first { $0.native == .history }?.isEnabled(in: model.state) != true)
            Divider()
            Button("Commands") { model.panel = "commands" }
            Button("Files") { showInspector("Files") }
            Button("Extension diagnostics") { showInspector("Activity") }
            Button("Copy working directory") { model.copy(session.directory) }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Session actions").accessibilityIdentifier("mac-session-actions")
        .help("Session controls, resume, tree, history and diagnostics")
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
                        Section("Extension diagnostics") {
                            if model.state.notices.isEmpty { Text("No extension diagnostics").font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(model.state.notices.enumerated()), id: \.offset) { _, value in
                                Text(value).font(.caption).textSelection(.enabled)
                            }
                        }.accessibilityIdentifier("mac-extension-diagnostics")
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
            case "rename":
                if let id = renamingSession, id == state.selected,
                   let session = state.sessions.first(where: { $0.id == id }) {
                    MacRenameSessionView(initialName: session.title, state: state, request: model.scopedRequest(for: state)) {
                        model.panel = nil; renamingSession = nil
                    }
                }
            case "resume": MacResumeSessionView(model: model)
            case "tree": SessionTreeView(request: model.scopedRequest(for: state)) {
                if model.panel == "tree" { model.panel = nil }
            }
            case "history": HistoryView(request: model.scopedRequest(for: state), paged: true) {
                if model.panel == "history" { model.panel = nil }
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

struct MacResumeSessionView: View {
    @Bindable var model: CompanionModel
    @State private var interrupted: SessionInfo?
    @State private var activating = false
    @State private var error: String?

    var body: some View {
        List {
            Text("Choose a companion-managed session. Previous instructions are not resent.")
                .font(.caption).foregroundStyle(.secondary)
            if model.state.working {
                Text("Pi is working. Wait or use Stop before switching sessions.").font(.callout)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            if activating { ProgressView("Opening session…") }
            if model.state.sessions.isEmpty { Text("No saved sessions. Use New session in the toolbar to create one.") }
            ForEach(model.state.sessions.sorted { $0.updated > $1.updated }) { session in
                Button {
                    if session.interrupted { interrupted = session }
                    else { activate(session.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.displayName(for: session)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if session.id == model.state.selected { Text("Loaded").font(.caption) }
                            else if session.interrupted { Text("Needs review").font(.caption) }
                        }
                        Text(session.directory).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text(session.updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .buttonStyle(.plain).disabled(activating || model.openingSession || model.state.working)
                .help(model.fullDisplayName(for: session) + "\n" + session.directory)
                .accessibilityIdentifier("mac-resume-session-" + session.id.uuidString)
            }
        }
        .navigationTitle("Resume session").accessibilityIdentifier("mac-resume-sessions")
        .confirmationDialog("Resume interrupted session?", isPresented: Binding(
            get: { interrupted != nil }, set: { if !$0 { interrupted = nil } }
        )) {
            Button("Resume without resending instructions") {
                if let session = interrupted { activate(session.id) }
                interrupted = nil
            }
        } message: {
            Text("Saved messages do not prove that interrupted tools completed. Review the transcript and project before sending another instruction.")
        }
    }

    private func activate(_ id: UUID) {
        guard !activating, !model.openingSession, !model.state.working else { return }
        activating = true; error = nil
        Task {
            defer { activating = false }
            if await model.openSession(id) {
                if model.panel == "resume" { model.panel = nil }
            } else { error = (model.fault ?? .unavailable).explanation }
        }
    }
}

struct MacRenameSessionView: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    let renamed: () -> Void
    @State private var name: String
    @State private var saving = false
    @State private var error: String?

    init(initialName: String, state: HostSnapshot, request: @escaping (SessionAction) async throws -> AppResult, renamed: @escaping () -> Void) {
        self.state = state; self.request = request; self.renamed = renamed
        _name = State(initialValue: initialName)
    }

    private var proposedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("Session name") {
                TextField("Name", text: $name).accessibilityIdentifier("mac-session-rename-name")
                    .disabled(saving)
                Text("Updates the name in Pi. The session ID, working directory and saved messages do not change.")
                    .font(.caption).foregroundStyle(.secondary)
                if proposedName.utf8.count > 256 { Text("Use a name of at most 256 UTF-8 bytes.").font(.caption) }
            }
            if let error { Text(error).textSelection(.enabled) }
        }
        .navigationTitle("Rename session")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Rename") {
                    guard !saving, state.phase == "idle", state.selected != nil,
                          !proposedName.isEmpty, proposedName.utf8.count <= 256 else { return }
                    saving = true
                    let value = proposedName
                    Task {
                        defer { saving = false }
                        do {
                            let result = try await request(.rename(name: value))
                            if case .failure(let fault) = result { throw fault }
                            renamed()
                        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                    }
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("mac-session-rename-save")
                .disabled(saving || state.phase != "idle" || state.selected == nil || proposedName.isEmpty || proposedName.utf8.count > 256)
            }.padding(16)
        }
    }
}
