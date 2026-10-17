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
