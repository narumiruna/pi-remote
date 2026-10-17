import Foundation
import PiRemoteCore
import Testing
@testable import PiRemoteHost

private func indexedEntry(_ id: String, text: String = "text") -> JSONValue {
    .object(["type": .string("message"), "id": .string(id), "parentId": .null,
             "message": .object(["role": .string("user"), "content": .string(text)])])
}
private func customEntry(_ id: String, content: JSONValue, display: Bool) -> JSONValue {
    .object(["type": .string("custom_message"), "id": .string(id), "parentId": .null,
             "customType": .string("generic-fixture"), "display": .bool(display), "content": content,
             "details": .object(["not-for-preview": .string("opaque details")])])
}
private func indexedBytes(_ entries: [JSONValue], crlf: Bool = false) throws -> Data {
    let header: JSONValue = .object(["type": .string("session"), "version": .number(3), "id": .string("private-index")])
    var result = Data()
    for value in [header] + entries {
        result.append(try JSONEncoder().encode(value))
        result.append(contentsOf: crlf ? [13, 10] : [10])
    }
    return result
}
private func indexFixture(_ entries: [JSONValue], crlf: Bool = false) throws -> (root: URL, file: URL, bytes: Data) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-index-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = root.appendingPathComponent("session.jsonl"), bytes = try indexedBytes(entries, crlf: crlf)
    try bytes.write(to: file)
    return (root, file, bytes)
}

@Test func historyCustomPreviewNormalizesCanonicalTextAndImagesAndSuppressesHiddenData() async throws {
    let image = try outputImagePNG(seed: 71)
    let block: JSONValue = .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(image.base64EncodedString())])
    let text = String(repeating: "Visible 日本語 ", count: 150)
    let fixture = try indexFixture([
        customEntry("text", content: .string(text), display: true),
        customEntry("image", content: .array([.object(["type": .string("text"), "text": .string("Image context")]), block]), display: true),
        customEntry("hidden", content: .array([.object(["type": .string("text"), "text": .string("hidden content")]), block]), display: false)
    ], crlf: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = SessionHistory(), session = UUID()
    let page = try await history.page(session: session, file: fixture.file, cursor: nil)
    #expect(page.items.first { $0.id == "text" }?.text == DisplayLimit.text(text, bytes: 512))
    #expect(page.items.first { $0.id == "hidden" }?.text == "custom_message")
    let tokens = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["text", "image", "hidden"])
    let full = try await history.displayEntry(session: session, id: #require(tokens["text"]))
    #expect(full.preview.name == "custom_message" && full.preview.text == text && !full.preview.truncated)
    #expect(full.message?["role"]?.string == "custom" && full.message?["details"] == nil)
    let picture = try await history.displayEntry(session: session, id: #require(tokens["image"]))
    #expect(picture.preview.text == "Image context\n[Image]")
    var images = OutputImages()
    let mapped = images.message(try #require(picture.message))
    let reference = try #require(TranscriptReducer.imageReferences(mapped["content"])?.first)
    #expect(try images.image(reference.id).data == image)
    #expect(!String(decoding: try JSONEncoder().encode(mapped), as: UTF8.self).contains(image.base64EncodedString()))
    let hidden = try await history.displayEntry(session: session, id: #require(tokens["hidden"]))
    #expect(hidden.message == nil && hidden.preview.images == nil)
    #expect(hidden.preview.text == "No display text for this entry.")
    #expect(!String(decoding: try JSONEncoder().encode(hidden.preview), as: UTF8.self).contains("hidden content"))
    #expect(try Data(contentsOf: fixture.file) == fixture.bytes)
}

@Test func historyCustomPreviewKeepsTheFullPreviewBudgetAndRejectsMalformedContent() async throws {
    let fixture = try indexFixture([customEntry("large", content: .string(String(repeating: "日本語", count: 100_000)), display: true)])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = SessionHistory(), session = UUID()
    let tokens = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["large"])
    let preview = try await history.preview(session: session, id: #require(tokens["large"]))
    #expect(preview.truncated && preview.text.utf8.count <= 256 * 1_024 && preview.text.utf8.count > 512)
    try indexedBytes([customEntry("invalid", content: .number(7), display: true)]).write(to: fixture.file, options: .atomic)
    let invalid = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["invalid"])
    await #expect(throws: RemoteFault.incompatiblePi) { try await history.preview(session: session, id: #require(invalid["invalid"])) }
}

@Test func historyIndexScansAnUnchangedFileOnceAcrossInspectionPagesAndScopesTokens() async throws {
    let fixture = try indexFixture((0..<1205).map { indexedEntry("e\($0)", text: "Entry \($0) 日本語") }, crlf: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = SessionHistory(), session = UUID()
    var first: UUID?
    for start in stride(from: 0, to: 1205, by: 100) {
        let ids = Set((start..<min(start + 100, 1205)).map { "e\($0)" })
        let tokens = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ids)
        #expect(Set(tokens.keys) == ids)
        if start == 0 { first = tokens["e0"] }
    }
    #expect(await history.inspectionIndexBuilds == 1)
    #expect(await history.inspectionIndexBytesRead == UInt64(fixture.bytes.count))
    #expect(try await history.preview(session: session, id: #require(first)).text == "Entry 0 日本語")
    await #expect(throws: RemoteFault.expired) { try await history.preview(session: UUID(), id: #require(first)) }
    let other = UUID()
    let tokens = try await history.inspectionPreviews(session: other, file: fixture.file, ids: ["e0"])
    #expect(await history.inspectionIndexBuilds == 2)
    #expect(await history.inspectionIndexCount == 2)
    #expect(await history.inspectionIndexBytesRead == UInt64(fixture.bytes.count * 2))
    #expect(tokens["e0"] != first)
    await #expect(throws: RemoteFault.expired) { try await history.preview(session: session, id: #require(tokens["e0"])) }
}

@Test func historyIndexInvalidatesOnAppendSameSizeRewriteAndReplacement() async throws {
    let fixture = try indexFixture([indexedEntry("e0", text: "Original")])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = SessionHistory(), session = UUID()
    let page = try await history.page(session: session, file: fixture.file, cursor: nil)
    let fileToken = try #require(page.items.first?.preview)
    let initial = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["e0"])
    let oldToken = try #require(initial["e0"])
    let writer = try FileHandle(forWritingTo: fixture.file)
    try writer.seekToEnd(); try writer.write(contentsOf: JSONEncoder().encode(indexedEntry("e1")) + Data([10])); try writer.close()
    let appended = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["e0", "e1"])
    #expect(appended.count == 2)
    #expect(await history.inspectionIndexBuilds == 2)
    await #expect(throws: RemoteFault.staleDirectory) { try await history.preview(session: session, id: oldToken) }
    // Existing file-page previews still permit append-only growth.
    #expect(try await history.preview(session: session, id: fileToken).text == "Original")
    let prior = try await history.revision(file: fixture.file)
    try await Task.sleep(for: .milliseconds(2))
    let current = try Data(contentsOf: fixture.file)
    let changed = Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "Original", with: "Modified").utf8)
    #expect(changed.count == current.count)
    let update = try FileHandle(forWritingTo: fixture.file)
    try update.write(contentsOf: changed); try update.close()
    #expect(try await history.revision(file: fixture.file) != prior)
    let rewritten = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["e0"])
    #expect(await history.inspectionIndexBuilds == 3)
    #expect(try await history.preview(session: session, id: #require(rewritten["e0"])).text == "Modified")
    await #expect(throws: RemoteFault.staleDirectory) { try await history.preview(session: session, id: #require(appended["e0"])) }
    try indexedBytes([indexedEntry("replacement")]).write(to: fixture.file, options: .atomic)
    let replacement = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["replacement"])
    #expect(await history.inspectionIndexBuilds == 4)
    #expect(replacement.count == 1)
    await #expect(throws: RemoteFault.staleDirectory) { try await history.preview(session: session, id: #require(rewritten["e0"])) }
}

@Test func historyIndexBoundsCachesAndPreservesTheNewestPreviewTokens() async throws {
    let fixture = try indexFixture((0..<100).map { indexedEntry("e\($0)") })
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = SessionHistory(), sessions = [UUID(), UUID(), UUID()]
    let ids = Set((0..<100).map { "e\($0)" })
    for session in sessions { _ = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ids) }
    #expect(await history.inspectionIndexCount == 2)
    #expect(await history.inspectionIndexBuilds == 3)
    _ = try await history.inspectionPreviews(session: sessions[0], file: fixture.file, ids: ids)
    #expect(await history.inspectionIndexCount == 2)
    #expect(await history.inspectionIndexBuilds == 4)
    let initial = try await history.inspectionPreviews(session: sessions[0], file: fixture.file, ids: ids)
    var latest: [String: UUID] = [:]
    for _ in 0..<21 { latest = try await history.inspectionPreviews(session: sessions[0], file: fixture.file, ids: ids) }
    for token in latest.values { #expect(try await history.preview(session: sessions[0], id: token).text == "text") }
    await #expect(throws: RemoteFault.expired) { try await history.preview(session: sessions[0], id: #require(initial["e0"])) }
    #expect(await history.inspectionIndexBuilds == 4)
}

@Test func historyIndexEnforcesFileRecordCountIdentifierAndCancellationBounds() async throws {
    let fixture = try indexFixture([])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let history = SessionHistory(), session = UUID()
    let oversized = try FileHandle(forWritingTo: fixture.file)
    try oversized.truncate(atOffset: 32 * 1_024 * 1_024 + 1); try oversized.close()
    await #expect(throws: RemoteFault.tooLarge) { try await history.inspectionPreviews(session: session, file: fixture.file, ids: []) }
    #expect(await history.inspectionIndexBytesRead == 0)
    for records in [[indexedEntry("duplicate"), indexedEntry("duplicate")], [indexedEntry(String(repeating: "i", count: 129))]] {
        try indexedBytes(records).write(to: fixture.file, options: .atomic)
        await #expect(throws: RemoteFault.incompatiblePi) { try await history.inspectionPreviews(session: session, file: fixture.file, ids: []) }
    }
    try indexedBytes((0...10_000).map { indexedEntry(String($0)) }).write(to: fixture.file, options: .atomic)
    await #expect(throws: RemoteFault.tooLarge) { try await history.inspectionPreviews(session: session, file: fixture.file, ids: []) }
    try indexedBytes([indexedEntry("large", text: String(repeating: "x", count: 8 * 1_024 * 1_024))]).write(to: fixture.file, options: .atomic)
    await #expect(throws: RemoteFault.tooLarge) { try await history.inspectionPreviews(session: session, file: fixture.file, ids: []) }
    try Data("{\"type\":\"session\"}\nnot-json\n".utf8).write(to: fixture.file, options: .atomic)
    await #expect(throws: RemoteFault.incompatiblePi) { try await history.inspectionPreviews(session: session, file: fixture.file, ids: []) }
    try indexedBytes([indexedEntry("valid")]).write(to: fixture.file, options: .atomic)
    let tooMany = Set((0...100).map(String.init))
    await #expect(throws: RemoteFault.tooLarge) { try await history.inspectionPreviews(session: session, file: fixture.file, ids: tooMany) }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["valid"])
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await history.inspectionIndexCount == 0)
    let valid = try await history.inspectionPreviews(session: session, file: fixture.file, ids: ["valid"])
    #expect(valid.count == 1)
}
