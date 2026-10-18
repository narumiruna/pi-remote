import PiRemoteCore
import SwiftUI

/// Display order follows Pi's catalog: first-seen providers, then their original model order.
struct PiConfigurationChoices: Equatable {
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        let model: String?
        let current: Bool
        let action: SessionAction
    }
    struct Group: Identifiable, Equatable {
        let id: String
        let provider: String?
        var choices: [Choice]
    }

    let context: SessionContext
    let thinking: Bool
    let query: String
    let groups: [Group]
    let hasChoices: Bool
    var choices: [Choice] { groups.flatMap(\.choices) }
    var initialSelection: String? { choices.first(where: \.current)?.id ?? choices.first?.id }

    init(state: HostSnapshot, thinking: Bool, query: String = "") {
        context = state.context
        self.thinking = thinking
        self.query = query
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String...) -> Bool {
            search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
        }
        var groups: [Group] = []
        var seen = Set<String>()
        if thinking {
            let choices = state.thinkingLevels.filter { seen.insert($0).inserted && matches($0) }.map {
                Choice(id: $0, name: $0, model: nil, current: $0 == state.thinking, action: .thinking(level: $0))
            }
            if !choices.isEmpty { groups = [Group(id: "thinking", provider: nil, choices: choices)] }
            hasChoices = !state.thinkingLevels.isEmpty
        } else {
            for model in state.models where seen.insert(model.id).inserted {
                let choice = Choice(id: model.id, name: model.name, model: model.model,
                                    current: model.id == state.model, action: .model(provider: model.provider, id: model.model))
                if let index = groups.firstIndex(where: { $0.id == model.provider }) {
                    groups[index].choices.append(choice)
                } else {
                    groups.append(Group(id: model.provider, provider: model.provider, choices: [choice]))
                }
            }
            hasChoices = !state.models.isEmpty
            groups = groups.compactMap { group in
                let filtered = group.choices.filter { matches($0.name, $0.model ?? "", group.provider ?? "", $0.id) }
                return filtered.isEmpty ? nil : Group(id: group.id, provider: group.provider, choices: filtered)
            }
        }
        self.groups = groups
    }

    func moved(from selected: String?, direction: MoveCommandDirection) -> String? {
        guard direction == .up || direction == .down, !choices.isEmpty else { return selected }
        let index = choices.firstIndex { $0.id == selected } ?? 0
        return choices[min(choices.count - 1, max(0, index + (direction == .up ? -1 : 1)))].id
    }
}

/// Keeps selection and request completion bound to the displayed picker context.
struct PiConfigurationSelection {
    struct Apply: Equatable {
        let id: UUID
        let context: SessionContext
        let thinking: Bool
        let choice: PiConfigurationChoices.Choice
    }
    private(set) var displayed: PiConfigurationChoices?
    var selected: String?
    private(set) var pending: Apply?
    private(set) var error: String?
    var applying: Bool { pending != nil }

    mutating func update(_ choices: PiConfigurationChoices) {
        let changedContext = displayed?.context != choices.context || displayed?.thinking != choices.thinking
        if changedContext {
            pending = nil
            error = nil
        }
        if changedContext || displayed?.query != choices.query || !choices.choices.contains(where: { $0.id == selected }) {
            selected = choices.initialSelection
        }
        displayed = choices
    }

    func canApply(_ choices: PiConfigurationChoices, state: HostSnapshot) -> Bool {
        !applying && !state.working && state.selected != nil && displayed == choices &&
            choices.context == state.context && choices.choices.contains { $0.id == selected }
    }

    mutating func begin(_ choices: PiConfigurationChoices, state: HostSnapshot) -> Apply? {
        guard canApply(choices, state: state), let choice = choices.choices.first(where: { $0.id == selected }) else { return nil }
        let apply = Apply(id: UUID(), context: choices.context, thinking: choices.thinking, choice: choice)
        pending = apply
        error = nil
        return apply
    }

    /// Return true only when this request may close this picker.
    mutating func finish(_ apply: Apply, fault: RemoteFault?) -> Bool {
        guard pending == apply, displayed?.context == apply.context, displayed?.thinking == apply.thinking else { return false }
        pending = nil
        if let fault { error = fault.explanation; return false }
        return displayed?.choices.contains { $0.id == apply.choice.id && $0.action == apply.choice.action } == true
    }

    mutating func invalidate() { displayed = nil; pending = nil }
}

struct PiConfigurationPicker: View {
    let state: HostSnapshot
    let thinking: Bool
    let request: (SessionAction) async throws -> AppResult
    let done: () -> Void
    @State private var query = ""
    @State private var selection = PiConfigurationSelection()
    @FocusState private var searchFocused: Bool

    private var choices: PiConfigurationChoices { .init(state: state, thinking: thinking, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thinking ? "Thinking level" : "Model").foregroundStyle(PiPalette.accent)
            TextField("Search", text: $query).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("pi-configuration-search")
                .onSubmit { applySelection() }
                .onKeyPress(.upArrow) {
                    selection.selected = choices.moved(from: selection.selected, direction: .up)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    selection.selected = choices.moved(from: selection.selected, direction: .down)
                    return .handled
                }
            if let error = selection.error { Text(error).foregroundStyle(PiPalette.warning) }
            if choices.choices.isEmpty {
                Text(choices.hasChoices ? "No matching choices." : "No available choices. Open an idle Pi session first.")
                    .foregroundStyle(PiPalette.muted)
            }
            ScrollViewReader { proxy in
                List(selection: $selection.selected) {
                    ForEach(choices.groups) { group in
                        Section {
                            ForEach(group.choices) { option in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name)
                                        if let model = option.model { Text(model).font(.system(size: 11, design: .monospaced)).foregroundStyle(PiPalette.muted) }
                                    }
                                    Spacer()
                                    if option.current { Label("Current", systemImage: "checkmark").foregroundStyle(PiPalette.accent) }
                                }.tag(option.id).id(option.id)
                                    .onTapGesture(count: 2) { selection.selected = option.id; applySelection() }
                            }
                        } header: {
                            if let provider = group.provider {
                                Text(provider).font(.system(size: 11, design: .monospaced)).foregroundStyle(PiPalette.muted).textCase(nil)
                            }
                        }
                    }
                }.listStyle(.plain)
                    .onChange(of: selection.selected) { _, value in if let value { proxy.scrollTo(value) } }
            }
            HStack {
                Text("↑↓ select · enter apply · esc close").foregroundStyle(PiPalette.muted)
                Spacer()
                Button(selection.applying ? "Applying…" : "Apply") { applySelection() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pi-configuration-apply")
                    .disabled(!selection.canApply(choices, state: state))
            }
        }.padding(16).font(.system(size: 13, design: .monospaced))
            .foregroundStyle(PiPalette.text)
            .background(PiPalette.background)
            .navigationTitle(thinking ? "Thinking level" : "Model")
            .onAppear { searchFocused = true }
            .onChange(of: choices, initial: true) { _, value in selection.update(value) }
            .onDisappear { selection.invalidate() }
            .disabled(selection.applying)
    }

    private func applySelection() {
        guard let apply = selection.begin(choices, state: state) else { return }
        let request = request
        Task { @MainActor in
            // The picker can change context before this task starts.
            guard selection.pending == apply else { return }
            let fault: RemoteFault?
            do {
                let result = try await request(apply.choice.action)
                if case .failure(let failure) = result { fault = failure } else { fault = nil }
            } catch { fault = error as? RemoteFault ?? .unavailable }
            if selection.finish(apply, fault: fault) { done() }
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
