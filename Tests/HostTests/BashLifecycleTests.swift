import Foundation
import Testing
import PiRemoteCore

// Shared protocol checks do not require a process or provider.
@Test func bashConsentFieldIsRequiredAndCancellationIsSessionBound() throws {
    let missingConsent = Data(#"{"bash":{"command":"fixture","excludeFromContext":false}}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SessionAction.self, from: missingConsent) }
    let action = SessionAction.abortBash(id: UUID())
    #expect(action.mutates)
    #expect(action.needsSession)
    #expect(!action.changesSession)
    #expect(try JSONDecoder().decode(SessionAction.self, from: JSONEncoder().encode(action)) == action)
}
