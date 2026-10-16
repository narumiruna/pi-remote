import Foundation
import Testing
@testable import PiRemoteCore

@Test func runtimeSettingsDecodeStrictModesAndOmitLocalPiState() throws {
    let data = Data(#"{"steeringMode":"all","followUpMode":"one-at-a-time","autoCompactionEnabled":true,"sessionFile":"/private/session.jsonl"}"#.utf8)
    let settings = try JSONDecoder().decode(RuntimeSettings.self, from: data)
    #expect(settings == RuntimeSettings(steeringMode: .all, followUpMode: .oneAtATime, autoCompactionEnabled: true))
    let encoded = try AppPacket(AppResult.runtimeSettings(settings)).encode()
    #expect(try AppPacket<AppResult>.decode(encoded).payload == .runtimeSettings(settings))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("session.jsonl"))
    let invalid = Data(#"{"steeringMode":"unknown","followUpMode":"all","autoCompactionEnabled":true}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RuntimeSettings.self, from: invalid) }
}

@Test func runtimeAndCopyActionsKeepSessionAndMutationRules() {
    #expect(SessionAction.closeSession.needsSession && SessionAction.closeSession.mutates && SessionAction.closeSession.changesSession)
    #expect(SessionAction.lastAssistant.needsSession && !SessionAction.lastAssistant.mutates)
    #expect(SessionAction.runtimeSettings.needsSession && !SessionAction.runtimeSettings.mutates)
    #expect(SessionAction.queueMode(kind: .steering, mode: .all).mutates)
    #expect(SessionAction.autoCompaction(enabled: false).mutates)
}
