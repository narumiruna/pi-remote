import Observation
import PiRemoteCore
import SwiftUI

private var sessionControlMinimum: CGFloat? {
    #if os(macOS)
    nil
    #else
    44
    #endif
}

struct SpaceListView: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    let newSession: () -> Void
    let selected: () -> Void

    private var directories: [String] {
        Set(state.sessions.map(\.directory)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Button("New session", systemImage: "plus", action: newSession)
                    .frame(minHeight: sessionControlMinimum).disabled(state.working)
                if state.capabilities.contains("session-import") {
                    NavigationLink("Import JSONL session") {
                        SessionImportView(request: request, canChooseDirectory: state.capabilities.contains("session-import-directory"),
                                          canEnterPath: state.capabilities.contains("directory-path"), imported: selected)
                    }.frame(minHeight: sessionControlMinimum).disabled(state.working)
                }
            }
            Section {
                ForEach(directories, id: \.self) { directory in
                    let sessions = state.sessions.filter { $0.directory == directory }
                    NavigationLink {
                        SessionListView(state: state, directory: directory, request: request, newSession: newSession, selected: selected)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(URL(fileURLWithPath: directory).lastPathComponent.isEmpty ? directory : URL(fileURLWithPath: directory).lastPathComponent,
                                  systemImage: "folder")
                            Text(directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).frame(minHeight: sessionControlMinimum, alignment: .leading)
                    }
                    .accessibilityIdentifier("space-" + directory)
                }
                if directories.isEmpty {
                    Text("No spaces yet. Start a session in a Mac folder to add a space.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Mac folders") }
        }
        .navigationTitle("Spaces")
    }
}

private struct SessionListView: View {
    let state: HostSnapshot
    let directory: String
    let request: (SessionAction) async throws -> AppResult
    let newSession: () -> Void
    let selected: () -> Void
    @State private var interrupted: SessionInfo?
    @State private var error: String?
    private var sessions: [SessionInfo] { state.sessions.filter { $0.directory == directory } }
    private var isCurrentDirectory: Bool { sessions.contains { $0.id == state.selected } }

    var body: some View {
        List {
            Section {
                Text(directory).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if state.capabilities.contains("directory-path") {
                NavigationLink {
                    DirectoryBrowser(selecting: true, request: request, pathEntry: true, initialPath: directory) { id, _ in
                        _ = try await request(.createSession(directory: id)); selected()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("New session", systemImage: "plus")
                        Text("Review or change this folder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                    .accessibilityIdentifier("space-new-session")
                    .accessibilityLabel("New session")
                    .accessibilityHint("Review or change this folder before starting Pi.")
                    .frame(minHeight: sessionControlMinimum).disabled(state.working)
            } else {
                Button("New session", systemImage: "plus", action: newSession)
                    .frame(minHeight: sessionControlMinimum).disabled(state.working)
            }
            if state.capabilities.contains("session-lifecycle"), isCurrentDirectory {
                NavigationLink {
                    NewManagedSessionView(state: state, request: request, created: selected)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New session options")
                        Text("Current folder · Optional parent link").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("space-new-session-options")
                    .accessibilityLabel("New session options")
                    .accessibilityHint("Use the current folder with an optional parent link. Messages are not copied.")
                    .frame(minHeight: sessionControlMinimum).disabled(state.working)
            }
            if let error { Text(error).foregroundStyle(.primary) }
            ForEach(sessions) { session in
                Button {
                    if session.interrupted { interrupted = session }
                    else { resume(session) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).foregroundStyle(.primary)
                        Text(session.updated, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        if sessions.filter({ $0.title == session.title }).count > 1 {
                            Text("ID: " + session.id.uuidString.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        if session.id == state.selected { Label("Current session", systemImage: "checkmark.circle").font(.caption) }
                        if session.interrupted { Label("Review interrupted work before continuing", systemImage: "exclamationmark.triangle").font(.caption) }
                    }.padding(.vertical, 4).frame(minHeight: sessionControlMinimum, alignment: .leading)
                }.disabled(state.working)
                    .accessibilityIdentifier("session-" + session.id.uuidString)
            }
        }
        .navigationTitle("Sessions")
        .confirmationDialog("Resume interrupted session?", isPresented: Binding(get: { interrupted != nil }, set: { if !$0 { interrupted = nil } })) {
            Button("Resume without resending any prompt") { if let session = interrupted { resume(session) }; interrupted = nil }
            Button("Cancel", role: .cancel) { interrupted = nil }
        } message: { Text("Saved messages do not prove that an interrupted tool completed. Review the transcript and project before sending another prompt.") }
    }
    private func resume(_ session: SessionInfo) {
        Task {
            do { _ = try await request(.resumeSession(id: session.id)); selected() }
            catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
        }
    }
}

struct SessionControls: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    var closed: () -> Void = {}
    #if os(macOS)
    var closeSession: (() -> Void)? = nil
    var closeSessionDisabledReason: String? = nil
    @Environment(\.macInterfaceMode) private var interfaceMode
    @State private var details = false
    @State private var advanced = false
    #else
    @State private var details = false
    #endif
    let preview: (FilePreview) -> Void
    @State private var confirmClose = false
    @State private var name = ""
    @State private var error: String?
    @State private var command = SessionCommandOperation()
    var body: some View {
        Form {
            #if os(macOS)
            if interfaceMode == .desktop {
                desktopControls
            } else {
                standardControls
            }
            #else
            phoneControls
            #endif
        }
        .navigationTitle("Session controls")
        .onChange(of: state.context, initial: true) { _, context in command.align(to: context) }
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            if state.capabilities.contains("close-session") {
                HStack {
                    Spacer()
                    Button("Close Session", role: .destructive) { closeSession?() }
                        .disabled(closeSession == nil || state.selected == nil || closeSessionDisabledReason != nil)
                        .help(closeSessionDisabledReason ?? "Close Session; keep saved history and draft")
                        .accessibilityIdentifier("mac-inspector-close-session")
                }.padding(12).background(.bar)
            }
        }
        #endif
        #if !os(macOS)
        .alert("Close this Pi session?", isPresented: $confirmClose) {
            Button("Close Pi session", role: .destructive) {
                Task {
                    do { _ = try await request(.closeSession); closed() }
                    catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This stops the idle Pi process, not the listener. Saved history remains on the Mac. Reopen it from Sessions; no prompt is resent.") }
        #endif
    }
    @ViewBuilder private var standardControls: some View {
        if let error { Text(error).foregroundStyle(.primary) }
        directorySection
        if state.capabilities.contains("pi-release-notes") {
            Section("Installed Pi") {
                NavigationLink("Pi changelog") { ReleaseNotesView(request: request) }.frame(minHeight: sessionControlMinimum)
            }
        }
        Section("Pi") {
            Text("Version: " + state.piVersion).font(.caption)
            modelPicker
            thinkingPicker
            if state.capabilities.contains("model-cycling") {
                Button("Cycle model") { perform(.cycleModel) }.frame(minHeight: sessionControlMinimum)
                Button("Cycle thinking level") { perform(.cycleThinking) }.frame(minHeight: sessionControlMinimum)
            }
        }.disabled(state.working || state.selected == nil)
        retryRecovery
        usageSection
        outputSection
        exportSection
        runtimeSection
        sessionSection
        pendingSection
        SessionCommandActions(state: state, request: request, operation: command)
    }

    #if !os(macOS)
    private var phoneControls: some View {
        Group {
            Section {
                modelPicker
                thinkingPicker
                if state.capabilities.contains("model-cycling") {
                    Button("Cycle model") { perform(.cycleModel) }.frame(minHeight: sessionControlMinimum)
                    Button("Cycle thinking level") { perform(.cycleThinking) }.frame(minHeight: sessionControlMinimum)
                }
            }.disabled(state.working || state.selected == nil)
            if let error { Text(error).foregroundStyle(.primary) }
            directorySection
            retryRecovery
            usageSection
            outputSection
            exportSection
            runtimeSection
            sessionSection
            pendingSection
            SessionCommandActions(state: state, request: request, operation: command)
            Section {
                DisclosureGroup("Details", isExpanded: $details) {
                    if details {
                        Text("Version: " + state.piVersion).font(.caption)
                        if state.capabilities.contains("pi-release-notes") {
                            NavigationLink("Pi changelog") { ReleaseNotesView(request: request) }
                                .frame(minHeight: sessionControlMinimum)
                        }
                    }
                }.accessibilityIdentifier("phone-session-details")
                    .frame(minHeight: sessionControlMinimum)
            }
        }
    }
    #endif

    #if os(macOS)
    private var desktopControls: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                    modelPicker.labelsHidden()
                        .accessibilityIdentifier("mac-session-model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thinking level")
                    thinkingPicker.labelsHidden()
                        .accessibilityIdentifier("mac-session-thinking")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.disabled(state.working || state.selected == nil)
            if let error { Text(error).foregroundStyle(.primary) }
            if !advanced {
                if command.sending {
                    ProgressView("Command in progress").controlSize(.small)
                        .accessibilityIdentifier("session-command-pending")
                }
                if let error = command.error {
                    Text(error).foregroundStyle(.primary)
                        .accessibilityIdentifier("session-command-error")
                }
            }
            retryRecovery
            directorySection
            usageSection
            outputSection
            pendingSection
            Section {
                DisclosureGroup("Details", isExpanded: $details) { EmptyView() }
                    .accessibilityIdentifier("mac-session-details")
                if details { MacDesktopSessionResources(state: state) }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) { EmptyView() }
                    .accessibilityIdentifier("mac-session-advanced")
            }
            // Keep sections at Form level so grouped rows and child AX identities
            // do not inherit the disclosure header's layout or identifier.
            if advanced {
                exportSection
                runtimeSection
                sessionSection
                SessionCommandActions(state: state, request: request, operation: command)
            }
        }
    }
    #endif

    private var modelPicker: some View {
        Picker("Model", selection: Binding(get: { state.model }, set: { value in
            if let model = state.models.first(where: { $0.id == value }) { perform(.model(provider: model.provider, id: model.model)) }
        })) {
            ForEach(state.models) { model in Text(model.name).tag(model.id) }
        }
    }

    private var thinkingPicker: some View {
        Picker("Thinking level", selection: Binding(get: { state.thinking }, set: { perform(.thinking(level: $0)) })) {
            ForEach(state.thinkingLevels, id: \.self) { Text($0).tag($0) }
        }
    }

    @ViewBuilder private var directorySection: some View {
        if let session = state.sessions.first(where: { $0.id == state.selected }) {
            Section("Working directory") {
                Text(session.directory).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var retryRecovery: some View {
        if state.capabilities.contains("retry-controls"), state.phase == "retrying" {
            Section("Retry recovery") {
                Text("Cancelling a retry wait does not undo tool actions or cancel every kind of active work. Use Stop to stop work and clear queued messages.").font(.caption)
                Button("Cancel retry wait") { perform(.abortRetry) }.frame(minHeight: sessionControlMinimum)
                    .disabled(state.selected == nil || state.phase != "retrying")
            }
        }
    }

    @ViewBuilder private var usageSection: some View {
        if state.capabilities.contains("session-statistics") {
            Section("Usage") {
                NavigationLink("Session tokens and cost") { SessionStatisticsView(request: request) }
                    .frame(minHeight: sessionControlMinimum).disabled(state.selected == nil)
            }
        }
    }

    @ViewBuilder private var outputSection: some View {
        if state.capabilities.contains("last-assistant") {
            Section("Output") {
                NavigationLink("Copy last assistant message") { LastAssistantView(request: request) }
                    .frame(minHeight: sessionControlMinimum).disabled(state.selected == nil)
            }
        }
    }

    @ViewBuilder private var exportSection: some View {
        if state.capabilities.contains("session-export") {
            Section("Export") {
                NavigationLink("Review and export session") { SessionExportView(request: request, jsonlEnabled: state.capabilities.contains("session-jsonl-export")) }
                    .frame(minHeight: sessionControlMinimum).disabled(state.working || state.selected == nil)
            }
        }
    }

    @ViewBuilder private var runtimeSection: some View {
        if state.capabilities.contains("runtime-settings"), state.runtime != nil {
            Section("Runtime") {
                NavigationLink("Pi runtime settings") { RuntimeSettingsView(request: request) }
                    .frame(minHeight: sessionControlMinimum).disabled(state.working || state.selected == nil)
                if state.capabilities.contains("retry-controls") {
                    NavigationLink("Automatic retry controls") { RetrySettingsView(request: request) }
                        .frame(minHeight: sessionControlMinimum).disabled(state.working || state.selected == nil)
                }
            }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            if state.capabilities.contains("session-lifecycle") {
                NavigationLink("New in current directory") {
                    NewManagedSessionView(state: state, request: request, created: closed)
                }.frame(minHeight: sessionControlMinimum)
            }
            TextField("Session name", text: $name)
            Button("Rename") { perform(.rename(name: name)) }.disabled(name.isEmpty)
            NavigationLink("Compact context") { CompactionView(request: request) }.frame(minHeight: sessionControlMinimum)
            Button("Clone session") { perform(.clone) }
            #if !os(macOS)
            if state.capabilities.contains("close-session") {
                Button("Close Pi session", role: .destructive) { confirmClose = true }.frame(minHeight: sessionControlMinimum)
            }
            #endif
            Button("Working tree diff") {
                Task {
                    do { if case .preview(let value) = try await request(.diff) { preview(value) } }
                    catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                }
            }
        }.disabled(state.working || state.selected == nil)
    }

    @ViewBuilder private var pendingSection: some View {
        if let pending = state.pendingMessages, pending > 0 {
            Section("Pending messages") {
                Text("Queued messages: \(pending). Use Stop to clear the queue.")
            }
        }
    }

    private func perform(_ action: SessionAction) {
        Task {
            do { _ = try await request(action) }
            catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
        }
    }
}

struct SessionCommandsView: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    @State private var command = SessionCommandOperation()

    var body: some View {
        Form {
            SessionCommandActions(state: state, request: request, operation: command)
        }
        .accessibilityIdentifier("session-commands-form")
        .navigationTitle("Commands")
        .onChange(of: state.context, initial: true) { _, context in command.align(to: context) }
    }
}

/// The parent owns pending command input and results across disclosure changes.
@Observable @MainActor private final class SessionCommandOperation {
    var arguments = ""
    var sending = false
    var error: String?
    private var context: SessionContext?
    private(set) var generation = UUID()

    func align(to context: SessionContext) {
        guard self.context != context else { return }
        self.context = context
        generation = UUID()
        arguments = ""; sending = false; error = nil
    }
}

private struct SessionCommandActions: View {
    let state: HostSnapshot
    // The parent binds this closure to the session context that opened the controls.
    let request: (SessionAction) async throws -> AppResult
    @Bindable var operation: SessionCommandOperation

    var body: some View {
        Section("Commands, skills, and prompt templates") {
            if let error = operation.error {
                Text(error).foregroundStyle(.primary)
                    .accessibilityIdentifier("session-command-error")
            }
            TextField("Command arguments", text: $operation.arguments)
                .accessibilityIdentifier("command-arguments")
                .disabled(operation.sending || state.selected == nil)
            if state.commands.isEmpty {
                Text("No commands are available for this session.")
                    .accessibilityIdentifier("session-commands-empty")
            }
            ForEach(state.commands) { command in
                Button { perform(command) } label: {
                    VStack(alignment: .leading) {
                        Text("/" + command.name)
                        Text(command.detail).font(.caption).foregroundStyle(.primary.opacity(0.75))
                    }.frame(minHeight: sessionControlMinimum)
                }
                .accessibilityIdentifier("session-command-" + command.id)
                .disabled(operation.sending || state.selected == nil || (state.working && command.source != "extension"))
            }
            Text("Some commands require Pi's terminal UI and cannot run here.")
                .font(.caption).foregroundStyle(.primary.opacity(0.75))
        }
    }

    private func perform(_ command: CommandOption) {
        operation.align(to: state.context)
        guard !operation.sending, state.selected != nil,
              !state.working || command.source == "extension" else { return }
        operation.sending = true
        operation.error = nil
        let generation = operation.generation
        let action = SessionAction.command(name: command.name, arguments: operation.arguments)
        Task { @MainActor in
            defer { if operation.generation == generation { operation.sending = false } }
            do {
                let result = try await request(action)
                if case .failure(let fault) = result { throw fault }
            } catch {
                if operation.generation == generation { operation.error = (error as? RemoteFault ?? .unavailable).explanation }
            }
        }
    }
}

struct NewManagedSessionView: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    let created: () -> Void
    @State private var parent = false
    @State private var confirm = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Form {
            if let session = state.sessions.first(where: { $0.id == state.selected }) {
                Section("Working directory") { Text(session.directory).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section("New session") {
                Toggle("Record current session as parent", isOn: $parent)
                    .accessibilityIdentifier("new-session-parent")
                Text("Starts an empty conversation in the same directory. Parent ancestry records a link to saved history; it does not copy messages or resend prompts. A parent must have a saved session file.")
                    .font(.caption)
            }.disabled(sending || state.working || state.selected == nil)
            if let error { Text(error).foregroundStyle(.primary) }
        }
        .accessibilityIdentifier("new-session-form")
        .navigationTitle("New session")
        .safeAreaInset(edge: .bottom) {
            Button { confirm = true } label: {
                Text("Review new session").frame(maxWidth: .infinity, minHeight: sessionControlMinimum)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("new-session-review")
            .disabled(sending || state.working || state.selected == nil)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
        }
        .alert("Start an empty session?", isPresented: $confirm) {
            Button("Start new session") {
                sending = true
                Task {
                    defer { sending = false }
                    do {
                        let result = try await request(.newSession(parent: parent))
                        if case .failure(let fault) = result { throw fault }
                        created()
                    } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(parent ? "The new session will record the current saved session as its parent. No messages are copied." : "The current session remains in Sessions. No messages are copied or sent.") }
        .onChange(of: state.context) { _, _ in confirm = false; parent = false }
    }
}

struct HistoryView: View {
    let request: (SessionAction) async throws -> AppResult
    var paged = false
    let forked: () -> Void
    @State private var page = HistoryPage(items: [], next: nil)
    @State private var newer: [HistoryPage] = []
    @State private var error: String?
    @State private var loading = false
    @State private var preview: FilePreview?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.primary) }
            NavigationLink("Session tree and fork options") { SessionTreeView(request: request, forked: forked) }
                .accessibilityIdentifier("session-tree-link")
            Text("File history includes compacted entries and abandoned branches. Open the session tree for labels, the active leaf and Pi's current fork options.")
                .font(.caption).foregroundStyle(.primary.opacity(0.75))
            if loading { ProgressView("Loading history") }
            if !newer.isEmpty { Button("Newer entries") { page = newer.removeLast() }.frame(minHeight: sessionControlMinimum).disabled(loading) }
            Button("Reload newest entries") { Task { newer = []; await load(nil) } }.frame(minHeight: sessionControlMinimum).disabled(loading)
            ForEach(page.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.kind + " · " + item.id).font(.caption.monospaced()).foregroundStyle(.primary.opacity(0.75))
                    if let parent = item.parent { Text("Parent: " + parent).font(.caption2.monospaced()).foregroundStyle(.primary.opacity(0.75)) }
                    Text(item.text).textSelection(.enabled)
                    if let id = item.preview {
                        Button("Read entry") {
                            Task {
                                do { if case .preview(let value) = try await request(.historyEntry(id: id)) { preview = value } }
                                catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                            }
                        }.frame(minHeight: sessionControlMinimum)
                    }
                    if item.canFork {
                        Button("Fork from this message") {
                            Task {
                                do { _ = try await request(.fork(entry: item.id)); forked() }
                                catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                            }
                        }.frame(minHeight: sessionControlMinimum)
                    }
                }.padding(.vertical, 4)
            }
            if let next = page.next { Button("Older entries") { Task { await load(next) } }.frame(minHeight: sessionControlMinimum).disabled(loading) }
        }
        .navigationTitle("History")
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
            if paged, case .historyPage(let value) = try await request(.historyPage(cursor: cursor)) {
                if cursor != nil { newer.append(page); newer = Array(newer.suffix(8)) }
                page = value
            } else if !paged, case .history(let values) = try await request(.history) {
                page = HistoryPage(items: values.reversed(), next: nil)
            }
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
