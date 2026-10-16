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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // The host bounds this view to 100 messages and 256 KiB. Eager layout keeps live row heights stable.
                    VStack(alignment: .leading, spacing: 20) {
                        if state.messages.isEmpty {
                            ContentUnavailableView("Ready for a task", systemImage: "bubble.left.and.text.bubble.right",
                                                   description: Text("Choose a folder and start a session, then send an instruction."))
                                .frame(maxWidth: .infinity)
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
                                            .font(.subheadline).frame(minHeight: 44)
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
                                            Text("Thinking").frame(minHeight: 44)
                                        }.font(.callout)
                                    }
                                    MarkdownContent(text: message.text)
                                    if let images = message.images { OutputImageList(images: images, request: request) }
                                    if message.truncated { Text("Display truncated; inspect History or the source file.").font(.caption).foregroundStyle(.primary.opacity(0.75)) }
                                    if message.isError { Label("Pi reported an error", systemImage: "exclamationmark.triangle").foregroundStyle(.primary).font(.caption) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .padding(20)
                }
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
                            Label("Latest", systemImage: "arrow.down").frame(minHeight: 44)
                        }.font(.caption).buttonStyle(.borderedProminent).foregroundStyle(.background).padding()
                    }
                }
            }
            if !state.notices.isEmpty {
                DisclosureGroup("Extension status") {
                    ForEach(Array(state.notices.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }.font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
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
                    if state.working {
                        Button(action: stop) {
                            Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                            .accessibilityLabel("Stop")
                            .accessibilityHint("Clear queued instructions and stop current work. File changes are not undone.")
                    }
                    Button(action: send) {
                        Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                        .buttonStyle(.borderedProminent).foregroundStyle(.background).accessibilityLabel("Send")
                        .disabled(sending || state.selected == nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(16)
        }
        .onChange(of: state.working) { _, working in delivery = working ? .steer : .prompt }
        .onAppear { delivery = state.working ? .steer : .prompt }
    }
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
        case .capacity: "The request limit was reached. Wait for pending actions to finish."
        case .cancelled: "The action was cancelled."
        case .unsupportedVersion: "These app versions cannot communicate. Update Pi Remote and Pi Remote for Mac, then connect again."
        default: "The request was rejected. Check the input and connection."
        }
    }
}
