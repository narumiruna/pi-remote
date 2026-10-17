import CoreTransferable
import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionExportDocument: FileDocument, Transferable, Sendable {
    static var jsonLinesType: UTType { UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText }
    static var readableContentTypes: [UTType] { [.html, jsonLinesType] }
    var data: Data
    var format: SessionExportFormat
    var contentType: UTType { format == .html ? .html : Self.jsonLinesType }
    var filename: String { format == .html ? "pi-session.html" : "pi-session.jsonl" }
    init(_ value: SessionExport) { data = value.data; format = value.format }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        format = configuration.contentType.conforms(to: Self.jsonLinesType) ? .jsonl : .html
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
    func sharingData() throws -> Data {
        try SessionExport(data: data, format: format).validate()
        return data
    }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { try $0.sharingData() }
            .exportingCondition { $0.format == .html }
            .suggestedFileName { $0.filename }
        DataRepresentation(exportedContentType: jsonLinesType) { try $0.sharingData() }
            .exportingCondition { $0.format == .jsonl }
            .suggestedFileName { $0.filename }
    }
}

struct SessionExportView: View {
    let request: (SessionAction) async throws -> AppResult
    var jsonlEnabled = false
    @State private var format: SessionExportFormat = .html
    @State private var consent = false
    @State private var loading = false
    @State private var document: SessionExportDocument?
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            if jsonlEnabled {
                Picker("Export format", selection: $format) {
                    Text("HTML").tag(SessionExportFormat.html)
                    Text("JSONL (.jsonl)").tag(SessionExportFormat.jsonl)
                }.disabled(loading || document != nil)
            }
            Section("Review before export") {
                Text(format == .html ? "HTML export can include the entire session tree: prompts, thinking, tool arguments, file contents, command output, system instructions and exposed secrets. Review History before continuing." : "JSONL exports the active branch, not abandoned branches. It can include prompts, thinking, tool arguments, file contents, command output, system instructions and exposed secrets. Review History before continuing.")
                Text("The app does not redact this file or upload it automatically. Saving to cloud storage or choosing a sharing service can send it to that provider or recipient. HTML contains active content; open it only in a trusted browser.")
                Toggle("I have reviewed the session and accept exporting its contents", isOn: $consent)
                    .disabled(loading || document != nil).accessibilityIdentifier("export-consent")
            }
            if let error { Text(error).accessibilityIdentifier("export-error") }
            if saved { Text("Export saved").accessibilityIdentifier("export-saved") }
            if loading { ProgressView("Preparing export") }
            if let document {
                Text("Complete \(document.format == .html ? "HTML" : "JSONL") file: \(document.data.count) bytes. Preparing it does not upload it.")
                Button(document.format == .html ? "Save HTML file" : "Save JSONL file") { saving = true }.frame(minHeight: 44)
                NavigationLink("Review sharing options") { SessionExportShareView(document: document) }.frame(minHeight: 44)
                Button("Discard export", role: .destructive) { self.document = nil; consent = false; saved = false }
                    .frame(minHeight: 44)
            } else {
                Button(format == .html ? "Prepare HTML export" : "Prepare JSONL export") { Task { await prepare() } }
                    .frame(minHeight: 44).disabled(!consent || loading)
            }
            Text(format == .html ? "Pi needs a saved conversation for HTML export. Exports larger than 2 MiB are rejected, not truncated." : "JSONL can export an empty branch. Export input and output larger than 2 MiB are rejected, not truncated.").font(.caption)
        }
        .navigationTitle("Export session")
        .fileExporter(isPresented: $saving, document: document, contentType: document?.contentType ?? .html, defaultFilename: document?.filename ?? "pi-session.html") { result in
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
            guard case .exportSession(let value) = try await request(format == .html ? .exportSession : .exportJSONL),
                  value.format == format else { throw RemoteFault.incompatiblePi }
            try value.validate()
            document = SessionExportDocument(value)
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}

private struct SessionExportShareView: View {
    let document: SessionExportDocument
    @State private var consent = false
    var body: some View {
        Form {
            Text(document.filename + " · \(document.data.count) bytes")
            Text("A sharing service can upload this complete file or send it to other people. Access depends on that service and can be public. The file is not redacted. HTML contains active content.")
            Text("Cancel the service picker if you do not want to send it. Pi Remote cannot verify delivery or recall a shared file.")
            Toggle("I accept sending this export to the service or recipient I choose", isOn: $consent)
                .accessibilityIdentifier("share-consent")
            ShareLink(item: document, preview: SharePreview(document.filename)) {
                Label("Choose sharing service", systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }.disabled(!consent).accessibilityIdentifier("share-service")
        }.navigationTitle("Share export")
    }
}
