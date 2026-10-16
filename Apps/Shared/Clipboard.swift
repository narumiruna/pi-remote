import PiRemoteCore
import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

@MainActor enum LocalClipboard {
    #if os(iOS)
    static func copy(_ text: String, to pasteboard: UIPasteboard = .general, expiresAt: Date = Date().addingTimeInterval(120)) throws {
        guard !text.isEmpty, text.utf8.count <= 256 * 1_024 else { throw RemoteFault.invalidRequest }
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true, .expirationDate: expiresAt])
    }
    #else
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        guard !text.isEmpty, text.utf8.count <= 256 * 1_024 else { throw RemoteFault.invalidRequest }
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        guard pasteboard.setString(text, forType: .string) else { throw RemoteFault.storageFailure }
    }
    #endif
}

typealias ClipboardWriter = @MainActor @Sendable (String) throws -> Void
private struct ClipboardWriterKey: EnvironmentKey {
    static let defaultValue: ClipboardWriter = { try LocalClipboard.copy($0) }
}
extension EnvironmentValues {
    var clipboardWriter: ClipboardWriter {
        get { self[ClipboardWriterKey.self] }
        set { self[ClipboardWriterKey.self] = newValue }
    }
}

struct CopyTextButton: View {
    let text: String
    var truncated = false
    @Environment(\.clipboardWriter) private var copy
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            Button {
                do { try copy(text); copied = true; error = nil }
                catch { self.error = "Cannot copy text. Check clipboard access and try again." }
            } label: { Text(truncated ? "Copy shown text" : "Copy text").frame(minWidth: 44, minHeight: 44) }
                .disabled(text.isEmpty).buttonStyle(.bordered)
            if copied { Text("Copied to this device").font(.caption) }
            if let error { Text(error).font(.caption) }
        }
        .onChange(of: text) { _, _ in copied = false; error = nil }
    }
}
