import AppKit
import PiRemoteCore
import SwiftUI

/// A native transcript, editor and footer. Pi still owns execution through RPC.
struct PiConversationView: View {
    @Bindable var model: CompanionModel
    var openControls: (String) -> Void
    @State private var showThinking = false
    @State private var expandTools = false
    @State private var following = true
    @State private var statistics: SessionStatistics?
    @State private var statisticsSequence: UInt64?
    @State private var shellOffer: PiShellOffer?
    @State private var input: PiEditorInput?
    @State private var completions: PiEditorCompletions?
    @State private var completionGeneration = UUID()
    @State private var completionError: String?

    private var contextID: String { model.state.epoch.uuidString + (model.state.selected?.uuidString ?? "none") }
    private var canCompose: Bool {
        model.state.selected != nil && !model.openingSession && model.closingSession == nil &&
        !["unavailable", "interrupted", "recovering", "starting", "stopping", "bash"].contains(model.state.phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcript
            if let shell = model.state.bash,
               shell.working || shell.status == .unknownOutcome || !model.state.messages.contains(where: {
                   $0.role == "bash" && $0.text.hasPrefix((shell.excludeFromContext ? "!! " : "! ") + shell.command + "\n")
               }) { shellOutput(shell) }
            if let count = model.state.pendingMessages, count > 0 {
                Text("\(count) queued · option+up edits queued input · esc stops and offers queued text · Stop clears it")
                    .foregroundStyle(PiPalette.warning).padding(.horizontal, 16).padding(.vertical, 4)
            }
            if let error = completionError {
                Text(error).foregroundStyle(PiPalette.warning).padding(.horizontal, 16)
                    .accessibilityIdentifier("pi-completion-error")
            }
            if !model.state.notices.isEmpty {
                ForEach(Array(model.state.notices.enumerated()), id: \.offset) { _, notice in
                    Text(notice).foregroundStyle(PiPalette.muted).textSelection(.enabled).padding(.horizontal, 16)
                }
            }
            editor
            footer
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(PiPalette.text)
        .background(PiPalette.background)
        .accessibilityIdentifier("pi-coding-surface")
        .task(id: model.state.phase + contextID) { await refreshStatistics() }
        .onChange(of: model.state.context) { _, _ in
            shellOffer = nil; completions = nil; completionError = nil
            completionGeneration = UUID(); statistics = nil; statisticsSequence = nil; following = true
        }
        .sheet(item: $shellOffer) { offer in
            VStack(alignment: .leading, spacing: 16) {
                Text("Run command on the Mac?").font(.headline)
                Text("Working directory: " + (model.state.sessions.first { $0.id == offer.context.session }?.directory ?? "Unavailable"))
                    .textSelection(.enabled)
                ScrollView { Text(offer.command).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
                Text(offer.excludeFromContext ? "!! excludes output from model context. Pi still saves the shell entry in session history." : "! includes output in model context. Pi saves the shell entry in session history.")
                Text("Commands use your Mac permissions and can change files or contact external services. Cancellation cannot undo changes.")
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { shellOffer = nil }.keyboardShortcut(.cancelAction)
                    Button("Run command") { runShell(offer) }.keyboardShortcut(.defaultAction)
                        .disabled(model.state.context != offer.context || model.state.working || model.sending)
                }
            }.padding(24).frame(width: 560)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.state.messages.isEmpty { startup }
                    if model.state.hasOlderMessages {
                        Button("Earlier messages are saved on the Mac · /history") { model.openNativeWorkflow(.history) }
                            .buttonStyle(.plain).foregroundStyle(PiPalette.muted)
                    }
                    ForEach(model.state.messages) { message in
                        PiTranscriptRow(message: message, showThinking: showThinking, expandTools: expandTools,
                                        request: model.scopedRequest(for: model.state))
                    }
                    Color.clear.frame(height: 1).id("pi-transcript-end")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { following = false }
            }
            .onChange(of: model.state.messages) { _, _ in
                if following { proxy.scrollTo("pi-transcript-end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button("↓ Latest") { following = true; proxy.scrollTo("pi-transcript-end", anchor: .bottom) }
                        .buttonStyle(.bordered).padding(12).accessibilityIdentifier("pi-follow-latest")
                }
            }
        }
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("pi ").foregroundColor(PiPalette.accent) + Text(model.state.piVersion).foregroundColor(PiPalette.muted))
            Text(model.state.selected == nil ? "Choose a folder to start Pi, or resume a saved session." : startupStatus)
            Text("enter send · shift+enter newline · tab complete · esc stop")
            Text("ctrl+l model · shift+tab thinking · ctrl+o tools · ctrl+t thinking text")
            Text("/ for commands · @ for file paths · ! / !! for reviewed shell commands")
            if model.state.selected == nil {
                HStack(spacing: 20) {
                    Button("New session…") { model.panel = "directory" }.disabled(model.startupError != nil || model.state.working)
                    Button("Resume…") { model.openNativeWorkflow(.resume) }
                }.foregroundStyle(PiPalette.accent).padding(.top, 8)
            }
            Text("Loaded resource inventory is unavailable through RPC. Use Commands to inspect discovered commands.")
                .foregroundStyle(PiPalette.muted)
        }
        .foregroundStyle(PiPalette.muted).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pi-startup")
    }

    private var startupStatus: String {
        switch model.state.phase {
        case "idle": "Ready for a task."
        case "waiting": "Pi is waiting for your answer."
        case "retrying": "Pi is retrying."
        case "compacting": "Pi is compacting context."
        case "interrupted", "unavailable": "Pi is not running. Resume explicitly; no prompt will be resent."
        case "recovering": "The outcome is uncertain. Review state before another action."
        default: "Pi is " + model.state.phase + "."
        }
    }

    private var editorRule: Color {
        if model.text.hasPrefix("!!") { return PiPalette.muted }
        if model.text.hasPrefix("!") { return PiPalette.bash }
        return PiPalette.thinking(model.state.thinking)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Rectangle().fill(editorRule).frame(height: 1)
            PiEditor(text: $model.text, contextID: contextID, isBusy: model.state.working,
                     canSubmit: canCompose && !model.sending, completions: completions, history: model.promptHistory,
                     onSubmit: submit, onStop: { if model.state.working { recoverQueue(stop: true) } },
                     onRecoverQueue: { recoverQueue(stop: $0) },
                     onCompletion: complete, onCompletionRequest: requestCompletions,
                     onDismissCompletion: { completions = nil; completionGeneration = UUID() },
                     onSelectModel: { openControls("model") }, onCycleModel: { direction in
                         if direction > 0 { perform(.cycleModel) }
                         else { openControls("model") }
                     },
                     onToggleTools: { expandTools.toggle() }, onToggleThinking: { showThinking.toggle() },
                     onCycleThinking: { perform(.cycleThinking) })
                .frame(height: completions?.options.isEmpty == false ? 240 : 100).padding(.horizontal, 8).padding(.vertical, 4)
                .accessibilityIdentifier("pi-editor")
            Rectangle().fill(editorRule).frame(height: 1)
        }
    }

    private var footer: some View {
        let value = PiFooterValue(state: model.state, statistics: statistics)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(value.directory).lineLimit(1).truncationMode(.middle).help(value.directory)
                Spacer(minLength: 8)
                Text(value.phase).foregroundStyle(model.state.working ? PiPalette.warning : PiPalette.muted)
                if model.state.working {
                    Button("Stop") { model.stopWork() }.buttonStyle(.plain).foregroundStyle(PiPalette.warning)
                        .accessibilityIdentifier("pi-stop")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { usage(value); Spacer(minLength: 8); configuration(value) }
                VStack(alignment: .leading, spacing: 3) { configuration(value); usage(value) }
            }
        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(PiPalette.muted)
            .padding(.horizontal, 16).padding(.vertical, 7).accessibilityIdentifier("pi-footer")
    }

    private func usage(_ value: PiFooterValue) -> some View {
        Text(value.usage + (statistics != nil && model.state.working ? " · last settled" : ""))
            .lineLimit(1).help(value.usage)
    }

    private func configuration(_ value: PiFooterValue) -> some View {
        HStack(spacing: 8) {
            Button(value.model) { openControls("model") }.buttonStyle(.plain).help("Select model (Control-L)")
            Button(model.state.thinking.isEmpty ? "thinking unavailable" : model.state.thinking) { openControls("thinking") }
                .buttonStyle(.plain).foregroundStyle(PiPalette.thinking(model.state.thinking))
        }
    }

    private func shellOutput(_ shell: BashExecution) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text((shell.excludeFromContext ? "!! " : "! ") + shell.command).lineLimit(2)
                Spacer()
                Text(shell.status.rawValue)
                if shell.status == .running || shell.status == .cancelling {
                    Button("Cancel command") { perform(.abortBash(id: shell.id)) }.disabled(shell.status == .cancelling)
                }
            }.foregroundStyle(PiPalette.accent)
            ScrollView([.vertical, .horizontal]) { Text(shell.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 150)
            if shell.truncated { Text("Shell output truncated at the display limit.").foregroundStyle(PiPalette.warning) }
            if let code = shell.exitCode { Text("exit \(code)") }
            if let fault = shell.fault { Text(fault.explanation).foregroundStyle(PiPalette.warning) }
        }.padding(12).background(PiPalette.panel).accessibilityIdentifier("pi-shell-output")
    }

    private func submit(_ delivery: Delivery) {
        guard canCompose, !model.sending else { return }
        let draft = model.text
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let offer = PiShellOffer.parse(draft, context: model.state.context) {
            guard !model.state.working, model.state.capabilities.contains("bash") else { model.composerError = "Wait for an idle session with shell support."; return }
            guard !offer.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { model.composerError = "Enter a command after ! or !!."; return }
            shellOffer = offer; return
        }
        if let command = PiBuiltinCommand.parse(draft), PiBuiltinCommand.all.contains(where: { $0.name == command.name }) {
            guard command.arguments.isEmpty else { model.composerError = "Use the native picker for this command; inline arguments are not supported."; return }
            guard model.state.dialogs.isEmpty else { model.composerError = "Answer or cancel the open request first."; return }
            openControls(command.name)
            return
        }
        if let command = PiBuiltinCommand.parse(draft), ["login", "logout", "trust", "reload", "llama", "share", "bug", "debug", "quit", "scoped-models"].contains(command.name) {
            model.composerError = "This terminal workflow is not available here. Use Pi on the Mac for /" + command.name + "."
            return
        }
        model.delivery = delivery
        model.send(context: model.state.context)
    }

    private func runShell(_ offer: PiShellOffer) {
        shellOffer = nil
        guard model.state.context == offer.context, !model.state.working else { model.fault = .conflict; return }
        guard !model.needsActionReview else { model.fault = .unknownOutcome; return }
        let request = model.scopedRequest(for: model.state)
        model.sending = true
        Task { @MainActor in
            defer { model.sending = false }
            do {
                _ = try await request(.bash(command: offer.command, excludeFromContext: offer.excludeFromContext, confirmed: true))
                if model.state.context == offer.context, model.text == offer.draft { model.text = "" }
            } catch { model.fault = error as? RemoteFault ?? .unavailable }
        }
    }

    private func recoverQueue(stop: Bool) {
        guard model.state.selected != nil else { return }
        if ["bash", "recovering", "stopping"].contains(model.state.phase) {
            if stop { model.stopWork() }
            return
        }
        let context = model.state.context
        let request = model.scopedRequest(for: model.state)
        Task { @MainActor in
            do {
                if case .recoveredQueue(let text) = try await request(.recoverQueue(stop: stop)), !text.isEmpty,
                   model.state.context == context {
                    if model.text.isEmpty { model.text = text }
                    else { model.editorOffer = EditorOffer(id: UUID(), session: context.session, text: text) }
                }
            } catch { model.fault = error as? RemoteFault ?? .unavailable }
        }
    }

    private func perform(_ action: SessionAction) {
        let request = model.scopedRequest(for: model.state)
        Task { do { _ = try await request(action) } catch { model.fault = error as? RemoteFault ?? .unavailable } }
    }

    private func refreshStatistics() async {
        guard model.state.phase == "idle", model.state.selected != nil,
              !model.sending, !model.openingSession, model.closingSession == nil else { return }
        let context = model.state.context
        guard statisticsSequence != model.state.sequence else { return }
        let sequence = model.state.sequence
        do {
            let value = try await model.readStatistics(for: model.state)
            if model.state.context == context {
                statistics = value; statisticsSequence = sequence
            }
        } catch { if model.state.context == context { statistics = nil } }
    }

    private func requestCompletions(_ input: PiEditorInput, explicit: Bool) {
        self.input = input; completions = nil; completionError = nil
        let generation = UUID(); completionGeneration = generation
        guard input.contextID == contextID else { return }
        // File names are not shell syntax. Do not insert unescaped names into executable drafts.
        guard !input.text.hasPrefix("!") else {
            if explicit { completionError = "Path completion is disabled in shell commands. Enter and review shell quoting explicitly." }
            return
        }
        if let token = MacSlashCommands.completion(in: input.text, selection: input.selection) {
            let builtins = PiBuiltinCommand.all.filter { $0.name.hasPrefix(token.query.lowercased()) }
            var options = builtins.map { PiEditorCompletions.Option(id: $0.name, label: "/" + $0.name, detail: $0.detail, replacement: "/" + $0.name + " ") }
            options += MacSlashCommands.matching(in: model.state, query: token.query).filter { value in !builtins.contains { $0.name == value.name } }.map {
                PiEditorCompletions.Option(id: $0.name, label: "/" + $0.name, detail: $0.disabledReason(in: model.state) ?? $0.detail,
                                          replacement: "/" + $0.name + " ")
            }
            if !options.isEmpty {
                completions = PiEditorCompletions(input: input, replacementRange: token.tokenRange, options: options)
                return
            }
        }
        guard let directory = model.state.sessions.first(where: { $0.id == model.state.selected })?.directory,
              let query = PiPathQuery.parse(text: input.text, selection: input.selection, directory: directory) else { return }
        let request = model.scopedRequest(for: model.state)
        Task { @MainActor in
            do {
                guard case .directories(var page) = try await request(.directoryAtPath(path: query.directory)) else { return }
                var items = page.items
                // At most 1,000 names per completion request; preserve cursor ownership and never read file contents.
                for _ in 0..<9 {
                    guard completionGeneration == generation, self.input == input else { return }
                    guard let cursor = page.next else { break }
                    guard case .directories(let next) = try await request(.directories(id: page.id, cursor: cursor)), next.id == page.id else { throw RemoteFault.conflict }
                    page = next; items += page.items
                }
                guard completionGeneration == generation, self.input == input, input.contextID == contextID else { return }
                let matched = items.filter {
                    $0.fault == nil && !$0.name.contains("\"") && !$0.name.contains("\\") &&
                    $0.name.rangeOfCharacter(from: .controlCharacters) == nil &&
                    (query.prefix.isEmpty || $0.name.range(of: query.prefix, options: [.anchored, .caseInsensitive]) != nil)
                }.prefix(100)
                let options = matched.map { item in
                    PiEditorCompletions.Option(id: item.id.uuidString, label: item.name + (item.isDirectory ? "/" : ""), detail: item.isDirectory ? "directory" : "path only · Files previews and attaches content",
                                              replacement: query.replacement(item))
                }
                completions = PiEditorCompletions(input: input, replacementRange: query.range, options: options)
                if page.next != nil { completionError = "More paths exist. Narrow the prefix or use Files." }
            } catch {
                guard completionGeneration == generation, self.input == input else { return }
                completionError = (error as? RemoteFault ?? .unavailable).explanation
            }
        }
    }

    private func complete(_ option: PiEditorCompletions.Option) {
        // PiEditor applies a validated edit; this callback invalidates the asynchronous batch.
        completions = nil; completionGeneration = UUID()
    }
}

private struct PiTranscriptRow: View {
    let message: TranscriptMessage
    let showThinking: Bool
    let expandTools: Bool
    let request: (SessionAction) async throws -> AppResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.role == "tool" {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Text((expanded || expandTools) ? "▾" : "▸")
                        Text(message.text.components(separatedBy: "\n").first ?? "Tool")
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Text(message.streaming ? "…" : (message.isError ? "failed" : "✓"))
                    }
                }.buttonStyle(.plain).foregroundStyle(message.isError ? PiPalette.warning : PiPalette.accent)
                if expanded || expandTools {
                    ScrollView(.horizontal) { Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                } else if message.isError {
                    Text(DisplayLimit.text(message.text.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), bytes: 512))
                        .foregroundStyle(PiPalette.warning).textSelection(.enabled)
                } else {
                    let lines = message.text.components(separatedBy: "\n")
                    if lines.first == "bash" {
                        Text(lines.dropFirst().suffix(5).joined(separator: "\n")).foregroundStyle(PiPalette.muted).textSelection(.enabled)
                        if lines.count > 6 { Text("Earlier output hidden · expand to read").foregroundStyle(PiPalette.muted) }
                    } else if lines.first != "read", lines.count > 1 {
                        Text(lines.dropFirst().prefix(10).joined(separator: "\n")).foregroundStyle(PiPalette.muted).textSelection(.enabled)
                        if lines.count > 11 { Text("More output hidden · expand to read").foregroundStyle(PiPalette.muted) }
                    }
                }
            } else if message.role == "bash" {
                Rectangle().fill(PiPalette.bash).frame(height: 1)
                let lines = message.text.components(separatedBy: "\n")
                ScrollView(.horizontal) {
                    Text(expanded ? message.text : lines.prefix(22).joined(separator: "\n"))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.count > 22 {
                    Button(expanded ? "Collapse command output" : "Expand command output") { expanded.toggle() }
                        .buttonStyle(.plain).foregroundStyle(PiPalette.muted)
                    if !expanded { Text(lines.last ?? "").foregroundStyle(PiPalette.muted) }
                }
                Rectangle().fill(PiPalette.bash).frame(height: 1)
            } else {
                if message.role == "user" {
                    Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let thinking = message.thinking, !thinking.isEmpty {
                        Text(showThinking ? thinking : "Thinking…").italic().foregroundStyle(PiPalette.muted).textSelection(.enabled)
                    }
                    PiMarkdown(text: message.text)
                }
            }
            if let images = message.images { OutputImageList(images: images, request: request) }
            if message.truncated { Text("Display limit reached. Full saved content is available through History.").foregroundStyle(PiPalette.warning) }
            if message.streaming { Text("…").foregroundStyle(PiPalette.muted).accessibilityLabel("Streaming") }
        }
        .padding(message.role == "user" || message.role == "tool" ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "tool" ? (message.isError ? PiPalette.toolError : (message.streaming ? PiPalette.toolPending : PiPalette.toolSuccess)) : (message.role == "user" ? PiPalette.panel : Color.clear))
        .foregroundStyle(message.isError ? PiPalette.warning : PiPalette.text)
        .accessibilityIdentifier("pi-message-" + message.id.uuidString)
    }
}

private struct PiMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MarkdownDocument(text).blocks) { block in
                HStack(alignment: .top, spacing: 6) {
                    if let marker = block.marker { Text(marker).foregroundStyle(PiPalette.muted) }
                    switch block.kind {
                    case .code:
                        ScrollView(.horizontal) {
                            Text(String(block.text.characters)).textSelection(.enabled).padding(8)
                        }.background(PiPalette.panel)
                    case .rule: Rectangle().fill(PiPalette.muted).frame(height: 1)
                    case .heading:
                        Text(block.text).bold().foregroundStyle(PiPalette.heading).textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                    case .table:
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                ForEach(Array(block.rows.enumerated()), id: \.offset) { _, cells in
                                    GridRow { ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in Text(cell).textSelection(.enabled) } }
                                }
                            }
                        }
                    default: Text(block.text).textSelection(.enabled)
                    }
                }.padding(.leading, CGFloat(block.indent) * 12)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}
