import AppKit
import Observation
import PiRemoteCore
import PiRemoteHost
import SwiftUI

/// Window-owned state stays current in lazy menu and sheet closures.
@Observable @MainActor private final class MacWindowPresentation {
    var inspectorSection = "Files"
    var remoteDetailsVisible = false
    var renamingSession: UUID?
    var closingSession: LocalCloseConfirmation?
}

struct CompanionWindow: View {
    @Bindable var model: CompanionModel
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityEnabled) private var systemAccessibilityEnabled
    @SceneStorage("macWorkspaceSidebarWidth") private var sidebarWidth = 240.0
    @SceneStorage("macWorkspaceInspectorWidth") private var inspectorWidth = 320.0
    @State private var presentation = MacWindowPresentation()
    @State private var toolbarHeight: CGFloat = 44
    @State private var removingWorkspace: String?
    @State private var hoveredSession: UUID?
    @State private var sheetFocusTarget: NSView?
    private var theme: MacInterfaceTheme { MacInterfaceTheme(mode: model.interfaceMode) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(compact: geometry.size.width < 1100)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
                Divider()
                HSplitView {
                    if model.sidebarVisible {
                        sidebar.frame(minWidth: 210, idealWidth: sidebarWidth, maxWidth: 320)
                            .background(MacSidebarWidthKeeper(preferredWidth: $sidebarWidth))
                    }
                    VStack(spacing: 0) {
                        notices
                        detail
                    }.frame(minWidth: 400, maxWidth: .infinity,
                            minHeight: max(0, geometry.size.height - toolbarHeight - 1), maxHeight: .infinity).layoutPriority(1)
                    if model.inspectorVisible && inspectorHasContent {
                        inspector.frame(minWidth: 260, idealWidth: min(inspectorWidth, 320), maxWidth: 320)
                            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { value in
                                if value >= 260, value <= 320, abs(inspectorWidth - value) > 1 { inspectorWidth = value }
                            }
                    }
                }
            }
            .background(theme.background)
            .foregroundStyle(theme.text)
            .sheet(isPresented: Binding(get: { model.panel != nil }, set: { if !$0 { model.panel = nil } }), onDismiss: {
                if let target = sheetFocusTarget, let window = target.window { window.makeFirstResponder(target) }
                sheetFocusTarget = nil
            }) {
                sheet
                    .frame(width: min(600, max(480, geometry.size.width - 32)),
                           height: min(640, max(360, geometry.size.height - 40)))
            }
        }
        .background(MacDebugWindowMarker(selectInspector: { section in
            showInspector(section)
        }).frame(width: 1, height: 1).allowsHitTesting(false))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.debug.enabled {
                HStack {
                    Label("Local debug mode is on · app-only UI controls enabled", systemImage: "ladybug")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Button("Disable debug mode") { model.debug.disable() }
                        .accessibilityIdentifier("mac-debug-banner-disable")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(theme.background).foregroundStyle(theme.text)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mac-debug-banner")
            }
        }
        .environment(\.colorScheme, model.interfaceMode == .pi ? .dark : systemColorScheme)
        .environment(\.macInterfaceMode, model.interfaceMode)
        // Expose SwiftUI's in-process tree for opted-in debug clicks. Preserve
        // system accessibility when debug is off; no global permission changes.
        .environment(\.accessibilityEnabled, systemAccessibilityEnabled || model.debug.enabled)
        .tint(theme.accent)
        .modifier(EditorOfferPrompt(offer: $model.editorOffer, replace: model.acceptEditorOffer))
        .confirmationDialog("Send this prompt again?", isPresented: $model.confirmResend) {
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
        .confirmationDialog("Stop and close this session?", isPresented: Binding(
            get: { presentation.closingSession != nil }, set: { if !$0 { presentation.closingSession = nil } }
        )) {
            Button("Stop and Close", role: .destructive) {
                if let target = presentation.closingSession, let id = target.context.session {
                    Task { await model.closeSession(id, confirmation: target) }
                }
                presentation.closingSession = nil
            }.accessibilityIdentifier("mac-session-stop-and-close")
        } message: {
            Text("Stop clears queued messages and waits for Pi to become idle before closing this session. File changes cannot be undone. Saved history and the draft are kept.")
        }
        .onChange(of: model.panel) { old, new in
            if old == nil, new != nil { sheetFocusTarget = NSApp.mainWindow?.firstResponder as? NSView }
        }
        .onChange(of: model.state.context) { _, _ in
            // A sheet must never silently retarget an action to a different loaded session.
            if let panel = model.panel, !["pairingQR", "hotkeys"].contains(panel) { model.panel = nil }
            if !model.state.dialogs.isEmpty { model.panel = "dialog" }
            presentation.renamingSession = nil
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Button("Sidebar", systemImage: "sidebar.left") { model.sidebarVisible.toggle() }
                .labelStyle(.iconOnly).keyboardShortcut("s", modifiers: [.command, .option])
                .accessibilityIdentifier("mac-sidebar-toggle")
            MacInterfaceModePicker(selection: $model.interfaceMode)
                .frame(width: 136, height: 24)
                .help("Interface appearance: Pi or Desktop")
            Button("New session", systemImage: "plus") {
                if let path = model.selectedWorkspace { Task { await model.createSession(in: path) } }
                else { model.panel = "directory" }
            }
            .disabled(model.state.working || model.openingSession || model.startupError != nil)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("mac-new-session")
            if model.state.working {
                Button("Stop", role: .destructive) { model.stopWork() }
                    .help("Stop active Pi work and clear queued messages. File changes are not undone.")
                    .accessibilityIdentifier("mac-stop")
            }
            Spacer(minLength: 8)
            if !model.showingLoadedSession {
                Text(model.piStatus).font(.caption).lineLimit(1)
                    .accessibilityIdentifier("mac-session-status")
            }
            Button { showInspector("Files") } label: {
                if compact { Image(systemName: "folder") } else { Label("Files", systemImage: "folder") }
            }
            .buttonStyle(.plain).accessibilityLabel("Files")
                .disabled(!model.hasInspectorContext)
                .help(model.hasInspectorContext ? "Files" : "Choose a workspace or session to browse files.")
                .accessibilityIdentifier("mac-files")
            Button { model.panel = "commands" } label: {
                if compact { Image(systemName: "slash.circle") } else { Label("Pi commands", systemImage: "slash.circle") }
            }
            .buttonStyle(.plain).accessibilityLabel("Pi commands").help("Pi commands").accessibilityIdentifier("mac-commands")
            sessionMenu
            globalActions
            Button("Inspector", systemImage: "sidebar.right", action: toggleInspector)
                .disabled(!model.hasInspectorContext)
                .accessibilityIdentifier("mac-inspector-toggle")
                .labelStyle(.iconOnly).keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide Files, Session and Activity")
        }
        .padding(.horizontal, compact ? 12 : 16).padding(.vertical, 10)
        .background {
            // Menu content is lazy. Keep global shortcuts mounted outside closed menus.
            HStack(spacing: 0) {
                Button("Switch session") { switchSession() }
                    .disabled(!canBrowseSessions).keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Command palette") { openCommandPalette() }
                    .disabled(!model.state.dialogs.isEmpty || model.closingSession != nil)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Close Session") { closeFocusedSession(focusedSession) }
                    .disabled(focusedCloseDisabled).keyboardShortcut("w", modifiers: [.command, .shift])
            }
            .frame(width: 0, height: 0).clipped().opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func switchSession() {
        guard canBrowseSessions else { return }
        model.openNativeWorkflow(.resume)
    }

    private func openCommandPalette() {
        guard model.state.dialogs.isEmpty, model.closingSession == nil else { return }
        model.panel = "palette"
    }

    private func closeFocusedSession(_ id: UUID?, confirmation: Binding<LocalCloseConfirmation?>? = nil) {
        guard let id, id == focusedSession else { return }
        beginClose(id, confirmation: confirmation)
    }

    private var sessionMenu: some View {
        let closeTarget = focusedSession
        let inspectorSelection = $presentation.inspectorSection
        let renameSelection = $presentation.renamingSession
        let closeConfirmation = $presentation.closingSession
        return Menu("Session") {
            if let session = model.state.sessions.first(where: { $0.id == focusedSession }) {
                Text((session.id == model.state.selected ? "Loaded session: " : "Saved session: ") + model.displayName(for: session))
            } else if let session = model.state.sessions.first(where: { $0.id == model.state.selected }) {
                Text("Active session: " + model.displayName(for: session))
            }
            Button("View conversation") { model.destination = .conversation }
            if let id = model.state.selected, !model.showingLoadedSession {
                Button("View active session") { model.destination = .session(id) }
            }
            Button("Switch session…") { switchSession() }
                .disabled(!canBrowseSessions)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .accessibilityIdentifier("mac-session-switcher-toggle")
            Button("Session controls") {
                inspectorSelection.wrappedValue = "Session"
                model.inspectorVisible = true
            }.disabled(!model.hasInspectorContext)
            if let session = model.state.sessions.first(where: { $0.id == focusedSession }), session.id == model.state.selected {
                Divider()
                contextualSessionActions(session, inspectorSelection: inspectorSelection, renameSelection: renameSelection)
            }
            Divider()
            Button("Close Session") { closeFocusedSession(closeTarget, confirmation: closeConfirmation) }
                .disabled(focusedCloseDisabled)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .accessibilityIdentifier("mac-close-focused-session")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityIdentifier("mac-session-menu")
        .help("Conversation, session switching, controls and contextual session actions")
    }

    private var globalActions: some View {
        let remoteDetails = $presentation.remoteDetailsVisible
        return Menu("Actions") {
            Button("Command palette…") { openCommandPalette() }
            .disabled(!model.state.dialogs.isEmpty || model.closingSession != nil)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .accessibilityIdentifier("mac-command-palette-toggle")
            Button("Keyboard shortcuts") { model.panel = "hotkeys" }
            Divider()
            Button("Overview") { model.destination = .overview }
            Button("Add workspace…") { model.panel = "workspace" }
            Button("Import session…") { model.panel = "import" }
                .disabled(model.state.working || model.openingSession)
            Divider()
            Button("Settings") { model.destination = .settings }
            Button("Devices") { model.destination = .devices }
            Button("iPhone access…") { remoteDetails.wrappedValue = true }
                .accessibilityIdentifier("mac-remote-access")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityIdentifier("mac-global-actions")
        .help("App navigation, command palette, settings, devices and remote access")
        .popover(isPresented: $presentation.remoteDetailsVisible) {
            VStack(alignment: .leading, spacing: 12) {
                Text("iPhone access").font(.headline)
                Text(model.serverStatus).accessibilityIdentifier("mac-remote-server-status")
                if model.listening { Text(model.serverEndpoint).font(.caption.monospaced()).textSelection(.enabled) }
                Text(model.connectionStatus).accessibilityIdentifier("mac-remote-device-status")
                Text("Remote access is optional. It only controls iPhone connections; local Pi sessions work without it.").font(.caption)
                HStack {
                    Button("iPhone access settings") { presentation.remoteDetailsVisible = false; model.destination = .settings }
                    Button("Devices") { presentation.remoteDetailsVisible = false; model.destination = .devices }
                }
            }.padding(16).frame(width: 310)
        }
    }

    private var sidebarSelection: Binding<MacDestination?> {
        Binding(get: { model.destination }, set: { destination in
            // Removing a sidebar List can emit nil. Keep the displayed screen.
            guard let destination else { return }
            if case .session(let id) = destination { Task { await model.openSession(id) } }
            else { model.destination = destination }
        })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Label("Pi", systemImage: "text.alignleft").tag(MacDestination.conversation)
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
        .background(theme.background).accessibilityIdentifier("mac-workspace-sidebar")
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        let context = model.state.context
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: session.id == model.state.selected ? "circle.fill" : "circle")
                    .font(.system(size: 6)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.displayName(for: session)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                MacSessionCloseButton(id: session.id, visible: hoveredSession == session.id || model.destination == .session(session.id),
                                      disabledReason: macCloseSessionDisabledReason(session.id, model: model)) { beginClose(session.id) }
            }
            HStack {
                Text(sessionStatus(session))
                Spacer(minLength: 4)
                Text(session.updated, style: .relative)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onHover { hoveredSession = $0 ? session.id : nil }
        .help(model.fullDisplayName(for: session) + "\n" + session.directory + "\nSession " + session.id.uuidString)
        .accessibilityIdentifier("mac-session-" + session.id.uuidString)
        .contextMenu {
            Button("Open session") { Task { await model.openSession(session.id) } }
                .disabled(model.openingSession)
            Button("Rename…") { beginRename(session.id) }
                .disabled(!canRename(session.id))
            Button("Close Session") { beginClose(session.id) }
                .disabled(macCloseSessionDisabledReason(session.id, model: model) != nil)
            Button("Copy session ID") { model.copy(session.id.uuidString) }
            if session.id == model.state.selected {
                Button("Session controls") { model.destination = .session(session.id); showInspector("Session") }
                Button("History and fork options") { showSessionWorkflow(.history, session: session, context: context) }
                    .disabled(model.state.working)
            }
        }
    }

    private var canBrowseSessions: Bool {
        model.closingSession == nil && MacSlashCommands.options(in: model.state)
            .first(where: { $0.native == .resume })?.isEnabled(in: model.state) == true
    }

    private var focusedSession: UUID? {
        if case .session(let id) = model.destination { return id }
        return model.destination == .conversation ? model.state.selected : nil
    }

    private var focusedCloseDisabled: Bool {
        guard let id = focusedSession else { return true }
        return macCloseSessionDisabledReason(id, model: model) != nil
    }

    private func beginClose(_ id: UUID, confirmation: Binding<LocalCloseConfirmation?>? = nil) {
        guard macCloseSessionDisabledReason(id, model: model) == nil else { return }
        if model.closeSessionRequiresConfirmation(id) {
            Task {
                if let value = await model.prepareSessionClose(id) {
                    if let confirmation { confirmation.wrappedValue = value }
                    else { presentation.closingSession = value }
                }
            }
        } else {
            Task { await model.closeSession(id) }
        }
    }

    private func sessionStatus(_ session: SessionInfo) -> String {
        macSessionStatus(session, model: model)
    }

    private func canRename(_ id: UUID) -> Bool {
        macRenameSessionDisabledReason(id, model: model) == nil
    }

    private func beginRename(_ id: UUID) {
        guard canRename(id) else { return }
        presentation.renamingSession = id
        model.panel = "rename"
    }

    private func openPiControl(_ name: String) -> Bool {
        guard model.state.dialogs.isEmpty else { model.composerError = "Answer or cancel the open request first."; return false }
        let idleOnly = ["new", "compact", "fork", "clone", "settings", "name", "export", "import"]
        guard !idleOnly.contains(name) || !model.state.working else { model.composerError = "Wait for Pi to become idle."; return false }
        switch name {
        case "session", "clone": showInspector("Session")
        case "settings": model.panel = "runtime"
        case "fork": return model.openNativeWorkflow(.tree)
        case "name":
            guard let id = model.state.selected, canRename(id) else { return false }
            beginRename(id)
        case "files": showInspector("Files")
        case "commands": model.panel = "commands"
        default: model.panel = name
        }
        return true
    }

    private var inspectorHasContent: Bool {
        switch presentation.inspectorSection {
        case "Session": return model.hasInspectorContext
        case "Activity": return model.hasInspectorContext
        default: return inspectorDirectory != nil
        }
    }

    private func toggleInspector() {
        guard model.hasInspectorContext else { return }
        if model.inspectorVisible && inspectorHasContent { model.inspectorVisible = false }
        else {
            if model.selectedWorkspace == nil { presentation.inspectorSection = "Session" }
            model.inspectorVisible = true
        }
    }

    private var loadedInspectorSession: SessionInfo? {
        model.state.sessions.first { $0.id == model.state.selected }
    }

    private var inspectorDirectory: String? {
        model.selectedWorkspace ?? loadedInspectorSession?.directory
    }

    private func showInspector(_ tab: String) {
        guard model.hasInspectorContext else { return }
        // Inspector selection never changes the conversation or starts Pi.
        presentation.inspectorSection = tab
        model.inspectorVisible = true
    }

    @ViewBuilder private var notices: some View {
        if let error = model.startupError { Text(error).textSelection(.enabled).padding(12) }
        if let error = model.draftSaveError { Text(error).font(.callout).padding(12) }
        if let error = model.sessionVisibilityError {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                .padding(12).accessibilityIdentifier("mac-session-visibility-error")
        }
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
        if model.destination == .conversation || model.showingLoadedSession {
            liveConversation
        } else {
            switch model.destination {
            case .devices: CompanionDevicesView(model: model)
            case .settings:
                CompanionConnectionSettings(model: model) {
                    guard let id = model.state.selected else { return }
                    model.destination = .session(id)
                    showInspector("Session")
                }
            case .workspace(let path): workspaceDetail(path)
            case .session(let id): sessionDetail(id)
            default: overview
            }
        }
    }

    private var liveConversation: some View {
        VStack(spacing: 0) {
            if let id = model.state.selected, ["unavailable", "interrupted"].contains(model.state.phase) {
                HStack {
                    Text("Pi is not running. Use /resume to choose a session, or open this one. No prompt will be resent.").font(.caption)
                    Button("Open session") { Task { await model.openSession(id) } }.disabled(model.openingSession)
                        .accessibilityIdentifier("mac-reopen-loaded-session")
                }.padding(12)
            }
            ZStack {
                // Both live navigation aliases keep the same native editor and transcript state.
                PiConversationView(model: model, openControls: openPiControl)
                    .disabled(model.closingSession != nil || model.openingSession)
                    .opacity(model.openingSession ? 0 : 1)
                    .accessibilityHidden(model.openingSession)
                if model.openingSession {
                    ProgressView("Opening session…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("mac-session-loading")
                }
            }
        }
    }

    private var overview: some View {
        List {
            Section {
                Text("Sessions").font(.title2.bold()).background(MacDebugPageScrollMarker())
                Text("Opening a session never stops work in another session. Closing keeps saved history and drafts.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add workspace", systemImage: "folder.badge.plus") { model.panel = "workspace" }
                    Button("Switch session…") { model.openNativeWorkflow(.resume) }
                        .disabled(!canBrowseSessions)
                }
            }
            ForEach(overviewDirectories, id: \.self) { path in
                Section {
                    HStack {
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("New session") { Task { await model.createSession(in: path) } }
                            .disabled(model.state.working || model.openingSession || model.startupError != nil)
                    }
                    ForEach(model.state.sessions.filter { $0.directory == path }.sorted { $0.updated > $1.updated }) { session in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName(for: session)).lineLimit(1).truncationMode(.middle)
                                    .help(model.fullDisplayName(for: session))
                                HStack {
                                    Text(sessionStatus(session))
                                    Text(session.updated, style: .relative)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(macOpenSessionLabel(session.id, model: model)) {
                                if session.id == model.state.selected { model.destination = .session(session.id) }
                                else if !model.openingSession, !model.state.working { Task { await model.openSession(session.id) } }
                            }
                                .disabled(session.id != model.state.selected && (model.openingSession || model.state.working))
                                .accessibilityIdentifier("mac-overview-open-" + session.id.uuidString)
                            Button("Close") { beginClose(session.id) }
                                .disabled(macCloseSessionDisabledReason(session.id, model: model) != nil)
                                .help(macCloseSessionDisabledReason(session.id, model: model) ?? "Close Session; keep history and draft")
                                .accessibilityIdentifier("mac-overview-close-" + session.id.uuidString)
                        }.padding(.vertical, 2)
                    }
                } header: { Text(URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent) }
            }
            if model.state.sessions.isEmpty {
                Text("No saved sessions. Add a workspace, then use New session.").foregroundStyle(.secondary)
            }
            if let error = model.state.error { Label(error.explanation, systemImage: "exclamationmark.triangle") }
            Section {
                DisclosureGroup("iPhone access (optional)") { CompanionServerControls(model: model) }
            }
        }.accessibilityIdentifier("mac-session-overview")
    }

    private var overviewDirectories: [String] {
        Set(model.workspaces.map(\.directory) + model.state.sessions.map(\.directory)).sorted()
    }

    private func workspaceDetail(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder").font(.title2.bold())
            Text(path).font(.callout.monospaced()).textSelection(.enabled)
            let sessions = model.state.sessions.filter { $0.directory == path }
            let count = sessions.count
            let allClosed = !sessions.isEmpty && sessions.allSatisfy { model.closedSessionIDs.contains($0.id) }
            Text(count == 0 ? "No sessions in this workspace" : "\(count) saved session\(count == 1 ? "" : "s")")
                .font(.headline)
            Text(count == 0
                 ? "Use New session in the toolbar to start a conversation in this folder."
                 : (allClosed ? "All sessions are closed. Use Switch session to reopen a saved conversation. History and drafts are kept."
                    : "Expand this workspace in the sidebar to open a session. Use New session in the toolbar for a new conversation."))
                .foregroundStyle(.secondary)
            if allClosed {
                Button("Switch session…") { model.openNativeWorkflow(.resume) }.disabled(!canBrowseSessions)
            }
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
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle)
                    Text(model.openingSession ? "Opening session…" : "Open the saved session").font(.title3)
                    Text(model.state.working ? "Another session is working. Its process will not be interrupted. Stop it before activating this session." : "Pi restores this session from its saved file. Previous messages are not sent again.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Open session") { Task { await model.openSession(id) } }
                        .buttonStyle(.borderedProminent).disabled(model.state.working || model.openingSession)
                    if model.openingSession { ProgressView() }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(model.openingSession ? "Opening…" : "Saved · not loaded")
                    .font(.caption).foregroundStyle(.secondary)
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
        _ = model.openNativeWorkflow(command, context: context)
    }

    @ViewBuilder private func contextualSessionActions(_ session: SessionInfo, inspectorSelection: Binding<String>,
                                                      renameSelection: Binding<UUID?>) -> some View {
        let context = model.state.context
        let commands = MacSlashCommands.options(in: model.state)
        Button("Rename…") {
            guard focusedSession == session.id, model.state.context == context, canRename(session.id) else { return }
            renameSelection.wrappedValue = session.id
            model.panel = "rename"
        }.disabled(!canRename(session.id))
        Button("Session tree") {
            guard focusedSession == session.id else { return }
            showSessionWorkflow(.tree, session: session, context: context)
        }
            .disabled(commands.first { $0.native == .tree }?.isEnabled(in: model.state) != true)
        Button("History") {
            guard focusedSession == session.id else { return }
            showSessionWorkflow(.history, session: session, context: context)
        }
            .disabled(commands.first { $0.native == .history }?.isEnabled(in: model.state) != true)
        Button("Extension diagnostics") {
            inspectorSelection.wrappedValue = "Activity"
            model.inspectorVisible = true
        }
        Button("Copy working directory") { model.copy(session.directory) }
    }

    @ViewBuilder private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: Binding(get: { presentation.inspectorSection }, set: { section in showInspector(section) })) {
                Text("Files").tag("Files"); Text("Session").tag("Session")
                Text("Activity").tag("Activity")
            }.pickerStyle(.segmented).labelsHidden().padding(12)
                .accessibilityLabel("Inspector").accessibilityIdentifier("mac-inspector-sections")
            Divider()
            switch presentation.inspectorSection {
            case "Session":
                if let id = focusedSession, id == model.state.selected {
                    NavigationStack {
                        SessionControls(state: model.state, request: model.scopedRequest(for: model.state), closed: { model.destination = .overview },
                                        closeSession: { beginClose(id) }, closeSessionDisabledReason: macCloseSessionDisabledReason(id, model: model)) {
                            model.preview = $0; model.panel = "preview"
                        }
                            .formStyle(.grouped)
                    }.id(model.state.context)
                } else {
                    List {
                        VStack(alignment: .leading, spacing: 16) {
                            if let saved = model.state.sessions.first(where: { $0.id == focusedSession }) {
                                inspectorSessionSummary(saved, title: "Selected saved session", status: "Saved · Not loaded")
                                Text("Open this session from the conversation to use its Pi controls.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let session = loadedInspectorSession {
                                activeInspectorSummary(session)
                            } else if focusedSession == nil {
                                Label("No loaded session", systemImage: "slider.horizontal.3").font(.headline)
                                Text("Open a session to use its Pi controls.").font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                    }.listStyle(.inset)
                }
            case "Activity":
                List {
                    if let session = loadedInspectorSession {
                        Section {
                            inspectorSessionSummary(session, title: "Loaded session activity", status: model.piStatus)
                            if !model.showingLoadedSession { viewActiveSessionButton(session) }
                        }
                        if !model.state.messages.contains(where: { $0.role == "tool" }), model.state.error == nil {
                            Text("No tool activity yet.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.state.messages.filter { $0.role == "tool" }) { message in
                            let value = PiToolRowValue(message, runtimePhase: model.state.phase)
                            DisclosureGroup {
                                Text(value.expandedOutput).font(.caption.monospaced()).textSelection(.enabled)
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(value.action, systemImage: value.systemImage)
                                    if let target = value.target { Text(target).lineLimit(1).truncationMode(.middle) }
                                    Spacer(minLength: 4)
                                    Text(value.statusLabel).font(.caption)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(value.accessibilityHeading)
                            }
                            .accessibilityIdentifier("mac-activity-tool-" + message.id.uuidString)
                        }
                        if let error = model.state.error { Text(error.explanation) }
                        Section("Extension diagnostics") {
                            if model.state.notices.isEmpty { Text("No extension diagnostics").font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(model.state.notices.enumerated()), id: \.offset) { _, value in
                                Text(value).font(.caption).textSelection(.enabled)
                            }
                        }.accessibilityIdentifier("mac-extension-diagnostics")
                    } else {
                        if let saved = model.state.sessions.first(where: { $0.id == focusedSession }) {
                            inspectorSessionSummary(saved, title: "Selected saved session", status: "Saved · Not loaded")
                        }
                        Label("No loaded session", systemImage: "clock").font(.headline)
                        Text("Open a session to view activity. Saved-session activity is not loaded here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            default:
                if let path = inspectorDirectory { files(path: path) }
                else { ContentUnavailableView("Choose a workspace", systemImage: "folder") }
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(theme.background)
            .accessibilityIdentifier("mac-context-inspector")
    }

    private func inspectorSessionSummary(_ session: SessionInfo, title: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(model.displayName(for: session)).textSelection(.enabled)
                .accessibilityIdentifier(session.id == model.state.selected ? "mac-inspector-active-session" : "mac-inspector-saved-session")
            Text(session.directory).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain)
    }

    private func activeInspectorSummary(_ session: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorSessionSummary(session, title: "Active session", status: model.piStatus)
            Text("View the active session to use its Pi controls.").font(.callout).foregroundStyle(.secondary)
            viewActiveSessionButton(session)
        }
    }

    private func viewActiveSessionButton(_ session: SessionInfo) -> some View {
        Button("View active session") { model.destination = .session(session.id) }
            .accessibilityIdentifier("mac-inspector-view-active-session")
    }

    private func files(path: String) -> some View {
        let state = model.state
        let attach: ((FilePreview) throws -> Void)? = {
            guard let id = focusedSession, id == state.selected else { return nil }
            return { preview in
                guard focusedSession == id, model.showingLoadedSession else { throw RemoteFault.conflict }
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
                    PiExtensionDialog(dialog: dialog, request: model.scopedRequest(for: state)).id(dialog.id)
                }
            case "rename":
                if let id = presentation.renamingSession, id == state.selected,
                   let session = state.sessions.first(where: { $0.id == id }) {
                    MacRenameSessionView(initialName: session.title, state: state, request: { action in
                        guard canRename(id) else { throw RemoteFault.conflict }
                        return try await model.scopedRequest(for: state)(action)
                    }) {
                        model.panel = nil; presentation.renamingSession = nil
                    }
                }
            case "resume": MacResumeSessionView(model: model)
            case "palette": MacCommandPaletteView(model: model, renameSession: beginRename, toggleInspector: toggleInspector)
            case "tree": SessionTreeView(request: model.scopedRequest(for: state)) {
                if model.panel == "tree" { model.panel = nil }
            }
            case "history": HistoryView(request: model.scopedRequest(for: state), paged: true) {
                if model.panel == "history" { model.panel = nil }
            }
            case "model", "thinking":
                PiConfigurationPicker(state: state, thinking: model.panel == "thinking", request: model.scopedRequest(for: state)) { model.panel = nil }
            case "runtime": RuntimeSettingsView(request: model.scopedRequest(for: state))
            case "statistics": SessionStatisticsView(request: model.scopedRequest(for: state))
            case "compact": CompactionView(request: model.scopedRequest(for: state))
            case "new": NewManagedSessionView(state: state, request: model.scopedRequest(for: state)) { model.panel = nil }
            case "copy": LastAssistantView(request: model.scopedRequest(for: state))
            case "export": SessionExportView(request: model.scopedRequest(for: state))
            case "changelog": ReleaseNotesView(request: model.scopedRequest(for: state))
            case "hotkeys": PiHotkeysView()
            case "commands": SessionCommandsView(state: state, request: model.scopedRequest(for: state))
            case "pairingQR": PairingQRView(code: model.code)
            case "preview": if let preview = model.preview { FilePreviewView(preview: preview) }
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .background(MacDebugPanelMarker(panel: model.panel ?? ""))
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

@MainActor private func macSessionStatus(_ session: SessionInfo, model: CompanionModel) -> String {
    if model.closingSession == session.id { return "Closing…" }
    if session.id == model.state.selected {
        if !model.state.dialogs.isEmpty { return "Waiting for input" }
        if model.state.error != nil { return "\(model.state.phase.capitalized) · Error" }
        switch model.state.phase {
        case "idle": return "Idle"
        case "working", "streaming", "tool", "queued": return "Working"
        case "waiting": return "Waiting for input"
        case "starting": return "Starting"
        case "stopping": return "Stopping"
        case "recovering": return "Status uncertain"
        case "retrying": return "Retrying"
        case "compacting": return "Compacting"
        case "unavailable": return "Unavailable"
        case "interrupted": return "Interrupted · review required"
        default: return "Unknown"
        }
    }
    let saved = model.closedSessionIDs.contains(session.id) ? "Saved · Closed" : "Saved · Not loaded"
    return session.interrupted ? saved + " · Interrupted" : saved
}

private struct MacInterfaceModePicker: NSViewRepresentable {
    @Binding var selection: MacInterfaceMode

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = MacInterfaceSegmentedControl(labels: MacInterfaceMode.allCases.map(\.label), trackingMode: .selectOne,
                                                   target: context.coordinator, action: #selector(Coordinator.selectMode(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fill
        control.setAccessibilityIdentifier("mac-interface-mode")
        control.setAccessibilityLabel("Interface appearance")
        control.toolTip = "Pi keeps the compact dark interface. Desktop follows the Mac appearance."
        control.selectedSegment = MacInterfaceMode.allCases.firstIndex(of: selection) ?? 0
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = context.environment.isEnabled
        control.selectedSegment = MacInterfaceMode.allCases.firstIndex(of: selection) ?? 0
    }

    @MainActor final class Coordinator: NSObject {
        var parent: MacInterfaceModePicker
        init(_ parent: MacInterfaceModePicker) { self.parent = parent }

        @objc func selectMode(_ control: NSSegmentedControl) {
            guard control.isEnabled, MacInterfaceMode.allCases.indices.contains(control.selectedSegment) else { return }
            parent.selection = MacInterfaceMode.allCases[control.selectedSegment]
        }
    }
}

private final class MacInterfaceSegmentedControl: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        let next = min(max(selectedSegment + (event.keyCode == 124 ? 1 : -1), 0), segmentCount - 1)
        guard next != selectedSegment else { return }
        selectedSegment = next
        sendAction(action, to: target)
    }
}

private struct MacSessionCloseButton: View {
    let id: UUID
    let visible: Bool
    let disabledReason: String?
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: close) { Image(systemName: "xmark").font(.caption) }
            .buttonStyle(.borderless)
            .focused($focused)
            .disabled(disabledReason != nil)
            .opacity(visible || focused ? 1 : 0)
            .allowsHitTesting(visible || focused)
            .accessibilityLabel("Close Session")
            .accessibilityIdentifier("mac-session-close-" + id.uuidString)
            .help(disabledReason ?? "Close Session; keep saved history and draft")
    }
}

private struct MacNavigationSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let submit: () -> Void
    let move: (MoveCommandDirection) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            if let field, let window = field.window { window.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { field.delegate = nil }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacNavigationSearchField
        init(_ parent: MacNavigationSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.move(.down)
            case #selector(NSResponder.moveUp(_:)): parent.move(.up)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

struct MacResumeSessionView: View {
    @Bindable var model: CompanionModel
    @State private var interrupted: SessionInfo?
    @State private var activating = false
    @State private var error: String?
    @State private var query = ""
    @State private var selection: UUID?
    private var sessions: [SessionInfo] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return model.state.sessions.filter { session in
            let metadata = [model.displayName(for: session), model.fullDisplayName(for: session), session.title,
                            session.directory, session.id.uuidString, macSessionStatus(session, model: model)].joined(separator: " ")
            return terms.allSatisfy { metadata.localizedCaseInsensitiveContains($0) }
        }.sorted { $0.updated > $1.updated }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacNavigationSearchField(text: $query, placeholder: "Search sessions, workspaces, paths or IDs",
                                     identifier: "mac-session-search", submit: openSelection,
                                     move: { moveSelection($0) }, cancel: { model.panel = nil })
                .frame(height: 24).padding(12)
            List(selection: $selection) {
            Text("Choose a companion-managed session. Previous prompts are not resent.")
                .font(.caption).foregroundStyle(.secondary)
            if model.state.working {
                Text("Pi is working. Wait or use Stop before switching sessions.").font(.callout)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            if activating { ProgressView("Opening session…") }
            if model.state.sessions.isEmpty { Text("No saved sessions. Use New session in the toolbar to create one.") }
            if sessions.isEmpty && !model.state.sessions.isEmpty { Text("No matching sessions.") }
            ForEach(sessions) { session in
                Button {
                    selection = session.id
                    choose(session)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.displayName(for: session)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(macSessionStatus(session, model: model)).font(.caption)
                        }
                        Text(session.directory).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        HStack {
                            Text(session.updated, style: .relative)
                            Text(session.id.uuidString).lineLimit(1).truncationMode(.middle)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .buttonStyle(.plain).disabled(activating || model.openingSession || model.state.working)
                .tag(session.id)
                .help(model.fullDisplayName(for: session) + "\n" + session.directory + "\n" + session.id.uuidString)
                .accessibilityIdentifier("mac-resume-session-" + session.id.uuidString)
            }
            }
            HStack {
                Spacer()
                Button("Open selected session") { openSelection() }
                    .disabled(selection == nil || activating || model.openingSession || model.state.working)
                    .accessibilityIdentifier("mac-resume-open")
            }.padding(12)
        }
        .onAppear { selection = sessions.first?.id }
        .onChange(of: query) { _, _ in selection = sessions.first?.id }
        .navigationTitle("Resume session").accessibilityIdentifier("mac-resume-sessions")
        .confirmationDialog("Resume interrupted session?", isPresented: Binding(
            get: { interrupted != nil }, set: { if !$0 { interrupted = nil } }
        )) {
            Button("Resume without resending prompts") {
                if let session = interrupted { activate(session.id) }
                interrupted = nil
            }
        } message: {
            Text("Saved messages do not prove that interrupted tools completed. Review the transcript and project before sending another prompt.")
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !sessions.isEmpty else { return }
        let index = selection.flatMap { selected in sessions.firstIndex { $0.id == selected } } ?? 0
        selection = sessions[min(max(index + (direction == .down ? 1 : -1), 0), sessions.count - 1)].id
    }

    private func openSelection() {
        if let session = sessions.first(where: { $0.id == selection }) { choose(session) }
    }

    private func choose(_ session: SessionInfo) {
        guard !activating, !model.openingSession, !model.state.working else { return }
        if session.interrupted { interrupted = session }
        else { activate(session.id) }
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

@MainActor func macOpenSessionLabel(_ id: UUID, model: CompanionModel) -> String {
    if model.state.selected == id { return "View conversation" }
    return model.closedSessionIDs.contains(id) ? "Reopen" : "Open"
}

/// Presentation availability must not change the coordinator's idempotent Close.
@MainActor func macCloseSessionDisabledReason(_ id: UUID, model: CompanionModel) -> String? {
    if model.state.selected != id, model.closedSessionIDs.contains(id) { return "This session is already closed. Use Reopen to load it." }
    return model.closeSessionDisabledReason(id)
}

@MainActor func macRenameSessionDisabledReason(_ id: UUID?, model: CompanionModel) -> String? {
    guard let id, model.state.selected == id,
          model.state.sessions.contains(where: { $0.id == id }) else { return "Open the loaded session to rename it." }
    guard model.state.phase == "idle" else { return "Wait for Pi to become idle." }
    return model.closeSessionDisabledReason(id)
}

private struct MacCommandPaletteView: View {
    @Bindable var model: CompanionModel
    let renameSession: (UUID) -> Void
    let toggleInspector: () -> Void
    @State private var query = ""
    @State private var selection: String?
    @State private var renameContext: SessionContext?
    private let appActions = ["Overview", "New session", "Add workspace", "Settings", "Devices", "Rename session", "Toggle Inspector"]
    private var nativeOptions: [MacSlashOption] {
        MacSlashCommands.options(in: model.state).filter { $0.native != nil && matches($0.name + " " + $0.detail) }
    }
    private var actions: [String] { appActions.filter { matches($0) } }
    private var ids: [String] { actions + nativeOptions.map { "/" + $0.name } }
    private var unavailableReason: String? {
        if !model.state.dialogs.isEmpty { return "Answer or cancel the open request first." }
        if model.closingSession != nil { return "Wait for the session change to finish." }
        return nil
    }

    private func disabledReason(_ action: String) -> String? {
        if let unavailableReason { return unavailableReason }
        if action == "New session" { return newSessionDisabledReason }
        if action == "Toggle Inspector", !model.hasInspectorContext { return "Choose a workspace or session to use the inspector." }
        if action == "Rename session" {
            guard renameContext == model.state.context else { return "Reopen the palette for the current session." }
            guard let id = renameContext?.session, model.showingLoadedSession else { return "Display the loaded session to rename it." }
            return macRenameSessionDisabledReason(id, model: model)
        }
        return nil
    }

    private var newSessionDisabledReason: String? {
        if model.startupError != nil { return "Resolve the startup error first." }
        return model.state.working || model.openingSession || model.closingSession != nil ? "Wait for Pi to become idle." : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            MacNavigationSearchField(text: $query, placeholder: "Search actions", identifier: "mac-command-palette-search",
                                     submit: { if let selection { run(selection) } }, move: { direction in
                guard !ids.isEmpty else { return }
                let index = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
                selection = ids[min(max(index + (direction == .down ? 1 : -1), 0), ids.count - 1)]
            }, cancel: { model.panel = nil })
                .frame(height: 24).padding(12)
            List(selection: $selection) {
                ForEach(actions, id: \.self) { action in
                    Button { run(action) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action)
                            if let reason = disabledReason(action) {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabledReason(action) != nil)
                    .tag(action)
                    .accessibilityIdentifier("mac-palette-" + action.lowercased().replacingOccurrences(of: " ", with: "-"))
                }
                ForEach(nativeOptions) { option in
                    Button { run("/" + option.name) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("/" + option.name)
                            Text(unavailableReason ?? option.disabledReason(in: model.state) ?? option.detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailableReason != nil || !option.isEnabled(in: model.state))
                    .tag("/" + option.name)
                    .accessibilityIdentifier("mac-palette-" + option.name)
                }
                if ids.isEmpty { Text("No matching actions.").foregroundStyle(.secondary) }
            }
            Text("Choose an action explicitly. Search does not execute commands. Pi commands remain available from Commands and the composer.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .navigationTitle("Command palette")
        .accessibilityIdentifier("mac-command-palette")
        .onAppear { selection = ids.first; renameContext = model.state.context }
        .onChange(of: query) { _, _ in selection = ids.first }
    }

    private func matches(_ value: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { value.localizedCaseInsensitiveContains(String($0)) }
    }

    private func run(_ id: String) {
        guard model.panel == "palette", ids.contains(id), unavailableReason == nil, disabledReason(id) == nil else { return }
        switch id {
        case "Overview": model.panel = nil; model.destination = .overview
        case "New session":
            guard newSessionDisabledReason == nil else { return }
            if let path = model.selectedWorkspace {
                model.panel = nil
                Task { await model.createSession(in: path) }
            } else { model.panel = "directory" }
        case "Add workspace": model.panel = "workspace"
        case "Settings": model.panel = nil; model.destination = .settings
        case "Devices": model.panel = nil; model.destination = .devices
        case "Rename session":
            if let id = renameContext?.session { renameSession(id) }
        case "Toggle Inspector": model.panel = nil; toggleInspector()
        default:
            guard let option = MacSlashCommands.options(in: model.state).first(where: { "/" + $0.name == id }),
                  let command = option.native, option.isEnabled(in: model.state) else { return }
            _ = model.openNativeWorkflow(command, context: model.state.context)
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
