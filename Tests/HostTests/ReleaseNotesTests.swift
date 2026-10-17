import Foundation
import PiRemoteCore
@testable import PiRemoteHost
import Testing

private struct ReleaseNotesInstallation {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var executable: URL { root.appendingPathComponent("dist/bundle/cli.js") }
    var notes: URL { root.appendingPathComponent("CHANGELOG.md") }
    init(text: String) throws {
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data(#"{"name":"@earendil-works/pi-coding-agent","version":"1.3.0","bin":{"pi":"dist/bundle/cli.js"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data(text.utf8).write(to: notes)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func releaseNotesPagesPreserveUnicodeAndBindTheSelectedInstallation() throws {
    let text = String(repeating: "Release 🦉\n", count: 40_000)
    let fixture = try ReleaseNotesInstallation(text: text)
    defer { fixture.remove() }
    var offset = 0
    var revision: String?
    var joined = ""
    repeat {
        let page = try PiReleaseNotes.page(executable: fixture.executable, offset: offset, revision: revision)
        try page.validate()
        #expect(page.version == "1.3.0" && page.offset == offset)
        #expect(page.totalBytes == text.utf8.count)
        joined += page.text; revision = page.revision
        guard let next = page.next else { break }
        #expect(next > offset)
        offset = next
    } while true
    #expect(joined == text)
    let link = fixture.root.appendingPathComponent("pi")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.executable)
    #expect(try PiReleaseNotes.page(executable: link, offset: 0, revision: nil).revision == revision)
    try Data("Changed".utf8).write(to: fixture.notes)
    #expect(throws: RemoteFault.expired) { try PiReleaseNotes.page(executable: fixture.executable, offset: offset, revision: revision) }
    let other = fixture.root.appendingPathComponent("other.js")
    try Data().write(to: other)
    #expect(throws: RemoteFault.unsupportedFeature) { try PiReleaseNotes.page(executable: other, offset: 0, revision: nil) }
}

@Test(arguments: [0, ReleaseNotesPage.maximumPageBytes, ReleaseNotesPage.maximumDocumentBytes])
func releaseNotesAcceptEmptyAndExactSizeBoundaries(count: Int) throws {
    let fixture = try ReleaseNotesInstallation(text: String(repeating: "a", count: count))
    defer { fixture.remove() }
    let first = try PiReleaseNotes.page(executable: fixture.executable, offset: 0, revision: nil)
    try first.validate()
    #expect(first.text.utf8.count == min(count, ReleaseNotesPage.maximumPageBytes))
    let end = try PiReleaseNotes.page(executable: fixture.executable, offset: count, revision: first.revision)
    #expect(end.text.isEmpty && end.next == nil)
    if count <= ReleaseNotesPage.maximumPageBytes { #expect(first.next == nil) }
}

@Test func releaseNotesRejectInvalidOffsetsResourcesAndLayouts() throws {
    let fixture = try ReleaseNotesInstallation(text: "🦉 notes")
    defer { fixture.remove() }
    let page = try PiReleaseNotes.page(executable: fixture.executable, offset: 0, revision: nil)
    for offset in [-1, 1, 999, Int.max] {
        #expect(throws: RemoteFault.invalidRequest) { try PiReleaseNotes.page(executable: fixture.executable, offset: offset, revision: page.revision) }
    }
    #expect(throws: RemoteFault.invalidRequest) { try PiReleaseNotes.page(executable: fixture.executable, offset: 4, revision: nil) }
    try Data([0xff]).write(to: fixture.notes)
    #expect(throws: RemoteFault.incompatiblePi) { try PiReleaseNotes.page(executable: fixture.executable, offset: 0, revision: nil) }
    try Data(repeating: 65, count: ReleaseNotesPage.maximumDocumentBytes + 1).write(to: fixture.notes)
    #expect(throws: RemoteFault.tooLarge) { try PiReleaseNotes.page(executable: fixture.executable, offset: 0, revision: nil) }
    try FileManager.default.removeItem(at: fixture.notes)
    try FileManager.default.createSymbolicLink(at: fixture.notes, withDestinationURL: fixture.executable)
    #expect(throws: RemoteFault.permissionDenied) { try PiReleaseNotes.page(executable: fixture.executable, offset: 0, revision: nil) }
    try FileManager.default.removeItem(at: fixture.notes)
    try FileManager.default.createDirectory(at: fixture.notes, withIntermediateDirectories: false)
    #expect(throws: RemoteFault.unsupportedFeature) { try PiReleaseNotes.page(executable: fixture.executable, offset: 0, revision: nil) }
}

@Test func releaseNotesHostActionNeedsNoActiveSessionOrChild() async throws {
    let fixture = try ReleaseNotesInstallation(text: "Installed notes")
    defer { fixture.remove() }
    let host = try HostCoordinator(support: fixture.root.appendingPathComponent("support"), executable: fixture.executable)
    let request = AppRequest(epoch: host.epoch, session: nil, action: .releaseNotes(offset: 0, revision: nil))
    let result = await host.handle(request, device: UUID())
    guard case .releaseNotes(let page) = result else { Issue.record("Expected installed release notes"); return }
    #expect(page.text == "Installed notes")
    #expect(await host.handle(AppRequest(epoch: UUID(), session: nil, action: request.action), device: UUID()) == .failure(.unknownOutcome))
    let lease = AuthorizationLease(); lease.revoke()
    #expect(await host.handle(request, device: UUID(), authorization: lease) == .failure(.unauthorized))
    await host.shutdown()
}
