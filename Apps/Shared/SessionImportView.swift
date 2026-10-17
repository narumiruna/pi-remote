import Foundation
import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionImportView: View {
    let request: (SessionAction) async throws -> AppResult
    let imported: () -> Void
    @State private var choosing = false
    @State private var confirming = false
    @State private var loading = false
    @State private var data: Data?
    @State private var review: SessionImport?
    @State private var error: String?

    var body: some View {
        Form {
            Text("Choose a Pi JSONL session (versions 1–3). Import copies it into companion-owned storage. It does not attach to or change the source file and does not resend a prompt.")
            Button("Choose session file") { choosing = true }.frame(minHeight: 44).disabled(loading)
            if let error { Text(error).accessibilityIdentifier("import-error") }
            if let review {
                Section("Review import") {
                    Text(review.title)
                    Text("Mac working directory")
                    Text(review.directory).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Version \(review.version) · \(review.entryCount) saved entries · \(data?.count ?? 0) bytes")
                    if review.version < 3 { Text("Pi migrates the managed copy to its current session format. The source file remains unchanged.") }
                    Text("The Mac must have read and search access to this directory. Import opens Pi there and can load its trusted extensions with your Mac permissions. Saved instructions and tool output can be untrusted. Review the transcript before sending anything.")
                    Button("Import and open") { confirming = true }.frame(minHeight: 44).disabled(loading)
                    Button("Discard import", role: .destructive) { data = nil; self.review = nil }.frame(minHeight: 44).disabled(loading)
                }
            }
            if loading { ProgressView("Importing session") }
            Text("Files larger than 2 MiB, malformed entries and invalid tree links are rejected, not truncated.").font(.caption)
        }
        .navigationTitle("Import session")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let bytes = try file.read(upToCount: SessionImport.maximumBytes + 1) ?? Data()
                let value = try SessionImport(data: bytes)
                data = bytes; review = value; error = nil
            } catch {
                data = nil; review = nil
                self.error = (error as? RemoteFault ?? .invalidRequest).explanation
            }
        }
        .alert("Import and open this session?", isPresented: $confirming) {
            Button("Import and open") { Task { await performImport() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This closes the current idle Pi session and opens the reviewed copy in its saved Mac directory. No prompt is sent automatically.") }
    }

    @MainActor private func performImport() async {
        guard let data, review != nil, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard case .ok = try await request(.importSession(data: data)) else { throw RemoteFault.incompatiblePi }
            self.data = nil; review = nil; imported()
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
