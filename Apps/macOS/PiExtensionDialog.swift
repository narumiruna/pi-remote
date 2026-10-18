import PiRemoteCore
import SwiftUI

/// Standard RPC interactions only. Terminal custom components are not transported.
struct PiExtensionDialog: View {
    let dialog: ExtensionDialog
    let request: (SessionAction) async throws -> AppResult
    @Environment(\.macInterfaceMode) private var interfaceMode
    private var theme: MacInterfaceTheme { MacInterfaceTheme(mode: interfaceMode) }
    @State private var value = ""
    @State private var query = ""
    @State private var selection: String?
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var options: [String] { dialog.options.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Keep request text scrollable without moving the response or answer buttons.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(dialog.title).foregroundStyle(theme.accent).accessibilityAddTraits(.isHeader)
                    if !dialog.message.isEmpty { Text(dialog.message).textSelection(.enabled) }
                    if let expires = dialog.expires { Text("Expires " + expires.formatted()).foregroundStyle(theme.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 60, maxHeight: 220)
            .accessibilityIdentifier("extension-dialog-request")
            if let error {
                Text(error)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityIdentifier("extension-dialog-error")
            }
            switch dialog.method {
            case "select":
                TextField("Filter choices", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let selection, options.contains(selection) { answer(value: selection) } }
                    .onMoveCommand { direction in move(direction) }
                List(selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option).onTapGesture(count: 2) { answer(value: option) }
                    }
                }.listStyle(.plain).frame(minHeight: 100)
            case "input":
                TextField("Response", text: $value).textFieldStyle(.plain).focused($focused)
                    .onSubmit { answer(value: value) }
            case "editor":
                TextEditor(text: $value).font(.system(size: 13, design: .monospaced)).focused($focused)
                    .frame(minHeight: 100)
                    .accessibilityLabel("Dialog text")
            case "confirm": Text("Choose Yes or No.").foregroundStyle(theme.muted)
            default: Text("This request cannot be displayed safely. Only cancellation is available.").foregroundStyle(theme.warning)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", role: .cancel) { answer(cancelled: true) }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("extension-dialog-cancel")
                Spacer()
                if dialog.method == "confirm" {
                    Button("No") { answer(confirmed: false) }
                        .accessibilityIdentifier("extension-dialog-no")
                    Button("Yes") { answer(confirmed: true) }
                        .accessibilityIdentifier("extension-dialog-confirm")
                } else if dialog.method == "select" {
                    Button("Select") { if let selection { answer(value: selection) } }
                        .disabled(selection == nil || !options.contains(selection ?? ""))
                        .accessibilityIdentifier("extension-dialog-select")
                } else if dialog.method == "input" || dialog.method == "editor" {
                    Button("Submit") { answer(value: value) }.keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("extension-dialog-submit")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).font(.system(size: 13, design: interfaceMode == .pi ? .monospaced : .default)).foregroundStyle(theme.text)
            .background(theme.background).disabled(sending).interactiveDismissDisabled()
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
            do {
                let result = try await request(.answer(dialog: dialog.id, value: value, confirmed: confirmed, cancelled: cancelled))
                if case .failure(let fault) = result { throw fault }
                // A successful answer stays disabled until the owner removes this request.
            } catch {
                self.error = (error as? RemoteFault ?? .unavailable).explanation
                sending = false
            }
        }
    }
}
