import PiRemoteCore
import SwiftUI

private var sessionControlMinimum: CGFloat? {
    #if os(macOS)
    nil
    #else
    44
    #endif
}

struct SessionListView: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    let newSession: () -> Void
    let selected: () -> Void
    @State private var interrupted: SessionInfo?
    @State private var error: String?
    var body: some View {
        List {
            Button("New session", systemImage: "plus", action: newSession).frame(minHeight: sessionControlMinimum).disabled(state.working)
            if state.capabilities.contains("session-lifecycle"), state.selected != nil {
                NavigationLink("New in current directory") {
                    NewManagedSessionView(state: state, request: request, created: selected)
                }.frame(minHeight: sessionControlMinimum).disabled(state.working)
            }
            if state.capabilities.contains("session-import") {
                NavigationLink("Import JSONL session") { SessionImportView(request: request, canChooseDirectory: state.capabilities.contains("session-import-directory"), canEnterPath: state.capabilities.contains("directory-path"), imported: selected) }
                    .frame(minHeight: sessionControlMinimum).disabled(state.working)
            }
            if let error { Text(error).foregroundStyle(.primary) }
            ForEach(state.sessions) { session in
                Button {
                    if session.interrupted { interrupted = session }
                    else { resume(session) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).foregroundStyle(.primary)
                        Text(session.directory).font(.caption.monospaced()).foregroundStyle(.primary.opacity(0.75)).lineLimit(2)
                        if session.interrupted { Label("Review interrupted work before continuing", systemImage: "exclamationmark.triangle").font(.caption) }
                    }.padding(.vertical, 4)
                }.disabled(state.working)
            }
        }
        .navigationTitle("Sessions")
        .confirmationDialog("Resume interrupted session?", isPresented: Binding(get: { interrupted != nil }, set: { if !$0 { interrupted = nil } })) {
            Button("Resume without resending any prompt") { if let session = interrupted { resume(session) }; interrupted = nil }
        } message: { Text("Saved messages do not prove that an interrupted tool completed. Review the transcript and project before sending another instruction.") }
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
    let preview: (FilePreview) -> Void
    @State private var confirmClose = false
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.primary) }
            if let session = state.sessions.first(where: { $0.id == state.selected }) {
                Section("Working directory") {
                    Text(session.directory).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if state.capabilities.contains("pi-release-notes") {
                Section("Installed Pi") {
                    NavigationLink("Pi release notes") { ReleaseNotesView(request: request) }.frame(minHeight: sessionControlMinimum)
                }
            }
            Section("Pi") {
                Text("Version: " + state.piVersion).font(.caption)
                Picker("Model", selection: Binding(get: { state.model }, set: { value in
                    if let model = state.models.first(where: { $0.id == value }) { perform(.model(provider: model.provider, id: model.model)) }
                })) {
                    ForEach(state.models) { model in Text(model.name).tag(model.id) }
                }
                Picker("Thinking", selection: Binding(get: { state.thinking }, set: { perform(.thinking(level: $0)) })) {
                    ForEach(state.thinkingLevels, id: \.self) { Text($0).tag($0) }
                }
                if state.capabilities.contains("model-cycling") {
                    Button("Cycle model") { perform(.cycleModel) }.frame(minHeight: sessionControlMinimum)
                    Button("Cycle thinking level") { perform(.cycleThinking) }.frame(minHeight: sessionControlMinimum)
                }
            }.disabled(state.working || state.selected == nil)
            if state.capabilities.contains("retry-controls"), state.phase == "retrying" {
                Section("Retry recovery") {
                    Text("Cancelling a retry wait does not undo tool actions or cancel every kind of active work. Use Stop to stop work and clear queued instructions.").font(.caption)
                    Button("Cancel retry wait") { perform(.abortRetry) }.frame(minHeight: sessionControlMinimum)
                        .disabled(state.selected == nil || state.phase != "retrying")
                }
            }
            if state.capabilities.contains("session-statistics") {
                Section("Usage") {
                    NavigationLink("Session tokens and cost") { SessionStatisticsView(request: request) }
                        .frame(minHeight: sessionControlMinimum).disabled(state.selected == nil)
                }
            }
            if state.capabilities.contains("last-assistant") {
                Section("Output") {
                    NavigationLink("Copy last response") { LastAssistantView(request: request) }
                        .frame(minHeight: sessionControlMinimum).disabled(state.selected == nil)
                }
            }
            if state.capabilities.contains("session-export") {
                Section("Export") {
                    NavigationLink("Review and export session") { SessionExportView(request: request, jsonlEnabled: state.capabilities.contains("session-jsonl-export")) }
                        .frame(minHeight: sessionControlMinimum).disabled(state.working || state.selected == nil)
                }
            }
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
            Section("Session") {
                if state.capabilities.contains("session-lifecycle") {
                    NavigationLink("New in current directory") {
                        NewManagedSessionView(state: state, request: request, created: closed)
                    }.frame(minHeight: sessionControlMinimum)
                }
                TextField("Session name", text: $name)
                Button("Rename") { perform(.rename(name: name)) }.disabled(name.isEmpty)
                NavigationLink("Compact context") { CompactionView(request: request) }.frame(minHeight: sessionControlMinimum)
                Button("Clone current branch") { perform(.clone) }
                if state.capabilities.contains("close-session") {
                    Button("Close Pi session", role: .destructive) { confirmClose = true }.frame(minHeight: sessionControlMinimum)
                }
                Button("Working tree diff") {
                    Task {
                        do { if case .preview(let value) = try await request(.diff) { preview(value) } }
                        catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                    }
                }
            }.disabled(state.working || state.selected == nil)
            if let pending = state.pendingMessages, pending > 0 {
                Section("Pending instructions") {
                    Text("Queued instructions: \(pending). Use Stop to clear the queue.")
                }
            }
            SessionCommandActions(state: state, request: request)
        }
        .navigationTitle("Session controls")
        .alert("Close this Pi session?", isPresented: $confirmClose) {
            Button("Close Pi session", role: .destructive) {
                Task {
                    do { _ = try await request(.closeSession); closed() }
                    catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This stops the idle Pi process, not the listener. Saved history remains on the Mac. Reopen it from Sessions; no prompt is resent.") }
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

    var body: some View {
        Form {
            SessionCommandActions(state: state, request: request)
        }
        .accessibilityIdentifier("session-commands-form")
        .navigationTitle("Commands")
    }
}

private struct SessionCommandActions: View {
    let state: HostSnapshot
    // The parent binds this closure to the session context that opened the controls.
    let request: (SessionAction) async throws -> AppResult
    @State private var arguments = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Section("Commands, skills, and templates") {
            if let error {
                Text(error).foregroundStyle(.primary)
                    .accessibilityIdentifier("session-command-error")
            }
            TextField("Command arguments", text: $arguments)
                .accessibilityIdentifier("command-arguments")
                .disabled(sending || state.selected == nil)
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
                .disabled(sending || state.selected == nil || (state.working && command.source != "extension"))
            }
            Text("Commands use Pi core RPC. A command can report that it requires a terminal.")
                .font(.caption).foregroundStyle(.primary.opacity(0.75))
        }
        .onChange(of: state.context) { _, _ in arguments = ""; error = nil }
    }

    private func perform(_ command: CommandOption) {
        guard !sending, state.selected != nil,
              !state.working || command.source == "extension" else { return }
        sending = true
        error = nil
        let action = SessionAction.command(name: command.name, arguments: arguments)
        Task { @MainActor in
            defer { sending = false }
            do {
                let result = try await request(action)
                if case .failure(let fault) = result { throw fault }
            } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
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
                Text("Starts an empty conversation in the same directory. Parent ancestry records a link to saved history; it does not copy messages or resend instructions. A parent must have a saved session file.")
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
