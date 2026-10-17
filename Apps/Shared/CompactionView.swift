import PiRemoteCore
import SwiftUI

struct CompactionView: View {
    let request: (SessionAction) async throws -> AppResult
    @State private var instructions = ""
    @State private var confirming = false
    @State private var running = false
    @State private var completed = false
    @State private var error: String?
    @FocusState private var editing: Bool

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pi summarizes earlier conversation context. This can use your configured provider and incur a cost. Saved session history remains on the Mac.")
                    Text("Optional summary instructions").font(.headline)
                    TextEditor(text: $instructions)
                        .frame(minHeight: 140)
                        .disabled(running)
                        .focused($editing)
                        .accessibilityLabel("Summary instructions")
                        .accessibilityIdentifier("compaction-instructions")
                        .id("compaction-editor")
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
                    Text("Leave the instructions empty to use Pi's default summary. Limit: 16 KiB of UTF-8 text.").font(.caption)
                    if instructions.utf8.count > 16_384 { Text("Instructions exceed the limit.") }
                    if let error { Text(error).accessibilityIdentifier("compaction-error") }
                    if completed { Text("Compaction completed.").accessibilityIdentifier("compaction-completed") }
                    if running { ProgressView("Waiting for Pi compaction") }
                }
                .padding()
            }
            .accessibilityIdentifier("compaction-form")
            .onChange(of: editing) { _, active in
                if active { scroll.scrollTo("compaction-editor", anchor: .top) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                if editing { scroll.scrollTo("compaction-editor", anchor: .top) }
            }
        }
        .navigationTitle("Compact context")
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
            if editing {
                Button { editing = false } label: {
                    Text("Done editing").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            } else { reviewAction }
            #else
            reviewAction
            #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("Compact conversation context?", isPresented: $confirming) {
            Button("Compact") { Task { await compact() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send the displayed instructions to Pi and use its configured compaction behavior. This does not start a new user prompt.")
        }
    }

    private var reviewAction: some View {
        Button { confirming = true } label: {
            Text("Review compaction").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("compaction-review")
        .disabled(running || instructions.utf8.count > 16_384)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    @MainActor private func compact() async {
        guard !running, instructions.utf8.count <= 16_384 else { return }
        running = true; completed = false; error = nil
        defer { running = false }
        do {
            _ = try await request(.compact(instructions: instructions))
            completed = true
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
