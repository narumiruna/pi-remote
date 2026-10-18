import PiRemoteCore
import SwiftUI

/// Standard RPC interactions only. Terminal custom components are not transported.
struct PiExtensionDialog: View {
    let dialog: ExtensionDialog
    let request: (SessionAction) async throws -> AppResult
    @State private var value = ""
    @State private var query = ""
    @State private var selection: String?
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var options: [String] { dialog.options.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dialog.title).foregroundStyle(PiPalette.accent).accessibilityAddTraits(.isHeader)
            if !dialog.message.isEmpty { Text(dialog.message).textSelection(.enabled) }
            if let expires = dialog.expires { Text("Expires " + expires.formatted()).foregroundStyle(PiPalette.muted) }
            if let error { Text(error).foregroundStyle(PiPalette.warning) }
            switch dialog.method {
            case "select":
                TextField("Filter choices", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let selection, options.contains(selection) { answer(value: selection) } }
                    .onMoveCommand { direction in move(direction) }
                List(selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option).onTapGesture(count: 2) { answer(value: option) }
                    }
                }.listStyle(.plain)
            case "input":
                TextField("Response", text: $value).textFieldStyle(.plain).focused($focused)
                    .onSubmit { answer(value: value) }
            case "editor":
                TextEditor(text: $value).font(.system(size: 13, design: .monospaced)).focused($focused)
                    .accessibilityLabel("Dialog text")
            case "confirm": Text("Choose Yes or No.").foregroundStyle(PiPalette.muted)
            default: Text("This request cannot be displayed safely. Only cancellation is available.").foregroundStyle(PiPalette.warning)
            }
            HStack {
                Button("Cancel", role: .cancel) { answer(cancelled: true) }.keyboardShortcut(.cancelAction)
                Spacer()
                if dialog.method == "confirm" {
                    Button("No") { answer(confirmed: false) }
                    Button("Yes") { answer(confirmed: true) }
                        .accessibilityIdentifier("extension-dialog-confirm")
                } else if dialog.method == "select" {
                    Button("Select") { if let selection { answer(value: selection) } }
                        .disabled(selection == nil || !options.contains(selection ?? ""))
                } else if dialog.method == "input" || dialog.method == "editor" {
                    Button("Submit") { answer(value: value) }.keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("extension-dialog-submit")
                }
            }
        }.padding(20).font(.system(size: 13, design: .monospaced)).foregroundStyle(PiPalette.text)
            .background(PiPalette.background).disabled(sending).interactiveDismissDisabled()
            .onAppear { value = dialog.text; selection = options.first; focused = true }
            .onChange(of: query) { _, _ in selection = options.first }
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !options.isEmpty, direction == .up || direction == .down else { return }
        let index = options.firstIndex { $0 == selection } ?? 0
        selection = options[min(options.count - 1, max(0, index + (direction == .up ? -1 : 1)))]
    }
    private func answer(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do {
                let result = try await request(.answer(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled))
                if case .failure(let fault) = result { throw fault }
            } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
        }
    }
}
