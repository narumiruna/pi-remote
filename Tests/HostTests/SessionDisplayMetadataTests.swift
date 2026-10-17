import Foundation
import PiRemoteCore
import Testing
@testable import PiRemoteHost

private func displayFixture(_ records: [String]) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("session.jsonl")
    try ([#"{"type":"session","id":"fixture","cwd":"/fixture"}"#] + records).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    return (root, file)
}

@Test func displayMetadataReadsLatestNameAndFirstMeaningfulInstruction() async throws {
    let (root, file) = try displayFixture([
        #"{"type":"session_info","name":"Earlier"}"#,
        #"{"type":"message","message":{"role":"assistant","content":"Not an instruction"}}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"image","data":"unused"},{"type":"text","text":"  \n "}]}}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"  Fix\n the "},{"type":"text","text":" tests  "}]}}"#,
        #"{"type":"message","message":{"role":"user","content":"Later instruction"}}"#,
        #"{"type":"session_info","name":"fixture"}"#
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory()
    let metadata = try await history.displayMetadata(file: file)
    #expect(metadata.name == "fixture")
    #expect(metadata.firstInstruction == "Fix the tests")
    let initialRead = await history.displayMetadataBytesRead
    #expect(try await history.displayMetadata(file: file) == metadata)
    #expect(await history.displayMetadataBytesRead - initialRead <= 65_536)
    // Same-size in-place edits invalidate the identity/size/mtime cache.
    let old = try String(contentsOf: file, encoding: .utf8)
    try old.replacingOccurrences(of: "fixture\"}", with: "renamed\"}").write(to: file, atomically: false, encoding: .utf8)
    #expect(try await history.displayMetadata(file: file).name == "renamed")
}

@Test func displayMetadataDoesNotTrustNamesFromPartialScans() async throws {
    let (root, file) = try displayFixture([
        #"{"type":"session_info","name":"Old name"}"#,
        #"{"type":"message","message":{"role":"user","content":"First instruction"}}"#,
        "{\"type\":\"custom\",\"data\":\"" + String(repeating: "x", count: 2 * 1_024 * 1_024) + "\"}",
        #"{"type":"session_info","name":"Unread new name"}"#
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory()
    let metadata = try await history.displayMetadata(file: file)
    #expect(metadata.name == nil)
    #expect(metadata.firstInstruction == "First instruction")
    #expect(await history.displayMetadataBytesRead == 2 * 1_024 * 1_024)
}

@Test func displayMetadataSupportsStringContentClearedNamesAndBoundedStrings() async throws {
    let (root, file) = try displayFixture([
        #"{"type":"session_info","name":"Old name"}"#,
        #"{"type":"session_info","name":"  "}"#,
        "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"" + String(repeating: "a", count: 8_000) + "\"}}"
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = try await SessionHistory().displayMetadata(file: file)
    #expect(metadata.name == nil)
    #expect((metadata.firstInstruction?.utf8.count ?? 0) <= 4_096)
}

@Test func displayMetadataRejectsSymlinksAndHandlesFinalRecordWithoutNewline() async throws {
    let (root, file) = try displayFixture([])
    defer { try? FileManager.default.removeItem(at: root) }
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"type":"session_info","name":"Latest"}"#.utf8))
    try handle.close()
    let history = SessionHistory()
    #expect(try await history.displayMetadata(file: file).name == "Latest")
    let link = root.appendingPathComponent("link.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    do { _ = try await history.displayMetadata(file: link); Issue.record("Symbolic link must fail") }
    catch { }
}

@Test func displayMetadataValidatesHeaderBeforeCacheAndAfterFileSwap() async throws {
    let (root, file) = try displayFixture([#"{"type":"session_info","name":"Fixture label"}"#])
    defer { try? FileManager.default.removeItem(at: root) }
    let history = SessionHistory()
    // Cache a valid JSONL result, then require a different managed identity.
    #expect(try await history.displayMetadata(file: file).name == "Fixture label")
    let directory = try DirectoryRegistry.identify(root)
    do {
        _ = try await history.displayMetadata(file: file, root: root, piID: "managed", directory: directory)
        Issue.record("Cached metadata must not bypass managed-header validation")
    } catch { }
    let header: JSONValue = .object(["type": .string("session"), "id": .string("managed"), "cwd": .string(root.path)])
    var valid = try JSONEncoder().encode(header)
    valid.append(Data("\n{\"type\":\"session_info\",\"name\":\"Managed label\"}\n".utf8))
    try valid.write(to: file, options: .atomic)
    #expect(try await history.displayMetadata(file: file, root: root, piID: "managed", directory: directory).name == "Managed label")
    let swapped = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "managed", with: "foreign")
    try swapped.write(to: file, atomically: true, encoding: .utf8)
    do {
        _ = try await history.displayMetadata(file: file, root: root, piID: "managed", directory: directory)
        Issue.record("A swapped foreign header must not supply metadata")
    } catch { }
}

@Test func displayMetadataRejectsRedirectedParentBeforeReadingAnyBytes() async throws {
    let (root, file) = try displayFixture([])
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("redirect")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let history = SessionHistory()
    do {
        _ = try await history.displayMetadata(file: link.appendingPathComponent(file.lastPathComponent), root: root)
        Issue.record("A symbolic-link parent must fail before reading")
    } catch { }
    #expect(await history.displayMetadataBytesRead == 0)
}

@Test func localDisplayMetadataDoesNotActivateOrModifySavedSession() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("workspace"), support = root.appendingPathComponent("support")
    let id = UUID(), folder = support.appendingPathComponent("pi-sessions/" + id.uuidString)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("saved.jsonl")
    let header: JSONValue = .object(["type": .string("session"), "id": .string(id.uuidString), "cwd": .string(project.path)])
    var data = try JSONEncoder().encode(header)
    data.append(Data("\n{\"type\":\"session_info\",\"name\":\"workspace\"}\n{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"Saved instruction\"}}\n".utf8))
    try data.write(to: file)
    let directory = try DirectoryRegistry.identify(project)
    let entry: JSONValue = .object([
        "info": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(SessionInfo(id: id, title: "workspace", directory: project.path))),
        "directory": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(directory)),
        "piID": .string(id.uuidString), "folder": .string(folder.absoluteString), "file": .string(file.absoluteString), "hasHistory": .bool(true)
    ])
    let catalog = try JSONEncoder().encode(JSONValue.array([entry]))
    try catalog.write(to: support.appendingPathComponent("sessions.json"))
    let host = try HostCoordinator(support: support, executable: root.appendingPathComponent("must-not-launch"))
    let before = await host.state()
    let metadata = await host.sessionDisplayMetadata(sessionID: id)
    #expect(metadata == SessionDisplayMetadata(name: "workspace", firstInstruction: "Saved instruction"))
    let after = await host.state()
    #expect(after.selected == before.selected && after.sessions == before.sessions && after.messages == before.messages)
    #expect(try Data(contentsOf: file) == data)
    #expect(try Data(contentsOf: support.appendingPathComponent("sessions.json")) == catalog)
    #expect(await host.sessionDisplayMetadata(sessionID: UUID()) == nil)
    await host.shutdown()
}
