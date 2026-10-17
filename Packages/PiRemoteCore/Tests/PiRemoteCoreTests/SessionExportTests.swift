import Foundation
import Testing
@testable import PiRemoteCore

@Test func sessionExportsValidateAndRoundTripWithoutTruncation() throws {
    let value = SessionExport(data: Data("<!doctype html><html>é</html>".utf8))
    try value.validate()
    #expect(try AppPacket<AppResult>.decode(AppPacket(AppResult.exportSession(value)).encode()).payload == .exportSession(value))
    #expect(SessionAction.exportSession.needsSession)
    #expect(!SessionAction.exportSession.mutates)
    #expect(throws: RemoteFault.incompatiblePi) { try SessionExport(data: Data()).validate() }
    #expect(throws: RemoteFault.incompatiblePi) { try SessionExport(data: Data([0xFF])).validate() }
    #expect(throws: RemoteFault.tooLarge) { try SessionExport(data: Data(repeating: 65, count: SessionExport.maximumBytes + 1)).validate() }
    let maximum = SessionExport(data: Data(repeating: 65, count: SessionExport.maximumBytes))
    try maximum.validate()
    #expect(try AppPacket(AppResult.exportSession(maximum)).encode().count < 4 * 1_024 * 1_024)
}

@Test func jsonlExportsPreserveBytesAndOlderHTMLRepliesStillDecode() throws {
    let data = Data(#"""
{"type":"session","version":3,"id":"export-fixture","cwd":"/tmp"}
{"type":"message","id":"user","parentId":null,"message":{"role":"user","content":"Saved fixture"}}
"""#.utf8)
    let value = SessionExport(data: data, format: .jsonl)
    try value.validate()
    #expect(try AppPacket<AppResult>.decode(AppPacket(AppResult.exportSession(value)).encode()).payload == .exportSession(value))
    #expect(throws: RemoteFault.invalidRequest) { try SessionExport(data: Data("not JSONL".utf8), format: .jsonl).validate() }
    let oldReply = try JSONEncoder().encode(["data": Data("Old HTML fixture".utf8).base64EncodedString()])
    let old = try JSONDecoder().decode(SessionExport.self, from: oldReply)
    #expect(old.format == .html && old.data == Data("Old HTML fixture".utf8))
    #expect(SessionAction.exportJSONL.needsSession && !SessionAction.exportJSONL.mutates)
}
