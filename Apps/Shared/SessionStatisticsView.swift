import PiRemoteCore
import SwiftUI

struct SessionStatisticsView: View {
    let request: (SessionAction) async throws -> AppResult
    @State private var statistics: SessionStatistics?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Form {
            if loading { ProgressView("Loading usage") }
            if let error { Text(error) }
            if let statistics {
                Section("Session totals") {
                    row("User messages", statistics.userMessages.formatted())
                    row("Assistant messages", statistics.assistantMessages.formatted())
                    row("Tool calls", statistics.toolCalls.formatted())
                    row("Tool results", statistics.toolResults.formatted())
                    row("Total messages", statistics.totalMessages.formatted())
                }
                Section("Tokens and cost") {
                    row("Input", statistics.tokens.input.formatted())
                    row("Output", statistics.tokens.output.formatted())
                    row("Cache read", statistics.tokens.cacheRead.formatted())
                    row("Cache write", statistics.tokens.cacheWrite.formatted())
                    row("Total tokens", statistics.tokens.total.formatted())
                    row("Reported cost (USD)", statistics.cost.formatted(.number.precision(.fractionLength(6))))
                    Text("Reported usage includes branches, tool-reported usage and summaries. It is not a provider invoice.")
                        .font(.caption)
                }
                Section("Current context") {
                    if let context = statistics.contextUsage {
                        row("Window", context.contextWindow.formatted())
                        if let tokens = context.tokens, let percent = context.percent {
                            row("Estimated tokens", tokens.formatted())
                            row("Used", percent.formatted(.number.precision(.fractionLength(1))) + "%")
                        } else {
                            Text("Usage is not available until a new response after compaction.")
                        }
                    } else { Text("No context-window estimate is available for this model.") }
                }
            }
            Button("Refresh usage") { Task { await load() } }.frame(minHeight: 44).disabled(loading)
        }
        .navigationTitle("Session usage")
        .task { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent { Text(value).foregroundStyle(Color.primary) } label: { Text(label) }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard case .statistics(let value) = try await request(.statistics) else { throw RemoteFault.incompatiblePi }
            try value.validate()
            statistics = value
        } catch { statistics = nil; self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
