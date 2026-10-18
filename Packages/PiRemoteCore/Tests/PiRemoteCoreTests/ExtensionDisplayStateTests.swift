import Foundation
import Testing
@testable import PiRemoteCore

@Test func extensionDisplaySnapshotRoundTripAndLegacyDecode() throws {
    var snapshot = HostSnapshot(host: UUID(), epoch: UUID())
    #expect(snapshot.capabilities.contains("extension-display"))
    let legacyData = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: legacyData).extensionDisplay == nil)
    #expect(!(try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])).keys.contains("extensionDisplay"))

    snapshot.extensionDisplay = ExtensionDisplayState(
        statuses: [ExtensionStatus(id: "status", text: "Ready")],
        widgets: [ExtensionWidget(id: "widget", text: "Above"), ExtensionWidget(id: "lower", text: "Below", placement: .belowEditor)],
        notices: [ExtensionNotice(id: "notice", text: "Info"), ExtensionNotice(id: "warning", text: "Warning", severity: .warning), ExtensionNotice(id: "error", text: "Error", severity: .error)]
    )
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    #expect(snapshot.extensionDisplay?.widgets.first?.placement == .aboveEditor)
    #expect(snapshot.extensionDisplay?.notices.first?.severity == .info)
}

@Test func extensionDisplayRejectsUnknownPlacementAndSeverity() throws {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ExtensionWidget.self, from: Data(#"{"id":"widget","text":"text","placement":"sideways"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ExtensionNotice.self, from: Data(#"{"id":"notice","text":"text","severity":"critical"}"#.utf8))
    }
}
