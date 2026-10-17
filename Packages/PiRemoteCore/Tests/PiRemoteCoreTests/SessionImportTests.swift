import Foundation
import Testing
@testable import PiRemoteCore

private func importFixture(_ entries: [JSONValue], version: Int = 3, cwd: String = "/tmp") throws -> Data {
    let header: JSONValue = .object(["type": .string("session"), "version": .number(Double(version)), "id": .string("custom-session-id"), "cwd": .string(cwd)])
    return try ([header] + entries).reduce(into: Data()) { result, entry in
        result.append(try JSONEncoder().encode(entry)); result.append(10)
    }
}
private func importedEntry(_ id: String, parent: JSONValue = .null) -> JSONValue {
    .object(["type": .string("message"), "id": .string(id), "parentId": parent,
             "message": .object(["role": .string("user"), "content": .string("Synthetic\u{2028}import\u{2029}fixture")])])
}

@Test func sessionImportPreservesValidBranchesAndCustomSessionIDs() throws {
    let bytes = try importFixture([importedEntry("root"), importedEntry("a", parent: .string("root")),
                                   importedEntry("b", parent: .string("root")), importedEntry("second-root"),
                                   .object(["type": .string("session_info"), "id": .string("name"), "parentId": .string("b"), "name": .string("Imported fixture")])])
    let value = try SessionImport(data: bytes)
    #expect(value.piID == "custom-session-id" && value.directory == "/tmp")
    #expect(value.title == "Imported fixture" && value.entryCount == 5)
    let crlf = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
    #expect(try SessionImport(data: crlf) == value)
    #expect(SessionAction.importSession(data: bytes).changesSession)
    #expect(SessionAction.importSession(data: bytes).mutates)
    #expect(!SessionAction.importSession(data: bytes).needsSession)
    let action = ClientMessage.request(AppRequest(epoch: UUID(), session: nil, action: .importSession(data: bytes)))
    guard case .request(let request) = try AppPacket<ClientMessage>.decode(AppPacket(action).encode()).payload else { Issue.record("Wrong payload"); return }
    #expect(request.action == .importSession(data: bytes))
}

@Test func sessionImportRejectsInvalidHeadersAndBrokenTreesBeforeDispatch() throws {
    let invalid: [Data] = [Data(), Data([0xFF]), Data("not JSONL".utf8),
        try importFixture([]), try importFixture([importedEntry("a")], version: 2),
        try importFixture([importedEntry("a")], cwd: "relative"),
        try importFixture([importedEntry("a")], cwd: "/tmp\0other"),
        try importFixture([importedEntry("a", parent: .string("missing"))]),
        try importFixture([importedEntry("a"), importedEntry("a")]),
        try importFixture([importedEntry("a", parent: .string("a"))]),
        try importFixture([.object(["type": .string("message"), "id": .string("a"), "parentId": .null])]),
        try importFixture([.object(["type": .string("session"), "id": .string("a"), "parentId": .null])])]
    for bytes in invalid { #expect(throws: RemoteFault.invalidRequest) { try SessionImport(data: bytes) } }
    #expect(throws: RemoteFault.tooLarge) { try SessionImport(data: Data(repeating: 65, count: SessionImport.maximumBytes + 1)) }
}
