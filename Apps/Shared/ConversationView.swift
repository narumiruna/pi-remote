import PiRemoteCore
import SwiftUI

struct ConversationView<Extras: View>: View {
    let state: HostSnapshot
    @Binding var text: String
    @Binding var delivery: Delivery
    var sending: Bool
    var send: () -> Void
    var stop: () -> Void
    var request: ((SessionAction) async throws -> AppResult)? = nil
    @ViewBuilder var extras: () -> Extras
    @State private var atBottom = true
    @State private var followingOutput = true
    @State private var userScrolling = false
    #if os(macOS)
    @State private var macEditorHeight: CGFloat = 76
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
        20
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
                                                   description: Text(state.selected == nil ? "Choose a folder and start a session, then send an instruction." : (!canCompose ? "Open the saved session to continue. Previous instructions are not resent." : (state.working ? "Waiting for output. Stop remains available." : "Send an instruction to start working in this session."))))
                                .frame(maxWidth: .infinity)
                            #endif
                        }
                        if state.hasOlderMessages {
                            Text("Earlier messages are saved on the Mac. Open History to inspect them.")
                                .font(.caption).foregroundStyle(.primary.opacity(0.75))
                        }
                        ForEach(state.messages) { message in
                            if message.role == "tool" {
                                VStack(alignment: .leading, spacing: 8) {
                                    DisclosureGroup {
                                        Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        if message.truncated { Text("Output truncated at the display limit.").font(.caption).foregroundStyle(.primary.opacity(0.75)) }
                                    } label: {
                                        Label(DisplayLimit.text(message.text.components(separatedBy: "\n").first ?? "Tool", bytes: 128),
                                              systemImage: message.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                                            .font(.subheadline).frame(minHeight: controlMinimum)
                                    }
                                    if let images = message.images {
                                        OutputImageList(images: images, request: request)
                                        if message.truncated { Text("Some output was omitted. Read History or inspect the source on the Mac.").font(.caption) }
                                    }
                                    if message.isError {
                                        Text("Tool error: " + DisplayLimit.text(message.text, bytes: 1_024))
                                            .font(.callout).textSelection(.enabled)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == "user" ? "You" : "Pi")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.primary.opacity(0.75))
                                    if let thinking = message.thinking, !thinking.isEmpty {
                                        DisclosureGroup { MarkdownContent(text: thinking) } label: {
                                            Text("Thinking").frame(minHeight: controlMinimum)
                                        }.font(.callout)
                                    }
                                    MarkdownContent(text: message.text)
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
                    .padding(20)
                    #endif
                }
                #if os(macOS)
                .accessibilityIdentifier("mac-conversation-transcript")
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
            if !state.notices.isEmpty {
                DisclosureGroup("Extension status") {
                    ForEach(Array(state.notices.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }.font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
            }
            #endif
            Divider()
            #if os(macOS)
            macComposer
            #else
            VStack(alignment: .leading, spacing: 8) {
                if state.working {
                    Picker("Send as", selection: $delivery) {
                        Text("Steer now").tag(Delivery.steer)
                        Text("Follow up").tag(Delivery.followUp)
                    }.pickerStyle(.menu)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    extras()
                    TextField("Message Pi", text: $text, prompt: Text("Message Pi").foregroundColor(.primary.opacity(0.75)), axis: .vertical)
                        .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 6)).textFieldStyle(.plain)
                        .accessibilityLabel("Instruction").accessibilityIdentifier("instruction")
                        .disabled(!canCompose)
                    if state.working {
                        Button(action: stop) {
                            Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly).frame(minWidth: controlMinimum, minHeight: controlMinimum)
                        }
                            .accessibilityLabel("Stop")
                            .accessibilityHint("Clear queued instructions and stop current work. File changes are not undone.")
                    }
                    Button(action: send) {
                        Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly).frame(minWidth: controlMinimum, minHeight: controlMinimum)
                    }
                        .buttonStyle(.borderedProminent).foregroundStyle(.background).accessibilityLabel("Send")
                        .disabled(sending || !canCompose)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(16)
            #endif
        }
        .onChange(of: state.working) { _, working in delivery = working ? .steer : .prompt }
        .onAppear { delivery = state.working ? .steer : .prompt }
    }

    #if os(macOS)
    private var macCanSend: Bool {
        canCompose && !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        case "starting": return "Wait while Pi opens the session. No instruction is resent."
        case "stopping": return "Wait for Pi to stop. File changes are not undone."
        case "recovering": return "Use Stop, then reopen the saved session. Do not resend uncertain instructions."
        case "waiting": return "Complete or cancel the open request. Stop remains available."
        default: break
        }
        if !canCompose { return "Open the saved session to continue. Previous instructions are not resent." }
        return state.working ? "Waiting for output. Stop remains available." : "Send an instruction to start working in this session."
    }

    private var macComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.system(size: 15)).scrollContentBackground(.hidden)
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
                .accessibilityLabel("Instruction").accessibilityIdentifier("instruction")
                .disabled(!canCompose)
            if state.working {
                Picker("Send as", selection: $delivery) {
                    Text("Steer now").tag(Delivery.steer)
                    Text("Follow up").tag(Delivery.followUp)
                }
                .pickerStyle(.menu).frame(maxWidth: 210, alignment: .leading)
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
                    .accessibilityHint("Clear queued instructions and stop current work. File changes are not undone.")
                }
                Button {
                    guard macCanSend else { return }
                    send()
                } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Send")
                .disabled(!macCanSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .labelStyle(.titleAndIcon).controlSize(.small)
            Text("⌘Return to send · Return for a new line")
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
    }
    #endif
}

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
        case .piLaunchFailed: "Pi could not start on the Mac. Check Connection settings → Pi and folder access → Choose Pi executable. Confirm that the selected Pi runs with --version and its runtime is installed."
        case .nodeUnavailable: "Pi needs Node.js, but the Mac app could not find it. Check your Node.js installation or default version configured in your Node version manager, then retry opening the session. Starting the server is not required."
        case .capacity: "The request limit was reached. Wait for pending actions to finish."
        case .cancelled: "The action was cancelled."
        case .unsupportedVersion: "These app versions cannot communicate. Update Pi Remote and Pi Remote for Mac, then connect again."
        default: "The request was rejected. Check the input and connection."
        }
    }
}
