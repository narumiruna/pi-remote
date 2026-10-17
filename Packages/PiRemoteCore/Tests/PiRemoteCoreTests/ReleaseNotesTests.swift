import Foundation
@testable import PiRemoteCore
import Testing

@Test func releaseNotesProtocolIsReadOnlyAndBounded() throws {
    let action = SessionAction.releaseNotes(offset: 0, revision: nil)
    #expect(!action.mutates && !action.needsSession && !action.changesSession)
    let page = ReleaseNotesPage(version: "1.3.0", revision: String(repeating: "a", count: 64), offset: 0, totalBytes: 4, text: "🦉", next: nil)
    try page.validate()
    let result = AppResult.releaseNotes(page)
    #expect(try JSONDecoder().decode(AppResult.self, from: JSONEncoder().encode(result)) == result)
    #expect(try JSONDecoder().decode(SessionAction.self, from: JSONEncoder().encode(action)) == action)
    var bad = page; bad.next = 4
    #expect(throws: RemoteFault.incompatiblePi) { try bad.validate() }
    bad = page; bad.offset = Int.max
    #expect(throws: RemoteFault.incompatiblePi) { try bad.validate() }
    bad = page; bad.totalBytes = ReleaseNotesPage.maximumDocumentBytes + 1
    #expect(throws: RemoteFault.incompatiblePi) { try bad.validate() }
    bad = page; bad.text = String(repeating: "a", count: ReleaseNotesPage.maximumPageBytes + 1)
    #expect(throws: RemoteFault.incompatiblePi) { try bad.validate() }
    bad = page; bad.revision = String(repeating: "z", count: 64)
    #expect(throws: RemoteFault.incompatiblePi) { try bad.validate() }
    bad = page; bad.text = ""; bad.next = 0
    #expect(throws: RemoteFault.incompatiblePi) { try bad.validate() }
}
