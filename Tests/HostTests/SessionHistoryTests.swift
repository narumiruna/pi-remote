import Foundation
import PiRemoteCore
import Testing
@testable import PiRemoteHost

private func historyFixture(_ count: Int, lineEnding: String = "\n") throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = root.appendingPathComponent("session.jsonl")
    var lines = [#"{"type":"session","version":3,"id":"fixture","cwd":"/fixture"}"#]
    for index in 0..<count {
        lines.append("{\"type\":\"message\",\"id\":\"e\(index)\",\"parentId\":\"e\(index - 1)\",\"message\":{\"role\":\"user\",\"content\":\"Entry \(index) 日本語\"}}")
    }
    try (lines.joined(separator: lineEnding) + lineEnding).write(to: file, atomically: true, encoding: .utf8)
    return (root, file)
}

@Test func historyCanPageBeyondOneThousandEntriesWithoutRepeats() async throws {
    let (root, file) = try historyFixture(1205, lineEnding: "\r\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory(), session = UUID()
    let append = try FileHandle(forWritingTo: file)
    try append.seekToEnd(); try append.write(contentsOf: Data("{\"incomplete\":".utf8)); try append.close()
    var cursor: UUID?, ids: [String] = []
    repeat {
        let page = try await history.page(session: session, file: file, cursor: cursor)
        #expect(page.items.count <= 100)
        #expect(page.items.allSatisfy { $0.text.contains("日本語") && $0.preview != nil })
        ids += page.items.map(\.id); cursor = page.next
    } while cursor != nil
    #expect(ids.count == 1205 && Set(ids).count == 1205)
    #expect(ids.first == "e1204" && ids.last == "e0")
}

@Test func historyPreviewIsScopedAndDetectsFileReplacement() async throws {
    let (root, file) = try historyFixture(105)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory(), session = UUID()
    let page = try await history.page(session: session, file: file, cursor: nil)
    let preview = try #require(page.items.first?.preview)
    #expect(try await history.preview(session: session, id: preview).text == "Entry 104 日本語")
    await #expect(throws: RemoteFault.expired) { try await history.preview(session: UUID(), id: preview) }
    await #expect(throws: RemoteFault.expired) { try await history.page(session: UUID(), file: file, cursor: page.next) }
    let older = try await history.page(session: session, file: file, cursor: page.next)
    let repeated = try await history.page(session: session, file: file, cursor: page.next)
    #expect(older.items.map(\.id) == repeated.items.map(\.id))
    let fresh = try await history.page(session: session, file: file, cursor: nil)
    try Data("replacement\n".utf8).write(to: file, options: .atomic)
    await #expect(throws: RemoteFault.staleDirectory) { try await history.preview(session: session, id: preview) }
    await #expect(throws: RemoteFault.expired) { try await history.page(session: session, file: file, cursor: fresh.next) }
}

@Test func historyDetailsAreBoundedAndDoNotExposeThinkingSignatures() async throws {
    let (root, file) = try historyFixture(0)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw: JSONValue = .object(["type": .string("message"), "id": .string("assistant"), "message": .object([
        "role": .string("assistant"), "content": .array([
            .object(["type": .string("thinking"), "thinking": .string("Visible thought"), "thinkingSignature": .string("secret-signature")]),
            .object(["type": .string("thinking"), "redacted": .bool(true), "thinking": .string("hidden-thought")]),
            .object(["type": .string("text"), "text": .string(String(repeating: "日本語", count: 50_000))])])])])
    let output = try FileHandle(forWritingTo: file)
    try output.seekToEnd(); try output.write(contentsOf: JSONEncoder().encode(raw) + Data([10])); try output.close()
    let history = SessionHistory(), session = UUID()
    let page = try await history.page(session: session, file: file, cursor: nil)
    let preview = try await history.preview(session: session, id: #require(page.items.first?.preview))
    #expect(preview.truncated && preview.text.utf8.count <= 256 * 1_024)
    #expect(preview.text.contains("Visible thought"))
    #expect(!preview.text.contains("secret-signature") && !preview.text.contains("hidden-thought"))
}

@Test func failedHistoryPagesStillBoundPreviewReferences() async throws {
    let (root, file) = try historyFixture(105)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory(), session = UUID()
    let initial = try await history.page(session: session, file: file, cursor: nil)
    let original = try #require(initial.items.first?.preview)
    let writer = try FileHandle(forWritingTo: file)
    try writer.seekToEnd()
    var text = "invalid\n"
    for index in 0..<99 { text += "{\"type\":\"message\",\"id\":\"new-\(index)\",\"message\":{\"role\":\"user\",\"content\":\"Fixture\"}}\n" }
    try writer.write(contentsOf: Data(text.utf8)); try writer.close()
    for _ in 0..<22 {
        await #expect(throws: RemoteFault.incompatiblePi) { try await history.page(session: session, file: file, cursor: nil) }
    }
    await #expect(throws: RemoteFault.expired) { try await history.preview(session: session, id: original) }
}

@Test func malformedAndOversizedHistoryFailWithoutUnboundedReads() async throws {
    let (root, file) = try historyFixture(0)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory(), session = UUID()
    try Data().write(to: file)
    await #expect(throws: RemoteFault.incompatiblePi) { try await history.page(session: session, file: file, cursor: nil) }
    try Data("partial-header".utf8).write(to: file)
    await #expect(throws: RemoteFault.incompatiblePi) { try await history.page(session: session, file: file, cursor: nil) }
    try Data("invalid\n".utf8).write(to: file)
    await #expect(throws: RemoteFault.incompatiblePi) { try await history.page(session: session, file: file, cursor: nil) }
    try Data(repeating: 120, count: 8 * 1_024 * 1_024 + 1).write(to: file)
    await #expect(throws: RemoteFault.tooLarge) { try await history.page(session: session, file: file, cursor: nil) }
    await #expect(throws: RemoteFault.expired) { try await history.page(session: session, file: nil, cursor: UUID()) }
}
