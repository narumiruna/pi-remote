import PiRemoteCore
import SwiftUI

struct ReleaseNotesView: View {
    let request: (SessionAction) async throws -> AppResult
    @State private var page: ReleaseNotesPage?
    @State private var previous: [Int] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Changelog from the selected Pi installation. Links are not opened automatically.").font(.caption).id("top")
                    if let page {
                        Text("Pi " + page.version).font(.headline)
                        Text("Bytes \(page.offset)–\(page.offset + page.text.utf8.count) of \(page.totalBytes)").font(.caption)
                        Text(page.text.isEmpty ? "No changelog entries." : page.text).textSelection(.enabled)
                    }
                    if let error { Text(error) }
                    if loading { ProgressView("Reading changelog") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    HStack {
                        Button { Task { await load(previous.last ?? 0, direction: -1); proxy.scrollTo("top") } } label: {
                            Text("Previous").frame(minWidth: 44, minHeight: 44)
                        }.disabled(previous.isEmpty || loading)
                        Spacer()
                        Button { Task { if let next = page?.next { await load(next, direction: 1); proxy.scrollTo("top") } } } label: {
                            Text("Next").frame(minWidth: 44, minHeight: 44)
                        }.disabled(page?.next == nil || loading)
                    }
                    Button { Task { await load(0, direction: 0); proxy.scrollTo("top") } } label: {
                        Text("Reload").frame(minWidth: 44, minHeight: 44)
                    }.disabled(loading)
                }.padding().background(.background)
            }
        }
        .navigationTitle("Pi changelog")
        .task { if page == nil { await load(0, direction: 0) } }
    }

    @MainActor private func load(_ offset: Int, direction: Int) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let revision = direction == 0 ? nil : page?.revision
            guard case .releaseNotes(let value) = try await request(.releaseNotes(offset: offset, revision: revision)) else { throw RemoteFault.incompatiblePi }
            try value.validate()
            guard value.offset == offset, revision == nil || value.revision == revision else { throw RemoteFault.incompatiblePi }
            try Task.checkCancellation()
            if direction > 0, let page { previous.append(page.offset); previous = Array(previous.suffix(64)) }
            else if direction < 0 { _ = previous.popLast() }
            else { previous = [] }
            page = value
        } catch { if !Task.isCancelled { self.error = (error as? RemoteFault ?? .unavailable).explanation } }
    }
}
