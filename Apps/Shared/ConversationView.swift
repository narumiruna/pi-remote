import PiRemoteCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ConversationView<Extras: View>: View {
    let state: HostSnapshot
    @Binding var text: String
    @Binding var delivery: Delivery
    var sending: Bool
    var remoteAvailable = true
    var hasAttachment = false
    var send: () -> Void
    var stop: () -> Void
    var request: ((SessionAction) async throws -> AppResult)? = nil
    @ViewBuilder var extras: () -> Extras
    @State private var atBottom = true
    @State private var followingOutput = true
    @State private var userScrolling = false
    #if os(macOS)
    @State private var macEditorHeight: CGFloat = 76
    @State private var macSelection = NSRange(location: 0, length: 0)
    @State private var macMarkedText = false
    @State private var macDismissed = false
    @State private var macHighlightedID: String?
    @State private var macFocusRequest = 0
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var controlMinimum: CGFloat? {
        #if os(macOS)
        nil
        #else
        44
        #endif
    }
    private var transcriptSpacing: CGFloat {
        #if os(macOS)
        16
        #else
        12
        #endif
    }
    private var canCompose: Bool { state.selected != nil && !["unavailable", "interrupted", "recovering", "starting", "stopping"].contains(state.phase) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // The host bounds this view to 100 messages and 256 KiB. Eager layout keeps live row heights stable.
                    VStack(alignment: .leading, spacing: transcriptSpacing) {
                        if state.messages.isEmpty {
                            #if os(macOS)
                            ContentUnavailableView(macEmptyTitle, systemImage: "bubble.left.and.text.bubble.right",
                                                   description: Text(macEmptyDescription))
                                .frame(maxWidth: .infinity)
                            #else
                            ContentUnavailableView(state.selected == nil ? "No session selected" : (!canCompose ? "Pi is not running" : (state.working ? "Pi is working" : "Ready for a task")), systemImage: "bubble.left.and.text.bubble.right",
                                                   description: Text(state.selected == nil ? "Choose a folder and start a session, then send a prompt." : (!canCompose ? "Open the saved session to continue. Previous prompts are not resent." : (state.working ? "Waiting for output. Stop remains available." : "Send a prompt to start working in this session."))))
                                .frame(maxWidth: .infinity)
                            #endif
                        }
                        if state.hasOlderMessages {
                            #if os(macOS)
                            Text("Earlier messages are saved on the Mac. Use /history to inspect them.")
                                .font(.caption).foregroundStyle(.primary.opacity(0.75))
                            #else
                            Text("Earlier messages are saved on the Mac. Open History to inspect them.")
                                .font(.caption).foregroundStyle(.primary.opacity(0.75))
                            #endif
                        }
                        ForEach(state.messages) { message in
                            if message.role == "tool" {
                                VStack(alignment: .leading, spacing: 8) {
                                    DisclosureGroup {
                                        Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        if message.truncated { Text("Output truncated at the display limit.").font(.caption).foregroundStyle(.primary.opacity(0.75)) }
                                        #if !os(macOS)
                                        if let images = message.images {
                                            OutputImageList(images: images, request: request)
                                        }
                                        #endif
                                    } label: {
                                        Label(DisplayLimit.text(message.text.components(separatedBy: "\n").first ?? "Tool", bytes: 128),
                                              systemImage: message.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                                            .font(.subheadline)
                                            #if !os(macOS)
                                            .lineLimit(1)
                                            #endif
                                            .frame(minHeight: controlMinimum)
                                    }
                                    #if os(macOS)
                                    if let images = message.images {
                                        OutputImageList(images: images, request: request)
                                        if message.truncated { Text("Some output was omitted. Read History or inspect the source on the Mac.").font(.caption) }
                                    }
                                    #endif
                                    if message.isError {
                                        Text("Tool error: " + DisplayLimit.text(message.text, bytes: 1_024))
                                            .font(.callout).textSelection(.enabled)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    #if os(macOS)
                                    Text(message.role == "user" ? "You" : "Pi")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.primary.opacity(0.75))
                                    #else
                                    if message.role != "assistant" || PhoneAssistantContent.parts(in: message).contains(where: { !$0.toolCall && !$0.text.isEmpty }) || message.thinking?.isEmpty == false {
                                        Text(message.role == "user" ? "You" : "Pi")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.primary.opacity(0.75))
                                    }
                                    #endif
                                    if let thinking = message.thinking, !thinking.isEmpty {
                                        DisclosureGroup { MarkdownContent(text: thinking) } label: {
                                            Text("Thinking").frame(minHeight: controlMinimum)
                                        }.font(.callout)
                                    }
                                    #if os(macOS)
                                    MarkdownContent(text: message.text)
                                    #else
                                    PhoneAssistantContent(message: message)
                                    #endif
                                    if let images = message.images { OutputImageList(images: images, request: request) }
                                    if message.truncated { Text("Display truncated; inspect History or the source file.").font(.caption).foregroundStyle(.primary.opacity(0.75)) }
                                    if message.isError { Label("Pi reported an error", systemImage: "exclamationmark.triangle").foregroundStyle(.primary).font(.caption) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    Button("Copy message") { try? LocalClipboard.copy(message.text) }.disabled(message.text.isEmpty)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    #if os(macOS)
                    .font(.system(size: 15))
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    #else
                    .padding(16)
                    #endif
                }
                #if os(macOS)
                .accessibilityIdentifier("mac-conversation-transcript")
                #else
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("phone-conversation-transcript")
                #endif
                .clipped()
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: state.selected) { _, _ in
                    followingOutput = true; userScrolling = false
                    proxy.scrollTo("latest", anchor: .bottom)
                }
                .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, _ in
                    if followingOutput && !userScrolling { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
                } action: { _, value in atBottom = value }
                .onScrollPhaseChange { _, phase in
                    // Pause during the gesture. Layout changes must not reverse the user's scroll.
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        userScrolling = true; followingOutput = false
                    } else if phase == .idle && userScrolling {
                        userScrolling = false; followingOutput = atBottom
                    }
                }
                .onChange(of: state.sequence) { _, _ in if followingOutput && !userScrolling { proxy.scrollTo("latest", anchor: .bottom) } }
                .overlay(alignment: .bottomTrailing) {
                    if !followingOutput {
                        Button { userScrolling = false; followingOutput = true; proxy.scrollTo("latest", anchor: .bottom) } label: {
                            Label("Latest", systemImage: "arrow.down").frame(minHeight: controlMinimum)
                        }.font(.caption).buttonStyle(.borderedProminent).foregroundStyle(.background).padding()
                    }
                }
            }
            #if !os(macOS)
            if dynamicTypeSize.isAccessibilitySize {
                PhoneExtensionNotices(state: state)
                if state.working { phoneDeliveryPicker.padding(.horizontal, 12) }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    if state.working { phoneDeliveryPicker.padding(.leading, 12) }
                    PhoneExtensionNotices(state: state)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            #endif
            Divider()
            #if os(macOS)
            macComposer
            #else
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    extras().disabled(!remoteAvailable)
                    TextField("Message Pi", text: $text, prompt: Text("Message Pi").foregroundColor(.primary.opacity(0.75)), axis: .vertical)
                        .lineLimit(1...3).textFieldStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Prompt").accessibilityIdentifier("instruction")
                        .disabled(!canCompose)
                    if state.working {
                        Button(action: stop) {
                            Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly).frame(minWidth: controlMinimum, minHeight: controlMinimum)
                        }
                            .accessibilityLabel("Stop")
                            .accessibilityHint("Clear queued messages and stop current work. File changes are not undone.")
                            .disabled(!remoteAvailable)
                    }
                    Button(action: send) {
                        Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly).frame(minWidth: controlMinimum, minHeight: controlMinimum)
                    }
                        .buttonStyle(.plain).background(.tint, in: Circle()).foregroundStyle(.background).accessibilityLabel("Send")
                        .disabled(!phoneCanSend)
                        .opacity(phoneCanSend ? 1 : 0.4)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            #endif
        }
        .onChange(of: state.working) { _, working in delivery = working ? .steer : .prompt }
        .onAppear { delivery = state.working ? .steer : .prompt }
    }

    #if !os(macOS)
    private var phoneCanSend: Bool {
        remoteAvailable && !sending && canCompose
            && (hasAttachment || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var phoneDeliveryPicker: some View {
        Menu {
            Picker("Send as", selection: $delivery) {
                Text("Steering").tag(Delivery.steer)
                Text("Follow-up").tag(Delivery.followUp)
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(delivery == .followUp ? "Follow-up" : "Steering")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.caption).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false).disabled(!remoteAvailable)
        .accessibilityLabel("Send as: " + (delivery == .followUp ? "Follow-up" : "Steering"))
        .accessibilityHint("Steering guides Pi after the current response and tool calls finish. Follow-up waits until Pi finishes the current task.")
    }
    #endif

    #if os(macOS)
    private var macEditable: Bool {
        state.selected != nil && !["recovering", "starting", "stopping"].contains(state.phase)
    }

    private var macIsSlash: Bool {
        if case .prompt = MacSlashCommands.submission(text, in: state) { return false }
        return true
    }

    private var macCanSend: Bool {
        guard macEditable, !macMarkedText, !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if macIsSlash {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().prefix { !$0.isWhitespace }
            if let option = MacSlashCommands.options(in: state).first(where: { $0.name == String(name) }) {
                return option.isEnabled(in: state)
            }
        }
        switch MacSlashCommands.submission(text, in: state) {
        case .prompt: return canCompose
        case .invalid: return true
        case .native, .command: return false
        }
    }

    private var macCompletion: MacSlashCompletion? {
        guard macEditable, !macMarkedText, !macDismissed else { return nil }
        if case .prompt = MacSlashCommands.submission(text, in: state) { return nil }
        return MacSlashCommands.completion(in: text, selection: macSelection)
    }

    private var macMatches: [MacSlashOption] {
        guard let completion = macCompletion else { return [] }
        return MacSlashCommands.matching(in: state, query: completion.query)
    }

    private var macHighlighted: MacSlashOption? {
        macMatches.first { $0.id == macHighlightedID } ?? macMatches.first
    }

    private func macComplete(_ option: MacSlashOption) {
        guard let completion = macCompletion, option.isEnabled(in: state), !sending else { return }
        let result = MacSlashCommands.completing(option, in: text, completion: completion)
        text = result.text
        macSelection = result.selection
        macHighlightedID = nil
        macFocusRequest += 1
    }

    private func macCompletionKey(_ key: MacComposerKey) -> Bool {
        switch key {
        case .up, .down:
            let options = macMatches
            guard !options.isEmpty else { return false }
            let current = options.firstIndex { $0.id == macHighlighted?.id } ?? 0
            let next = min(options.count - 1, max(0, current + (key == .up ? -1 : 1)))
            macHighlightedID = options[next].id
        case .complete:
            guard let option = macHighlighted, option.isEnabled(in: state), !sending else { return false }
            macComplete(option)
        case .dismiss:
            macDismissed = true
        }
        return true
    }

    private var macSuggestionHeight: CGFloat { min(200, CGFloat(max(1, macMatches.count)) * 66 + 8) }

    private var macSuggestions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if macMatches.isEmpty {
                        Text("No matching commands").foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(macMatches) { option in
                        Button { macComplete(option) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/" + option.name).font(.system(size: 13, weight: .semibold))
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                if !option.isEnabled(in: state) || sending {
                                    Text(sending ? "A request is being sent." : (option.disabledReason(in: state) ?? "Unavailable in the current session state."))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(macHighlighted?.id == option.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!option.isEnabled(in: state) || sending)
                        .accessibilityIdentifier("slash-option-" + option.name)
                        .id(option.id)
                    }
                }.padding(4)
            }
            .frame(height: macSuggestionHeight)
            .onChange(of: macHighlightedID) { _, _ in
                if let option = macHighlighted { proxy.scrollTo(option.id) }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.15)) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
        .accessibilityIdentifier("mac-slash-suggestions")
        .help("Return or Tab completes the selected command. Command-Return runs or sends the draft.")
    }

    var macEmptyTitle: String {
        if state.selected == nil { return "No session selected" }
        switch state.phase {
        case "starting": return "Starting Pi…"
        case "stopping": return "Stopping Pi…"
        case "recovering": return "Pi status is uncertain"
        case "waiting": return "Pi is waiting for input"
        default: break
        }
        if !canCompose { return "Pi is not running" }
        return state.working ? "Pi is working" : "Pi is idle and ready"
    }

    var macEmptyDescription: String {
        if state.selected == nil { return "Choose a workspace and open a session to start." }
        switch state.phase {
        case "starting": return "Wait while Pi opens the session. No prompt is resent."
        case "stopping": return "Wait for Pi to stop. File changes are not undone."
        case "recovering": return "Use Stop, then reopen the saved session. Do not resend uncertain prompts."
        case "waiting": return "Complete or cancel the open request. Stop remains available."
        default: break
        }
        if !canCompose { return "Open the saved session to continue. Previous prompts are not resent." }
        return state.working ? "Waiting for output. Stop remains available." : "Send a prompt to start working in this session."
    }

    private var macComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacComposerEditor(text: $text, selection: $macSelection, markedText: $macMarkedText,
                              context: state.context, editable: macEditable, popupShown: macCompletion != nil,
                              focusRequest: macFocusRequest, completionKey: macCompletionKey)
                .frame(height: macEditorHeight)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message Pi…").font(.system(size: 15)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background {
                    // Measure only enough text to fill the bounded editor viewport.
                    Text(String(text.prefix(4_096)) + "\n").font(.system(size: 15)).lineLimit(8)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).hidden().accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { min(180, max(76, $0.size.height)) } action: { macEditorHeight = $0 }
                }
                .accessibilityLabel("Prompt").accessibilityIdentifier("instruction")
                .onChange(of: text) { _, _ in macDismissed = false; macHighlightedID = nil }
                .onChange(of: macSelection) { _, _ in macDismissed = false; macHighlightedID = nil }
                .onChange(of: state.context) { _, _ in
                    macDismissed = false; macHighlightedID = nil; macMarkedText = false
                }
            if state.working {
                Picker("Send as", selection: $delivery) {
                    Text("Steering").tag(Delivery.steer)
                    Text("Follow-up").tag(Delivery.followUp)
                }
                .pickerStyle(.menu).frame(maxWidth: 210, alignment: .leading)
                .accessibilityHint("Steering guides Pi after the current response and tool calls finish. Follow-up waits until Pi finishes the current task.")
            }
            HStack(spacing: 6) {
                extras()
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
                if state.working {
                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .accessibilityLabel("Stop")
                    .accessibilityHint("Clear queued messages and stop current work. File changes are not undone.")
                }
                Button {
                    guard macCanSend else { return }
                    send()
                } label: {
                    Label(macIsSlash ? "Run" : "Send", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(macIsSlash ? "Run" : "Send")
                .help("Command-Return runs a command or sends a prompt. Return and Tab only complete while suggestions are visible.")
                .disabled(!macCanSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .labelStyle(.titleAndIcon).controlSize(.small)
            Text(macCompletion == nil
                 ? "Type / for commands · ⌘Return run/send · Return for a new line"
                 : "↑↓ select · Tab/Return complete · Esc close · ⌘Return run")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message composer").accessibilityIdentifier("mac-composer-container")
        .frame(maxWidth: 784)
        .frame(maxWidth: .infinity)
        .padding(16)
        .overlay(alignment: .top) {
            if macCompletion != nil {
                macSuggestions.frame(maxWidth: 784).padding(.horizontal, 16)
                    .offset(y: -macSuggestionHeight - 8)
            }
        }
        .zIndex(1)
    }
    #endif
}

#if os(macOS)
private enum MacComposerKey { case up, down, complete, dismiss }

private struct MacComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var markedText: Bool
    let context: SessionContext
    let editable: Bool
    let popupShown: Bool
    let focusRequest: Int
    let completionKey: (MacComposerKey) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.applying = true
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.delegate = nil
        editor.completionKey = nil
        editor.unmarkText()
        editor.undoManager?.removeAllActions()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let editor = ComposerTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textContainerInset = NSSize(width: 5, height: 8)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Prompt")
        editor.setAccessibilityIdentifier("instruction")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        let coordinator = context.coordinator
        let changedContext = coordinator.parent.context != self.context
        let changedBinding = coordinator.lastBoundText != text
        coordinator.lastBoundText = text
        coordinator.parent = self
        coordinator.applying = true
        defer { coordinator.applying = false }
        editor.isEditable = editable
        editor.popupShown = popupShown
        editor.completionKey = completionKey
        if changedContext {
            editor.unmarkText()
            editor.undoManager?.removeAllActions()
        }
        if editor.hasMarkedText() {
            // Selection updates can arrive before IME text reaches the binding.
            // Preserve preedit text unless the draft was explicitly replaced.
            if !changedBinding || editor.string == text { return }
            editor.unmarkText()
        }
        if editor.string != text {
            let fullRange = NSRange(location: 0, length: (editor.string as NSString).length)
            if !changedContext && editor.shouldChangeText(in: fullRange, replacementString: text) {
                editor.textStorage?.replaceCharacters(in: fullRange, with: text)
                editor.didChangeText()
            } else {
                editor.string = text
            }
        }
        let length = (editor.string as NSString).length
        let location = min(max(0, selection.location), length)
        let safeSelection = NSRange(location: location, length: min(max(0, selection.length), length - location))
        if editor.selectedRange() != safeSelection { editor.setSelectedRange(safeSelection) }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            editor.window?.makeFirstResponder(editor)
            editor.scrollRangeToVisible(safeSelection)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerEditor
        var applying = false
        var focusRequest: Int
        var lastBoundText: String
        init(_ parent: MacComposerEditor) {
            self.parent = parent
            focusRequest = parent.focusRequest
            lastBoundText = parent.text
        }
        func textDidChange(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
            parent.markedText = editor.hasMarkedText()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let editor = notification.object as? NSTextView else { return }
            parent.selection = editor.selectedRange()
            parent.markedText = editor.hasMarkedText()
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let editor = textView as? ComposerTextView, editor.popupShown,
                  !editor.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            guard !modifiers.contains(.command), !modifiers.contains(.shift),
                  !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
            let key: MacComposerKey
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.insertTab(_:)): key = .complete
            case #selector(NSResponder.insertNewline(_:)): key = .complete
            case #selector(NSResponder.cancelOperation(_:)): key = .dismiss
            default: return false
            }
            return editor.completionKey?(key) ?? false
        }
    }
}

private final class ComposerTextView: NSTextView {
    var popupShown = false
    var completionKey: ((MacComposerKey) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command), !hasMarkedText() {
            _ = window?.performKeyEquivalent(with: event)
            return
        }
        super.keyDown(with: event)
    }
}
#endif

#if !os(macOS)
struct PhoneAssistantContent: View {
    let message: TranscriptMessage

    struct Part: Identifiable, Equatable {
        var id: Int
        var text: String
        var toolCall: Bool
    }

    // Only typed tool-call ranges can collapse. Never guess from prose or JSON text.
    static func parts(in message: TranscriptMessage) -> [Part] {
        guard message.role == "assistant", let ranges = message.toolCallRanges, !ranges.isEmpty else {
            return [Part(id: 0, text: message.text, toolCall: false)]
        }
        let bytes = Array(message.text.utf8)
        var parts: [Part] = []
        var cursor = 0
        for range in ranges {
            guard range.lowerBound >= cursor, range.upperBound <= bytes.count, !range.isEmpty,
                  let prose = String(bytes: bytes[cursor..<range.lowerBound], encoding: .utf8),
                  let call = String(bytes: bytes[range], encoding: .utf8) else {
                return [Part(id: 0, text: message.text, toolCall: false)]
            }
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(Part(id: cursor, text: prose, toolCall: false))
            }
            parts.append(Part(id: range.lowerBound, text: call, toolCall: true))
            cursor = range.upperBound
        }
        guard let tail = String(bytes: bytes[cursor...], encoding: .utf8) else {
            return [Part(id: 0, text: message.text, toolCall: false)]
        }
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(Part(id: cursor, text: tail, toolCall: false))
        }
        return parts
    }

    var body: some View {
        ForEach(Self.parts(in: message)) { part in
            if part.toolCall {
                let name = DisplayLimit.text(part.text.components(separatedBy: "\n").first ?? "Tool", bytes: 128)
                DisclosureGroup {
                    Text(part.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("phone-tool-arguments-\(part.id)")
                } label: {
                    Label(name, systemImage: "wrench.and.screwdriver")
                        .font(.subheadline).lineLimit(1).frame(minHeight: 44)
                }
            } else {
                MarkdownContent(text: part.text)
            }
        }
    }
}

struct PhoneExtensionNotices: View {
    let state: HostSnapshot
    @State private var contentHeight: CGFloat = 44
    @State private var showingDetails = false

    // Keep severity in the summary and complete text in a separate detail sheet.
    static func notices(in state: HostSnapshot) -> [ExtensionNotice] {
        if let display = state.extensionDisplay { return display.notices }
        return state.notices.enumerated().map { ExtensionNotice(id: "legacy-\($0.offset)", text: $0.element) }
    }

    static func information(in state: HostSnapshot) -> [String] {
        guard let display = state.extensionDisplay else { return [] }
        let information = display.statuses.map(\.text) + display.widgets.map(\.text)
        let hasRecovery = display.notices.contains { $0.id == "recovery" }
        let noticeCount = display.notices.count - (hasRecovery ? 1 : 0)
        // Host legacy order: recovery, sorted statuses, sorted widgets, then notices.
        // Use positions, not text equality: typed text has terminal controls removed.
        if !hasRecovery, state.notices.count > information.count + noticeCount,
           let recovery = state.notices.first {
            return [recovery] + information
        }
        return information
    }

    static func summary(for notices: [ExtensionNotice]) -> String {
        let errors = notices.filter { $0.severity == .error }.count
        let warnings = notices.filter { $0.severity == .warning }.count
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) " + (errors == 1 ? "error" : "errors")) }
        if warnings > 0 { parts.append("\(warnings) " + (warnings == 1 ? "warning" : "warnings")) }
        return parts.isEmpty ? "Extension information" : parts.joined(separator: " · ")
    }

    private func notice(_ item: ExtensionNotice) -> some View {
        let severity = item.severity == .error ? "Error" : (item.severity == .warning ? "Warning" : "Information")
        let icon = item.severity == .error ? "exclamationmark.octagon" : (item.severity == .warning ? "exclamationmark.triangle" : "info.circle")
        return Label(severity + ": " + item.text, systemImage: icon)
            .font(.caption).textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(severity + ": " + item.text)
            .accessibilityIdentifier("extension-notice-" + item.id)
    }

    var body: some View {
        let notices = Self.notices(in: state)
        let recovery = notices.filter { $0.id == "recovery" }
        let diagnostics = notices.filter { $0.id != "recovery" }
        let information = Self.information(in: state)
        if !notices.isEmpty || !information.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recovery) { notice($0) }
                    if !diagnostics.isEmpty || !information.isEmpty {
                        Button { showingDetails = true } label: {
                            HStack {
                                Label(Self.summary(for: diagnostics), systemImage: diagnostics.contains { $0.severity != .info } ? "exclamationmark.triangle" : "info.circle")
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .font(.caption).buttonStyle(.plain)
                        .accessibilityLabel(Self.summary(for: diagnostics))
                        .accessibilityHint("Open complete notices, status and diagnostics.")
                        .accessibilityIdentifier("extension-notice-summary")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in contentHeight = height }
            .frame(height: min(180, max(44, contentHeight)))
            .padding(.horizontal, 20).padding(.bottom, 8)
            .sheet(isPresented: $showingDetails) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(diagnostics) { notice($0) }
                            ForEach(Array(information.enumerated()), id: \.offset) { item in
                                Text(item.element).font(.caption).textSelection(.enabled)
                                    .accessibilityIdentifier("extension-information-\(item.offset)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .navigationTitle("Extension details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showingDetails = false }
                        }
                    }
                }
            }
        }
    }
}
#endif

extension RemoteFault {
    var title: String {
        switch self {
        case .unknownOutcome: "Outcome unknown"
        case .unauthorized: "Not authorized"
        case .busy: "Pi is busy"
        case .permissionDenied: "Access denied"
        case .staleDirectory: "Folder changed"
        case .unsupportedFeature: "Not supported"
        case .expired: "Request expired"
        case .storageFailure: "Storage unavailable"
        case .tooLarge: "Size limit"
        case .conflict: "Session changed"
        case .incompatiblePi: "Pi version mismatch"
        case .providerAuthenticationRequired: "Sign in on Mac"
        case .unavailable: "Unavailable"
        case .piLaunchFailed: "Pi could not start"
        case .nodeUnavailable: "Node.js not found"
        case .capacity: "Request limit"
        case .cancelled: "Cancelled"
        case .unsupportedVersion: "Update apps"
        default: "Request rejected"
        }
    }
    var explanation: String {
        switch self {
        case .unknownOutcome: "The Mac may have accepted this action. Check the session before sending it again."
        case .unauthorized: "This device is not authorized. Pair again after checking access on the Mac."
        case .busy: "Pi is busy, or another control is changing the session. Stop work or wait, then try again."
        case .permissionDenied: "The Mac companion cannot access this folder. Grant access on the Mac."
        case .staleDirectory: "This folder or file changed, moved, or became unavailable. Browse again."
        case .unsupportedFeature: "This feature is not available through the current Pi interface."
        case .expired: "This pairing window, dialog, or history link expired. Open it again."
        case .storageFailure: "Protected storage is unavailable. Unlock the device and check Keychain or disk access."
        case .tooLarge: "The input or output exceeds the app's size limit."
        case .conflict: "The session changed. Refresh it before trying this action."
        case .incompatiblePi: "The selected Pi version returned an unsupported interface. Use a tested Pi version on the Mac."
        case .providerAuthenticationRequired: "Pi cannot authenticate with its provider. Sign in or configure credentials on the Mac, then retry."
        case .unavailable: "The Mac, Pi process, or connection is unavailable. Check the Mac and reconnect."
        case .piLaunchFailed: "Pi could not start on the Mac. Check Settings → Pi and folder access → Choose Pi executable. Confirm that the selected Pi runs with --version and its runtime is installed."
        case .nodeUnavailable: "Pi needs Node.js, but the Mac app could not find it. Check your Node.js installation or default version configured in your Node version manager, then retry opening the session. Starting the server is not required."
        case .capacity: "The request limit was reached. Wait for pending actions to finish."
        case .cancelled: "The action was cancelled."
        case .unsupportedVersion: "These app versions cannot communicate. Update Pi Remote and Pi Remote for Mac, then connect again."
        default: "The request was rejected. Check the input and connection."
        }
    }
}
