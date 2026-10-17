import PiRemoteCore
import SwiftUI

struct PiConfigurationPicker: View {
    let state: HostSnapshot
    let thinking: Bool
    let request: (SessionAction) async throws -> AppResult
    let done: () -> Void
    @State private var query = ""
    @State private var selected: String?
    @State private var applying = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private var options: [(id: String, label: String, action: SessionAction)] {
        if thinking { return state.thinkingLevels.map { ($0, $0, .thinking(level: $0)) } }
        return state.models.map { ($0.id, $0.name + " · " + $0.id, .model(provider: $0.provider, id: $0.model)) }
    }
    private var filtered: [(id: String, label: String, action: SessionAction)] {
        options.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thinking ? "Thinking level" : "Model").foregroundStyle(PiPalette.accent)
            TextField("Search", text: $query).textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { applySelection() }
                .onMoveCommand { direction in move(direction) }
            if let error { Text(error).foregroundStyle(PiPalette.warning) }
            if filtered.isEmpty { Text("No available choices. Open an idle Pi session first.").foregroundStyle(PiPalette.muted) }
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    ForEach(filtered, id: \.id) { option in
                        Text(option.label).tag(option.id).id(option.id)
                            .onTapGesture(count: 2) { selected = option.id; applySelection() }
                    }
                }.listStyle(.plain)
                    .onChange(of: selected) { _, value in if let value { proxy.scrollTo(value) } }
            }
            HStack {
                Text("↑↓ select · enter apply · esc close").foregroundStyle(PiPalette.muted)
                Spacer()
                Button("Apply") { applySelection() }.keyboardShortcut(.defaultAction)
                    .disabled(applying || selected == nil || state.working || state.selected == nil)
            }
        }.padding(16).font(.system(size: 13, design: .monospaced))
            .background(PiPalette.background)
            .navigationTitle(thinking ? "Thinking level" : "Model")
            .onAppear { selected = filtered.first?.id; searchFocused = true }
            .onChange(of: query) { _, _ in selected = filtered.first?.id }
            .onChange(of: state.context) { _, _ in selected = nil }
            .disabled(applying)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty, direction == .up || direction == .down else { return }
        let index = filtered.firstIndex { $0.id == selected } ?? 0
        selected = filtered[min(filtered.count - 1, max(0, index + (direction == .up ? -1 : 1)))].id
    }
    private func applySelection() {
        guard !applying, !state.working, state.selected != nil,
              let option = filtered.first(where: { $0.id == selected }) else { return }
        applying = true
        Task { @MainActor in
            defer { applying = false }
            do {
                let result = try await request(option.action)
                if case .failure(let fault) = result { throw fault }
                done()
            } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
        }
    }
}

struct PiHotkeysView: View {
    var body: some View {
        Form {
            Section("Prompt editor") {
                Text("Enter: send prompt; steer while working")
                Text("Shift-Enter or Control-Enter: newline")
                Text("Option-Enter: follow-up while working; send while idle")
                Text("Tab or Return with suggestions: complete only")
                Text("Up/Down: suggestions, then local prompt history at text boundaries")
                Text("Escape: dismiss suggestions; otherwise Stop")
            }
            Section("Pi controls") {
                Text("Control-L: select model")
                Text("Shift-Tab: cycle thinking level")
                Text("Control-O: expand or collapse tools")
                Text("Control-T: show or hide thinking")
                Text("Command-Shift-O: resume sessions")
                Text("Command-Shift-P: native action palette")
            }
            Section("Native differences") {
                Text("Completion never executes a command. File completion inserts paths only; Files previews and attaches content. Shell execution requires review. Session-tree navigation is read-only; fork is explicit.")
            }
        }.font(.system(size: 13, design: .monospaced)).navigationTitle("Keyboard shortcuts")
    }
}
