import Foundation
import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionImportView: View {
    let request: (SessionAction) async throws -> AppResult
    var canChooseDirectory = false
    var canEnterPath = false
    let imported: () -> Void
    @State private var choosing = false
    @State private var choosingDirectory = false
    @State private var confirming = false
    @State private var loading = false
    @State private var data: Data?
    @State private var review: SessionImport?
    @State private var target: (id: UUID, path: String)?
    @State private var error: String?

    var body: some View {
        Form {
            Text("Choose a Pi JSONL session (versions 1–3). Import copies it into companion-owned storage. It does not attach to or change the source file and does not resend a prompt.")
            Button("Choose session file") { choosing = true }.frame(minHeight: 44).disabled(loading)
            if let error { Text(error).accessibilityIdentifier("import-error") }
            if let review {
                Section("Review import") {
                    Text(review.title)
                    Text("Saved Mac working directory")
                    Text(review.directory ?? "Not recorded. Choose a Mac folder.").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Version \(review.version) · \(review.entryCount) saved entries · \(data?.count ?? 0) bytes")
                    if review.version < 3 { Text("Pi migrates the managed copy to its current session format. The source file remains unchanged.") }
                    if canChooseDirectory {
                        Button("Choose import folder") { choosingDirectory = true }.frame(minHeight: 44).disabled(loading)
                    } else if review.directory == nil {
                        Text("Update Pi Remote for Mac to choose an import directory.")
                    }
                    if let target {
                        Text("Chosen Mac working directory")
                        Text(target.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Only the managed copy's saved directory changes. This does not move project files or rewrite paths in saved messages. Review history before sending anything.")
                        Button("Clear chosen directory") { self.target = nil }.frame(minHeight: 44).disabled(loading)
                    }
                    Text("The Mac must have read and search access to the directory. Import opens Pi there and can load trusted extensions with your Mac permissions. Saved prompts and tool output can be untrusted. Review the transcript before sending anything.")
                    Button("Import and open") { confirming = true }.frame(minHeight: 44)
                        .disabled(loading || (review.directory == nil && target == nil))
                    Button("Discard import", role: .destructive) { clear() }.frame(minHeight: 44).disabled(loading)
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
                data = bytes; review = value; target = nil; error = nil
            } catch {
                clear()
                self.error = (error as? RemoteFault ?? .invalidRequest).explanation
            }
        }
        .sheet(isPresented: $choosingDirectory) {
            NavigationStack {
                DirectoryBrowser(selecting: true, request: request, selectionTitle: "Use this folder", pathEntry: canEnterPath) { id, path in
                    target = (id, path); choosingDirectory = false
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingDirectory = false } } }
            }
            #if os(macOS)
            .frame(width: 520, height: 520)
            #endif
        }
        .alert("Import and open this session?", isPresented: $confirming) {
            Button("Import and open") { Task { await performImport() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(target == nil ? "This closes the current idle Pi session and opens the reviewed copy in its saved Mac directory. No prompt is sent automatically." : "This closes the current idle Pi session and opens the copy in the chosen Mac directory. The source file and project files stay unchanged. No prompt is sent automatically.")
        }
    }

    private func clear() { data = nil; review = nil; target = nil; error = nil }

    @MainActor private func performImport() async {
        guard let data, let review, !loading, review.directory != nil || target != nil else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let action: SessionAction = target.map { .importSessionInDirectory(data: data, directory: $0.id) } ?? .importSession(data: data)
            guard case .ok = try await request(action) else { throw RemoteFault.incompatiblePi }
            clear(); imported()
        } catch { self.error = (error as? RemoteFault ?? .unavailable).explanation }
    }
}
