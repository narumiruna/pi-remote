import PiRemoteCore
import SwiftUI
import XCTest
@testable import PiRemote

@MainActor
final class PhoneTests: XCTestCase {
    func testLaunchIsLockedAndBackgroundClearsRemoteState() {
        let model = PhoneModel()
        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.covered)
        XCTAssertNil(model.state)
        model.state = HostSnapshot(host: UUID(), epoch: UUID())
        model.connected = true
        model.pairingText = "private pairing input"
        model.panel = "directory"
        model.scene(.background)
        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.covered)
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.state)
        XCTAssertNil(model.panel)
        XCTAssertTrue(model.pairingText.isEmpty)
    }

    func testSecretAccessWithoutUnlockFailsClosed() {
        let secrets = ProtectedSecrets()
        XCTAssertThrowsError(try secrets.get("test")) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
        XCTAssertThrowsError(try secrets.put(Data([1]), account: "test")) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
        XCTAssertThrowsError(try secrets.remove("test")) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
        secrets.invalidate()
        XCTAssertThrowsError(try secrets.get("test"))
    }

    func testConversationRendersIdleAndStreamingWithLargeText() throws {
        for working in [false, true] {
            for dark in [false, true] {
                var state = HostSnapshot(host: UUID(), epoch: UUID())
                state.selected = UUID()
                state.phase = working ? "working" : "idle"
                state.messages = [
                    TranscriptMessage(role: "user", text: "Review this change."),
                    TranscriptMessage(role: "assistant", text: "**Result**\n```swift\nlet value = 1\n```", streaming: working),
                    TranscriptMessage(role: "tool", text: "Read file\nFixture output")
                ]
                let view = ConversationView(state: state, text: .constant("A draft"), delivery: .constant(.steer),
                                            sending: false, send: {}, stop: {}, extras: { EmptyView() })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, .accessibility3)
                    .frame(width: 402, height: 874)
                let renderer = ImageRenderer(content: view)
                XCTAssertNotNil(renderer.uiImage)
            }
        }
    }
}
