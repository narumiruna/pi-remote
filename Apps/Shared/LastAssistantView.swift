import PiRemoteCore
import SwiftUI

struct LastAssistantView: View {
    let request: (SessionAction) async throws -> AppResult
    @Environment(\.dismiss) private var dismiss
    @State private var preview: FilePreview?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                if let error { Text(error) }
                else if let preview {
                    if preview.text.isEmpty { Text("No assistant text is available.") }
                    else {
                        Text("Snapshot of the last assistant message. Reopen to refresh.").font(.caption)
                        if preview.truncated { Text("Text exceeds 256 KiB. Only the shown portion can be copied.").font(.caption) }
                        MarkdownContent(text: preview.text)
                    }
                } else { ProgressView("Reading last assistant message") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("Last assistant message")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading) {
                HStack {
                    if let preview { CopyTextButton(text: preview.text, truncated: preview.truncated) }
                    Spacer()
                    Button { dismiss() } label: { Text("Done").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.bordered)
                }
                #if os(iOS)
                Text("Clipboard: this device only; expires in two minutes.").font(.caption)
                #else
                Text("Clipboard: this Mac only.").font(.caption)
                #endif
            }.padding().background(.background)
        }
        .task {
            do {
                guard case .preview(let value) = try await request(.lastAssistant) else { throw RemoteFault.incompatiblePi }
                try Task.checkCancellation()
                preview = value
            } catch { if !Task.isCancelled { self.error = (error as? RemoteFault ?? .unavailable).explanation } }
        }
    }
}
