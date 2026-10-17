import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionHTMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SessionExportView: View {
    let request: (SessionAction) async throws -> AppResult
    @State private var consent = false
    @State private var loading = false
    @State private var document: SessionHTMLDocument?
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section("Review before export") {
                Text("HTML export can include the entire session tree: prompts, thinking, tool arguments, file contents, command output, system instructions and exposed secrets. Review History before continuing.")
                Text("The app does not redact this file or upload it. Saving to a cloud-backed location can send it to that storage provider. HTML contains active content; open it only in a trusted browser.")
                Toggle("I have reviewed the session and accept exporting its contents", isOn: $consent)
                    .disabled(loading || document != nil).accessibilityIdentifier("export-consent")
            }
            if let error { Text(error).accessibilityIdentifier("export-error") }
            if saved { Text("Export saved").accessibilityIdentifier("export-saved") }
            if loading { ProgressView("Preparing HTML export") }
            if let document {
                Text("Complete HTML file: \(document.data.count) bytes. Nothing has been uploaded by Pi Remote.")
                Button("Save HTML file") { saving = true }.frame(minHeight: 44)
                Button("Discard export", role: .destructive) { self.document = nil; consent = false; saved = false }
                    .frame(minHeight: 44)
            } else {
                Button("Prepare HTML export") { Task { await prepare() } }
                    .frame(minHeight: 44).disabled(!consent || loading)
            }
            Text("Pi needs a saved conversation to export. Exports larger than 2 MiB are rejected, not truncated.").font(.caption)
        }
        .navigationTitle("Export session")
        .fileExporter(isPresented: $saving, document: document, contentType: .html, defaultFilename: "pi-session.html") { result in
            switch result {
            case .success: saved = true; document = nil; consent = false
            case .failure: error = "The file was not saved. Retry or discard the export."
            }
        }
    }

    @MainActor private func prepare() async {
        guard consent, !loading else { return }
        loading = true; error = nil; saved = false
        defer { loading = false }
        do {
            guard case .exportSession(let value) = try await request(.exportSession) else { throw RemoteFault.incompatiblePi }
            try value.validate()
            document = SessionHTMLDocument(data: value.data)
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
