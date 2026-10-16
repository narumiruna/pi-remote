import Foundation
import Testing
@testable import PiRemoteCore

private let statisticsJSON = #"{"userMessages":5,"assistantMessages":5,"toolCalls":12,"toolResults":12,"totalMessages":22,"tokens":{"input":50000,"output":10000,"cacheRead":40000,"cacheWrite":5000,"total":105000},"cost":0.45,"contextUsage":{"tokens":60000,"contextWindow":200000,"percent":30},"sessionFile":"/private/not-for-transport.jsonl"}"#

@Test func statisticsRoundTripExcludesLocalSessionPaths() throws {
    let value = try JSONDecoder().decode(SessionStatistics.self, from: Data(statisticsJSON.utf8))
    try value.validate()
    #expect(value.tokens.total == 105_000)
    #expect(value.contextUsage?.percent == 30)
    let packet = try AppPacket(AppResult.statistics(value)).encode()
    #expect(!String(decoding: packet, as: UTF8.self).contains("not-for-transport"))
    #expect(try AppPacket<AppResult>.decode(packet).payload == .statistics(value))
    #expect(!SessionAction.statistics.mutates && SessionAction.statistics.needsSession)
}

@Test func statisticsAllowUnavailableContextAfterCompaction() throws {
    let data = statisticsJSON.replacingOccurrences(of: "\"tokens\":60000", with: "\"tokens\":null")
        .replacingOccurrences(of: "\"percent\":30", with: "\"percent\":null")
    let value = try JSONDecoder().decode(SessionStatistics.self, from: Data(data.utf8))
    try value.validate()
    #expect(value.contextUsage?.tokens == nil && value.contextUsage?.percent == nil)
}

@Test func statisticsRejectInvalidValues() throws {
    let original = try JSONDecoder().decode(SessionStatistics.self, from: Data(statisticsJSON.utf8))
    var invalid = original; invalid.tokens.total = -1
    #expect(throws: RemoteFault.incompatiblePi) { try invalid.validate() }
    invalid = original; invalid.cost = .infinity
    #expect(throws: RemoteFault.incompatiblePi) { try invalid.validate() }
    invalid = original; invalid.contextUsage?.percent = .nan
    #expect(throws: RemoteFault.incompatiblePi) { try invalid.validate() }
    invalid = original; invalid.contextUsage?.contextWindow = 0
    #expect(throws: RemoteFault.incompatiblePi) { try invalid.validate() }
    invalid = original; invalid.contextUsage = nil
    try invalid.validate()
}
