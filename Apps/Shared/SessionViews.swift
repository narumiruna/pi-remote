import PiRemoteCore
import SwiftUI

struct SessionListView: View {
    let state: HostSnapshot
    let request: (SessionAction) async throws -> AppResult
    let newSession: () -> Void
    let selected: () -> Void
    @State private var interrupted: SessionInfo?
    @State private var error: String?
    var body: some View {
        List {
            Button("New session", systemImage: "plus", action: newSession).frame(minHeight: 44).disabled(state.working)
            if state.capabilities.contains("session-import") {
                NavigationLink("Import JSONL session") { SessionImportView(request: request, canChooseDirectory: state.capabilities.contains("session-import-directory"), imported: selected) }
                    .frame(minHeight: 44).disabled(state.working)
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
    @State private var arguments = ""
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
                    NavigationLink("Pi release notes") { ReleaseNotesView(request: request) }.frame(minHeight: 44)
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
                    Button("Cycle model") { perform(.cycleModel) }.frame(minHeight: 44)
                    Button("Cycle thinking level") { perform(.cycleThinking) }.frame(minHeight: 44)
                }
            }.disabled(state.working || state.selected == nil)
            if state.capabilities.contains("retry-controls"), state.phase == "retrying" {
                Section("Retry recovery") {
                    Text("Cancelling a retry wait does not undo tool actions or cancel every kind of active work. Use Stop to stop work and clear queued instructions.").font(.caption)
                    Button("Cancel retry wait") { perform(.abortRetry) }.frame(minHeight: 44)
                        .disabled(state.selected == nil || state.phase != "retrying")
                }
            }
            if state.capabilities.contains("session-statistics") {
                Section("Usage") {
                    NavigationLink("Session tokens and cost") { SessionStatisticsView(request: request) }
                        .frame(minHeight: 44).disabled(state.selected == nil)
                }
            }
            if state.capabilities.contains("last-assistant") {
                Section("Output") {
                    NavigationLink("Copy last response") { LastAssistantView(request: request) }
                        .frame(minHeight: 44).disabled(state.selected == nil)
                }
            }
            if state.capabilities.contains("session-export") {
                Section("Export") {
                    NavigationLink("Review and export session") { SessionExportView(request: request, jsonlEnabled: state.capabilities.contains("session-jsonl-export")) }
                        .frame(minHeight: 44).disabled(state.working || state.selected == nil)
                }
            }
            if state.capabilities.contains("runtime-settings"), state.runtime != nil {
                Section("Runtime") {
                    NavigationLink("Pi runtime settings") { RuntimeSettingsView(request: request) }
                        .frame(minHeight: 44).disabled(state.working || state.selected == nil)
                    if state.capabilities.contains("retry-controls") {
                        NavigationLink("Automatic retry controls") { RetrySettingsView(request: request) }
                            .frame(minHeight: 44).disabled(state.working || state.selected == nil)
                    }
                }
            }
            Section("Session") {
                TextField("Session name", text: $name)
                Button("Rename") { perform(.rename(name: name)) }.disabled(name.isEmpty)
                Button("Compact context") { perform(.compact(instructions: "")) }
                Button("Clone current branch") { perform(.clone) }
                if state.capabilities.contains("close-session") {
                    Button("Close Pi session", role: .destructive) { confirmClose = true }.frame(minHeight: 44)
                }
                Button("Working tree diff") {
                    Task {
                        do { if case .preview(let value) = try await request(.diff) { preview(value) } }
                        catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                    }
                }
            }.disabled(state.working || state.selected == nil)
            Section("Commands, skills, and templates") {
                TextField("Command arguments", text: $arguments)
                ForEach(state.commands) { command in
                    Button { perform(.command(name: command.name, arguments: arguments)) } label: {
                        VStack(alignment: .leading) {
                            Text("/" + command.name)
                            Text(command.detail).font(.caption).foregroundStyle(.primary.opacity(0.75))
                        }
                    }
                }
                Text("Terminal-only extension interfaces require native adapters; full compatibility is not yet verified.")
                    .font(.caption).foregroundStyle(.primary.opacity(0.75))
            }.disabled(state.working || state.selected == nil)
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
            Text("Includes compacted history and abandoned branches. Fork is available only for user messages on the active branch; it does not switch an abandoned branch.")
                .font(.caption).foregroundStyle(.primary.opacity(0.75))
            if loading { ProgressView("Loading history") }
            if !newer.isEmpty { Button("Newer entries") { page = newer.removeLast() }.frame(minHeight: 44).disabled(loading) }
            Button("Reload newest entries") { Task { newer = []; await load(nil) } }.frame(minHeight: 44).disabled(loading)
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
                        }.frame(minHeight: 44)
                    }
                    if item.canFork {
                        Button("Fork from this message") {
                            Task {
                                do { _ = try await request(.fork(entry: item.id)); forked() }
                                catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
                            }
                        }.frame(minHeight: 44)
                    }
                }.padding(.vertical, 4)
            }
            if let next = page.next { Button("Older entries") { Task { await load(next) } }.frame(minHeight: 44).disabled(loading) }
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
