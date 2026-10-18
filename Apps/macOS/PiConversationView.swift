import AppKit
import PiRemoteCore
import SwiftUI

/// A native transcript, editor and footer. Pi still owns execution through RPC.
struct PiConversationView: View {
    @Bindable var model: CompanionModel
    var openControls: (String) -> Bool
    @State private var showThinking = false
    @State private var expandTools = false
    @State private var showActivity = false
    @State private var scrollFollowing = PiScrollFollowing()
    @State private var statistics: SessionStatistics?
    @State private var statisticsSequence: UInt64?
    @State private var shellOffer: PiShellOffer?
    @State private var input: PiEditorInput?
    @State private var completions: PiEditorCompletions?
    @State private var completionGeneration = UUID()
    @State private var completionError: String?
    @State private var viewportHeight: CGFloat = 1
    @State private var historyHeight: CGFloat = 1
    @State private var naturalDockHeight: CGFloat = 1
    @State private var flowDockY: CGFloat = 0
    @State private var scrollTargets = PiConversationScrollTargets()
    @State private var showResources = false
    @State private var disclosure: ToolDisclosureRequest?

    private struct ToolDisclosureRequest {
        let id = UUID()
        let message: UUID
        let viewportY: CGFloat
        let context: String
    }

    private var isDesktop: Bool { model.interfaceMode == .desktop }
    private var theme: MacInterfaceTheme { MacInterfaceTheme(mode: model.interfaceMode) }
    private var selectedSession: SessionInfo? { model.state.sessions.first { $0.id == model.state.selected } }

    private var contextID: String { model.state.epoch.uuidString + (model.state.selected?.uuidString ?? "none") }
    private var canCompose: Bool {
        model.state.selected != nil && !model.openingSession && model.closingSession == nil &&
        !["unavailable", "interrupted", "recovering", "starting", "stopping", "bash"].contains(model.state.phase)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isDesktop {
                MacDesktopHeader(title: selectedSession.map { model.displayName(for: $0) } ?? "Pi Remote",
                                 directory: selectedSession?.directory, phase: model.state.phase,
                                 hasSession: model.state.selected != nil, openSession: { _ = openControls("session") })
            }
            surface
        }
        .font(isDesktop ? .system(size: 15) : .system(size: 13, design: .monospaced))
        .foregroundStyle(theme.text)
        .background(theme.background)
        .environment(\.macInterfaceMode, model.interfaceMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pi conversation")
        .accessibilityIdentifier("pi-coding-surface")
        .task(id: model.state.phase + contextID) { await refreshStatistics() }
        .onChange(of: model.state.context) { _, _ in
            shellOffer = nil; completions = nil; completionError = nil; disclosure = nil
            completionGeneration = UUID(); statistics = nil; statisticsSequence = nil; scrollFollowing.reset(); showActivity = false
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

    private var layout: PiConversationLayout {
        PiConversationLayout(isDesktop: isDesktop, viewportHeight: viewportHeight,
                             naturalDockHeight: naturalDockHeight, flowDockY: flowDockY)
    }

    private var surface: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                history(proxy: proxy)
                    .frame(height: isDesktop ? max(1, viewportHeight - layout.dockHeight) : viewportHeight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { historyHeight = max(1, $0) }
                // This owner never changes. Only its frame and offset change between modes.
                composerDock
                    .offset(y: layout.dockY)
                    .allowsHitTesting(layout.dockIntersectsViewport)
                    .accessibilityHidden(!layout.dockIntersectsViewport)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: "pi-conversation-root")
            .background(PiConversationWheelBridge(isDesktop: isDesktop, targets: scrollTargets))
            .contentShape(Rectangle())
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = max(1, $0) }
            .overlay(alignment: .bottomTrailing) {
                if !scrollFollowing.isFollowing {
                    Button("↓ Latest") { scrollFollowing.resume(); proxy.scrollTo("pi-surface-end", anchor: .bottom) }
                        .buttonStyle(.bordered).padding(12)
                        .padding(.bottom, isDesktop ? layout.dockHeight : 0)
                        .accessibilityIdentifier("pi-follow-latest")
                }
            }
            .onChange(of: layout.dockHeight) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
        }
    }

    private var composerDock: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                widgets(at: .aboveEditor)
                editor.padding(.top, 16)
                widgets(at: .belowEditor)
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalDockHeight = max(1, $0) }
            .background(PiConversationScrollProbe(targets: scrollTargets, isHistory: false))
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: layout.dockHeight)
        .background(theme.background)
        .frame(maxWidth: isDesktop ? 880 : .infinity)
        .padding(.horizontal, isDesktop ? 20 : 0)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("pi-composer-dock")
    }

    private func history(proxy: ScrollViewProxy) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    transcript { message, viewportY in
                        scrollFollowing.pause()
                        disclosure = ToolDisclosureRequest(message: message, viewportY: viewportY, context: contextID)
                    }.padding(.horizontal, 12).padding(.top, 8)
                    if let shell = model.state.bash,
                       shell.working || shell.status == .unknownOutcome || !model.state.messages.contains(where: {
                           $0.role == "bash" && $0.text.hasPrefix((shell.excludeFromContext ? "!! " : "! ") + shell.command + "\n")
                       }) { shellOutput(shell).padding(.top, 12) }
                    if let count = model.state.pendingMessages, count > 0 {
                        Text("\(count) queued · option+up edits queued input · esc stops and offers queued text · Stop clears it")
                            .foregroundStyle(theme.warning).padding(.horizontal, 12).padding(.top, 12)
                    }
                    if let error = completionError {
                        Text(error).foregroundStyle(theme.warning).padding(.horizontal, 12)
                            .accessibilityIdentifier("pi-completion-error")
                    }
                    if !diagnosticNotices.isEmpty { activity.padding(.horizontal, 12).padding(.top, 12) }
                    ForEach(importantNotices) { notice in
                        Text((notice.severity == .error ? "Error: " : "Warning: ") + DisplayLimit.text(notice.text, bytes: 512))
                            .lineLimit(3).textSelection(.enabled)
                            .foregroundStyle(theme.warning).help(notice.text)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
                    }
                    // Measure the placeholder, not the offset dock, to avoid geometry feedback.
                    Color.clear.frame(height: isDesktop ? 0 : layout.dockHeight)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.frame(in: .named("pi-conversation-root")).minY
                        } action: { flowDockY = $0 }
                    Color.clear.frame(height: 1).id("pi-surface-end")
                }.frame(maxWidth: isDesktop ? 880 : .infinity, alignment: .leading)
                    .padding(.horizontal, isDesktop ? 20 : 0)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, isDesktop ? 16 : 0)
                    .padding(.bottom, 8)
                    .background(PiConversationScrollProbe(targets: scrollTargets, isHistory: true))
            }
            .accessibilityIdentifier("pi-history-scroll")
            .coordinateSpace(name: "pi-surface-viewport")
            .task(id: disclosure?.id) {
                guard let request = disclosure else { return }
                await Task.yield()
                guard !Task.isCancelled, request.context == contextID else { return }
                let anchor = UnitPoint(x: 0, y: min(1, max(0, request.viewportY / historyHeight)))
                proxy.scrollTo("pi-tool-anchor-" + request.message.uuidString, anchor: anchor)
            }
            .onChange(of: model.interfaceMode) { _, _ in
                disclosure = nil
                // Keep reading intent. The same native editor and session stay mounted.
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .task(id: contextID) {
                await Task.yield()
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, atBottom in
                scrollFollowing.geometryChanged(atBottom: atBottom)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating { disclosure = nil }
                scrollFollowing.phaseChanged(phase)
            }
            .onChange(of: expandTools) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .onChange(of: model.state.messages) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .onChange(of: model.text) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .onChange(of: model.state.extensionDisplay) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .onChange(of: model.state.commands) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
            .onChange(of: completions?.options.count) { _, _ in
                if scrollFollowing.isFollowing { proxy.scrollTo("pi-surface-end", anchor: .bottom) }
            }
    }

    private func transcript(onDisclosure: @escaping (UUID, CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if isDesktop {
                if model.state.messages.isEmpty {
                    MacDesktopWelcome(hasSession: model.state.selected != nil,
                                      canStart: !model.state.working && model.startupError == nil && !model.openingSession,
                                      newSession: { model.panel = "directory" },
                                      resume: { model.openNativeWorkflow(.resume) },
                                      openFiles: { _ = openControls("files") },
                                      openCommands: { _ = openControls("commands") })
                        .frame(maxWidth: .infinity, minHeight: max(220, viewportHeight - 230))
                }
                if model.state.selected != nil { desktopResources }
            } else {
                PiStartupView(state: model.state, expanded: expandTools,
                              newSession: { if !model.state.working, model.startupError == nil { model.panel = "directory" } },
                              resume: { model.openNativeWorkflow(.resume) })
                    .padding(.bottom, 12)
            }
            if ["starting", "waiting", "retrying", "compacting", "interrupted", "unavailable", "recovering"].contains(model.state.phase) {
                Text(startupStatus).foregroundStyle(theme.muted)
            }
            if model.state.hasOlderMessages {
                Button("Earlier messages are saved on the Mac · /history") { model.openNativeWorkflow(.history) }
                    .buttonStyle(.plain).foregroundStyle(theme.muted)
            }
            ForEach(model.state.messages) { message in
                PiTranscriptRow(message: message, showThinking: showThinking, expandTools: expandTools,
                                request: model.scopedRequest(for: model.state), onDisclosure: onDisclosure, runtimePhase: model.state.phase)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var desktopResources: some View {
        DisclosureGroup(isExpanded: $showResources) {
            VStack(alignment: .leading, spacing: 10) {
                resourceLine("Context", value: "Loaded context paths are not reported by Pi RPC.")
                resourceLine("Skills", value: PiStartupResources.names(source: "skill", commands: model.state.commands).joined(separator: ", "))
                resourceLine("Prompts", value: PiStartupResources.names(source: "prompt", commands: model.state.commands).joined(separator: ", "))
            }.padding(.vertical, 10)
        } label: {
            Label("Session resources", systemImage: "books.vertical").foregroundStyle(theme.muted)
        }.font(.system(size: 12)).padding(.horizontal, 4)
            .accessibilityIdentifier("desktop-session-resources")
    }

    private func resourceLine(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(theme.muted)
            Text(value.isEmpty ? "No entries reported by Pi." : value)
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticNotices: [String] {
        model.state.extensionDisplay?.notices.map(\.text) ?? model.state.notices
    }

    private var importantNotices: [ExtensionNotice] {
        (model.state.extensionDisplay?.notices ?? []).filter { $0.severity != .info }
    }

    @ViewBuilder private func widgets(at placement: ExtensionWidgetPlacement) -> some View {
        let items = (model.state.extensionDisplay?.widgets ?? []).filter { $0.placement == placement }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { widget in
                    Text(widget.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("pi-widget-" + widget.id)
                }
            }.padding(.horizontal, 12).padding(.top, 12)
        }
    }

    private var activity: some View {
        DisclosureGroup(isExpanded: $showActivity) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnosticNotices.enumerated()), id: \.offset) { _, notice in
                        Text(notice).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 160)
        } label: {
            Text("Activity · \(diagnosticNotices.count) notices").textSelection(.enabled)
        }.foregroundStyle(theme.muted)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Activity · \(diagnosticNotices.count) notices")
            .accessibilityIdentifier("pi-activity")
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

    private var editorHint: String {
        if model.state.selected == nil { return "Choose or resume a session" }
        return model.state.working ? "Enter to steer · ⌥Enter follow-up" : "Enter to send · ⇧Enter new line"
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if isDesktop {
                HStack {
                    Text("Message Pi").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if model.state.working {
                        Label(model.state.phase.capitalized, systemImage: "circle.dotted")
                            .font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            } else if model.state.working {
                HStack(spacing: 6) {
                    Rectangle().fill(editorRule).frame(width: 20, height: 1)
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    Text(model.state.phase == "bash" ? "Running command" : model.state.phase.capitalized)
                        .foregroundStyle(editorRule).font(.system(size: 13, design: .monospaced))
                    Rectangle().fill(editorRule).frame(height: 1)
                }.frame(height: 18)
            } else { Rectangle().fill(editorRule).frame(height: 1) }
            PiEditor(text: $model.text, contextID: contextID, isBusy: model.state.working,
                     canSubmit: canCompose && !model.sending, completions: completions, history: model.promptHistory,
                     onSubmit: submit, onStop: { if model.state.working { recoverQueue(stop: true) } },
                     onRecoverQueue: { recoverQueue(stop: $0) },
                     onCompletion: complete, onCompletionRequest: requestCompletions,
                     onDismissCompletion: { completions = nil; completionGeneration = UUID() },
                     onSelectModel: { _ = openControls("model") }, onCycleModel: { direction in
                         if direction > 0 { perform(.cycleModel) }
                         else { _ = openControls("model") }
                     },
                     onToggleTools: { expandTools.toggle(); if isDesktop { showResources = expandTools } },
                     onToggleThinking: { showThinking.toggle() },
                     onCycleThinking: { perform(.cycleThinking) }, separatorColor: NSColor(editorRule), interfaceMode: model.interfaceMode)
                .disabled(model.state.selected == nil)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
                .accessibilityIdentifier("pi-editor")
                .accessibilityHint(editorHint)
            if !isDesktop, model.state.selected == nil {
                Text(editorHint).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
                    .accessibilityIdentifier("pi-editor-hint")
            }
            if isDesktop {
                HStack(spacing: 12) {
                    Button { _ = openControls("commands") } label: { Label("Commands", systemImage: "slash.circle") }
                        .buttonStyle(.plain).foregroundStyle(theme.muted).font(.system(size: 12))
                        .accessibilityIdentifier("desktop-commands")
                    Spacer(minLength: 4)
                    Text(editorHint)
                        .font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1)
                        .accessibilityIdentifier("pi-editor-hint")
                    Button { submit(model.state.working ? .steer : .prompt) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!canCompose || model.sending || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(model.state.working ? "Send steering" : "Send prompt")
                        .accessibilityIdentifier("desktop-send")
                }.padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 12)
            }
        }
        .background(isDesktop ? theme.panel : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: isDesktop ? 16 : 0))
        .overlay {
            if isDesktop { RoundedRectangle(cornerRadius: 16).stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1) }
        }
    }

    private var footer: some View {
        let value = PiFooterValue(state: model.state, statistics: statistics)
        return VStack(alignment: .leading, spacing: isDesktop ? 6 : 3) {
            if !isDesktop {
                HStack {
                    Text(value.directory).lineLimit(1).truncationMode(.middle).help(value.directory).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(value.phase).foregroundStyle(model.state.working ? theme.warning : theme.muted).textSelection(.enabled)
                    if model.state.working { stopButton }
                }
            }
            HStack {
                if isDesktop, model.state.selected == nil {
                    Label("Pi runs on this Mac", systemImage: "desktopcomputer")
                    Spacer(minLength: 8)
                    Text("No session loaded")
                } else {
                    usage(value)
                    Spacer(minLength: 8)
                    configuration(value).layoutPriority(1)
                    if isDesktop, model.state.working { stopButton }
                }
            }
            if let display = model.state.extensionDisplay, !display.statuses.isEmpty {
                let text = display.statuses.map(\.text).joined(separator: " · ")
                Text(text).lineLimit(1).truncationMode(.tail).textSelection(.enabled).help(text)
                    .accessibilityIdentifier("pi-extension-status")
            }
        }.font(isDesktop ? .system(size: 12) : .system(size: 13, design: .monospaced)).foregroundStyle(theme.muted)
            .padding(.horizontal, 16).padding(.vertical, isDesktop ? 10 : 7).accessibilityIdentifier("pi-footer")
    }

    private var stopButton: some View {
        Button("Stop") { model.stopWork() }.buttonStyle(.plain).foregroundStyle(theme.warning)
            .accessibilityIdentifier("pi-stop")
    }

    private func usage(_ value: PiFooterValue) -> some View {
        Text(value.usage + (statistics != nil && model.state.working ? " · last settled" : ""))
            .lineLimit(1).help(value.usage).textSelection(.enabled)
    }

    private func configuration(_ value: PiFooterValue) -> some View {
        HStack(spacing: 8) {
            PiFooterAction(title: value.model, color: theme.nativeMuted, identifier: "pi-model-selector") { _ = openControls("model") }
                .help("Select model (Control-L): " + value.model)
            Text("·")
            PiFooterAction(title: model.state.thinking.isEmpty ? "thinking unavailable" : model.state.thinking,
                           color: isDesktop ? theme.nativeMuted : NSColor(PiPalette.thinking(model.state.thinking)), identifier: "pi-thinking-selector") { _ = openControls("thinking") }
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
            }.foregroundStyle(theme.accent)
            ScrollView([.vertical, .horizontal]) { Text(shell.output).font(.system(size: isDesktop ? 12 : 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 150)
            if shell.truncated { Text("Shell output truncated at the display limit.").foregroundStyle(theme.warning) }
            if let code = shell.exitCode { Text("exit \(code)") }
            if let fault = shell.fault { Text(fault.explanation).foregroundStyle(theme.warning) }
        }.padding(12).background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: isDesktop ? 12 : 0))
            .accessibilityIdentifier("pi-shell-output")
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
            let context = model.state.context
            if openControls(command.name), model.state.context == context, model.text == draft {
                model.text = ""
                model.composerError = nil
            }
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

/// Dock geometry is independent of history content and native editor ownership.
struct PiConversationLayout {
    let isDesktop: Bool
    let viewportHeight: CGFloat
    let naturalDockHeight: CGFloat
    let flowDockY: CGFloat

    // Leave history space and make oversized extension/editor content scrollable in the dock.
    var dockHeight: CGFloat { min(max(1, naturalDockHeight), max(1, viewportHeight * 0.75)) }
    var dockY: CGFloat { isDesktop ? max(0, viewportHeight - dockHeight) : flowDockY }
    var dockIntersectsViewport: Bool { dockY < viewportHeight && dockY + dockHeight > 0 }
}

@MainActor final class PiConversationScrollTargets {
    weak var history: NSScrollView?
    weak var dock: NSScrollView?
}

/// Each probe is inside its scroll content, so no window-wide scroll-view search is needed.
private struct PiConversationScrollProbe: NSViewRepresentable {
    let targets: PiConversationScrollTargets
    let isHistory: Bool

    func makeNSView(context: Context) -> Probe { Probe(targets: targets, isHistory: isHistory) }
    func updateNSView(_ view: Probe, context: Context) { view.register() }

    final class Probe: NSView {
        let targets: PiConversationScrollTargets
        let isHistory: Bool
        init(targets: PiConversationScrollTargets, isHistory: Bool) {
            self.targets = targets; self.isHistory = isHistory
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        override func layout() { super.layout(); register() }
        func register() {
            guard let scroll = enclosingScrollView else { return }
            scroll.identifier = NSUserInterfaceItemIdentifier(isHistory ? "pi-debug-history" : "pi-debug-dock")
            if isHistory { targets.history = scroll } else { targets.dock = scroll }
        }
    }
}

private struct PiConversationWheelBridge: NSViewRepresentable {
    let isDesktop: Bool
    let targets: PiConversationScrollTargets
    func makeNSView(context: Context) -> PiConversationWheelView { PiConversationWheelView(targets: targets) }
    func updateNSView(_ view: PiConversationWheelView, context: Context) {
        view.isDesktop = isDesktop
        view.isEnabled = context.environment.isEnabled
    }
    static func dismantleNSView(_ view: PiConversationWheelView, coordinator: Void) { view.stopMonitoring() }
}

/// Restore Pi's wheel bubbling across the layout-only sibling seam. Desktop never uses this route.
@MainActor final class PiConversationWheelView: NSView {
    var isDesktop = false
    var isEnabled = true
    let targets: PiConversationScrollTargets
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }

    init(targets: PiConversationScrollTargets) {
        self.targets = targets
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let forwarded = MainActor.assumeIsolated {
                guard let self, let window = event.window else { return false }
                return self.forwardWheel(event, from: window, at: event.locationInWindow)
            }
            return forwarded ? nil : event
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    isolated deinit { stopMonitoring() }

    @discardableResult func forwardWheel(_ event: NSEvent, from eventWindow: NSWindow, at location: NSPoint) -> Bool {
        // SwiftUI's root hit test can return its graphics container. Resolve native children inside the visible dock.
        guard !isDesktop, isEnabled, !isHiddenOrHasHiddenAncestor,
              event.type == .scrollWheel, eventWindow === window,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              NSApp.modalWindow == nil || NSApp.modalWindow === eventWindow,
              eventWindow.sheets.isEmpty, eventWindow.sheetParent == nil,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              visibleRect.contains(convert(location, from: nil)),
              let history = targets.history, let dock = targets.dock,
              history.window === eventWindow, dock.window === eventWindow, !dock.isHiddenOrHasHiddenAncestor,
              dock.visibleRect.contains(dock.convert(location, from: nil)),
              let parent = dock.superview,
              let hit = dock.hitTest(parent.convert(location, from: nil)),
              hit === dock || hit.isDescendant(of: dock) else { return false }
        var current: NSView? = hit
        while let view = current {
            if let scroll = view as? NSScrollView, Self.canScroll(scroll, deltaY: event.scrollingDeltaY) { return false }
            if view === dock {
                history.scrollWheel(with: event)
                return true
            }
            current = view.superview
        }
        return false
    }

    static func canScroll(_ scroll: NSScrollView, deltaY: CGFloat) -> Bool {
        guard let document = scroll.documentView else { return false }
        let end = max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
        let origin = scroll.contentView.bounds.minY
        let towardEnd = document.isFlipped ? deltaY < 0 : deltaY > 0
        return towardEnd ? origin < end - 0.5 : origin > document.bounds.minY + 0.5
    }
}

/// Native borderless controls keep the compact footer selectable through Mac accessibility.
private struct PiFooterAction: NSViewRepresentable {
    @Environment(\.macInterfaceMode) private var interfaceMode
    let title: String
    let color: NSColor
    let identifier: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.activate))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.lineBreakMode = .byTruncatingMiddle
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: interfaceMode == .desktop ? NSFont.systemFont(ofSize: 12) : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: color])
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: min(proposal.width ?? size.width, size.width), height: max(18, size.height))
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}

private struct PiTranscriptRow: View {
    @Environment(\.macInterfaceMode) private var interfaceMode
    private var isDesktop: Bool { interfaceMode == .desktop }
    private var theme: MacInterfaceTheme { MacInterfaceTheme(mode: interfaceMode) }
    let message: TranscriptMessage
    let showThinking: Bool
    let expandTools: Bool
    let request: (SessionAction) async throws -> AppResult
    var onDisclosure: (UUID, CGFloat) -> Void = { _, _ in }
    var runtimePhase: String? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: isDesktop ? 10 : 6) {
            if isDesktop, message.role != "tool", message.role != "bash" {
                HStack(spacing: 6) {
                    Image(systemName: message.role == "user" ? "person.crop.circle.fill" : "sparkles")
                        .foregroundStyle(theme.accent)
                    Text(message.role == "user" ? "You" : "Pi")
                        .fontWeight(.semibold).foregroundStyle(theme.muted)
                }.font(.system(size: 11))
            }
            if message.role == "tool" {
                PiToolRow(message: message, expandTools: expandTools, onDisclosure: onDisclosure, runtimePhase: runtimePhase)
            } else if message.role == "bash" {
                Rectangle().fill(PiPalette.bash).frame(height: 1)
                let lines = message.text.components(separatedBy: "\n")
                ScrollView(.horizontal) {
                    Text(expanded ? message.text : lines.prefix(22).joined(separator: "\n"))
                        .font(.system(size: isDesktop ? 12 : 13, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.count > 22 {
                    Button(expanded ? "Collapse command output" : "Expand command output") { expanded.toggle() }
                        .buttonStyle(.plain).foregroundStyle(theme.muted)
                    if !expanded { Text(lines.last ?? "").foregroundStyle(theme.muted) }
                }
                Rectangle().fill(PiPalette.bash).frame(height: 1)
            } else {
                if message.role == "user" {
                    Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let thinking = message.thinking, !thinking.isEmpty {
                        Text(showThinking ? thinking : "Thinking…").italic().foregroundStyle(theme.muted).textSelection(.enabled)
                    }
                    PiMarkdown(text: message.text)
                }
            }
            if let images = message.images { OutputImageList(images: images, request: request) }
            if message.truncated { Text("Display limit reached. Full saved content is available through History.").foregroundStyle(theme.warning) }
            if message.streaming, message.role != "tool" { Text("…").foregroundStyle(theme.muted).accessibilityLabel("Streaming") }
        }
        .padding(isDesktop && message.role != "tool" ? 16 : (message.role == "user" ? 10 : 0))
        .frame(maxWidth: isDesktop && message.role == "user" ? 660 : .infinity, alignment: .leading)
        .background {
            if isDesktop, message.role != "tool" {
                RoundedRectangle(cornerRadius: 16)
                    .fill(message.role == "user" ? theme.accent.opacity(0.10) : theme.panel)
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1) }
            } else if message.role == "user" { PiPalette.panel }
        }
        .frame(maxWidth: .infinity, alignment: isDesktop && message.role == "user" ? .trailing : .leading)
        .foregroundStyle(message.isError ? theme.warning : theme.text)
        .accessibilityIdentifier("pi-message-" + message.id.uuidString)
    }
}

struct PiMarkdown: View {
    @Environment(\.macInterfaceMode) private var interfaceMode
    private var theme: MacInterfaceTheme { MacInterfaceTheme(mode: interfaceMode) }
    let text: String
    var copyCode: (String) throws -> Void = { try LocalClipboard.copy($0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MarkdownDocument(text).blocks) { block in
                HStack(alignment: .top, spacing: 6) {
                    if let marker = block.marker { Text(marker).foregroundStyle(theme.muted) }
                    switch block.kind {
                    case .code:
                        PiCodeBlock(code: String(block.text.characters), language: block.language, copy: copyCode)
                    case .rule: Rectangle().fill(theme.muted).frame(height: 1)
                    case .heading:
                        Text(block.text).bold().foregroundStyle(interfaceMode == .pi ? PiPalette.heading : theme.text).textSelection(.enabled)
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
