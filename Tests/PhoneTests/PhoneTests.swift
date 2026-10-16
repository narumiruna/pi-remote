import PiRemoteCore
import SwiftUI
import UIKit
import XCTest
@testable import PiRemote

@MainActor
final class PhoneTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults) -> Void) {
        let name = "PiRemoteTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testLaunchIsLockedAndBackgroundClearsRemoteState() {
        withPreferences { defaults in
            let model = PhoneModel(defaults: defaults)
            XCTAssertTrue(model.locked)
            XCTAssertTrue(model.covered)
            XCTAssertNil(model.state)
            model.state = HostSnapshot(host: UUID(), epoch: UUID())
            model.connected = true; model.connecting = true; model.pairing = true
            model.pairingText = "private pairing input"
            model.panel = "directory"
            model.preview = FilePreview(name: "test", text: "private preview", truncated: false)
            model.scene(.background)
            XCTAssertTrue(model.locked)
            XCTAssertTrue(model.covered)
            XCTAssertFalse(model.connected || model.connecting || model.pairing || model.unlocking)
            XCTAssertNil(model.state)
            XCTAssertNil(model.panel)
            XCTAssertNil(model.preview)
            XCTAssertTrue(model.pairingText.isEmpty)
        }
    }

    func testSecretAccessWithoutUnlockFailsClosed() {
        let secrets = ProtectedSecrets()
        XCTAssertThrowsError(try secrets.get("test")) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
        XCTAssertThrowsError(try secrets.put(Data([1]), account: "test")) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
        XCTAssertThrowsError(try secrets.remove("test")) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
        secrets.invalidate()
        XCTAssertThrowsError(try secrets.get("test"))
    }

    func testDraftsSurviveSessionChangesAndBackgroundWithoutAutomaticReplacement() {
        withPreferences { defaults in
            let model = PhoneModel(defaults: defaults), host = UUID()
            model.chooseMac(host); model.locked = false
            var first = HostSnapshot(host: host, epoch: UUID()); first.selected = UUID()
            var second = first; second.selected = UUID(); second.sequence = 1
            model.applyState(first); model.text = "First draft"
            model.applyState(second); XCTAssertEqual(model.text, "")
            model.text = "Second draft"; model.applyState(first)
            XCTAssertEqual(model.text, "First draft")
            first.draftID = UUID(); first.draft = "Offered text"
            model.applyState(first)
            XCTAssertEqual(model.text, "First draft")
            XCTAssertEqual(model.editorOffer?.text, "Offered text")
            model.acceptEditorOffer(model.editorOffer!)
            XCTAssertEqual(model.text, "Offered text")
            model.applyState(second); XCTAssertEqual(model.text, "Second draft")
            model.scene(.background)
            let restarted = PhoneModel(defaults: defaults)
            XCTAssertTrue(restarted.locked)
            XCTAssertEqual(restarted.text, "Second draft")
        }
    }

    func testStaleEditorOffersCannotReplaceAnotherSessionsDraft() {
        withPreferences { defaults in
            let model = PhoneModel(defaults: defaults), host = UUID()
            model.chooseMac(host); model.locked = false
            var state = HostSnapshot(host: host, epoch: UUID()); state.selected = UUID()
            model.applyState(state); model.text = "Existing draft"
            let offer = EditorOffer(id: UUID(), session: state.selected, text: "Old session text")
            state.selected = UUID(); model.applyState(state); model.text = "New session draft"
            model.acceptEditorOffer(offer)
            XCTAssertEqual(model.text, "New session draft")
            model.lock(); model.acceptEditorOffer(offer)
            XCTAssertEqual(model.text, "New session draft")
        }
    }

    func testAttachmentScopesChangeOnMacSessionAndLockBoundaries() {
        withPreferences { defaults in
            let model = PhoneModel(defaults: defaults)
            let initial = model.contentScope
            let host = UUID(); model.chooseMac(host)
            XCTAssertNotEqual(model.contentScope, initial)
            model.locked = false
            var state = HostSnapshot(host: host, epoch: UUID()); state.selected = UUID()
            model.applyState(state)
            let first = model.contentScope
            state.selected = UUID(); model.applyState(state)
            XCTAssertNotEqual(model.contentScope, first)
            let current = model.contentScope; model.lock()
            XCTAssertNotEqual(model.contentScope, current)
            model.applyState(state)
            XCTAssertNil(model.state)
            XCTAssertFalse(model.connected)
        }
    }

    func testActionsFromOldHostEpochAreRejectedBeforeDispatch() async {
        let name = "PiRemoteTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = PhoneModel(defaults: defaults), host = UUID()
        model.chooseMac(host); model.locked = false
        var state = HostSnapshot(host: host, epoch: UUID()); state.selected = UUID()
        model.applyState(state); model.text = "Existing draft"
        let oldContext = state.context, oldRequest = model.scopedRequest(for: state)
        state.epoch = UUID(); model.applyState(state)
        do { _ = try await oldRequest(.command(name: "fixture", arguments: "")); XCTFail("A stale UI action must not dispatch") }
        catch { XCTAssertEqual(error as? RemoteFault, .conflict) }
        model.send(context: oldContext)
        XCTAssertEqual(model.fault, .conflict)
        XCTAssertFalse(model.sending)
        XCTAssertEqual(model.text, "Existing draft")
    }

    func testResendConfirmationCannotCrossSessionBoundary() {
        withPreferences { defaults in
            defaults.set(true, forKey: "uncertainAction")
            let model = PhoneModel(defaults: defaults), host = UUID()
            model.chooseMac(host); model.locked = false
            var state = HostSnapshot(host: host, epoch: UUID()); state.selected = UUID()
            model.applyState(state); model.text = "Original instruction"
            model.send(context: state.context)
            XCTAssertTrue(model.confirmResend)
            state.selected = UUID(); model.applyState(state); model.text = "Another session draft"
            XCTAssertFalse(model.confirmResend)
            model.resend()
            XCTAssertTrue(model.needsActionReview)
            XCTAssertFalse(model.sending)
            XCTAssertEqual(model.text, "Another session draft")
            XCTAssertEqual(model.fault, .conflict)
        }
    }

    func testConversationRendersRunStatesMarkdownAndThinkingWithLargeText() async throws {
        for phase in ["idle", "working", "retrying", "compacting", "interrupted"] {
            for dark in [false, true] {
                for compact in [false, true] {
                    var state = HostSnapshot(host: UUID(), epoch: UUID())
                    state.selected = UUID(); state.phase = phase
                    state.messages = [
                        TranscriptMessage(role: "user", text: "Review this change."),
                        TranscriptMessage(role: "assistant", text: "## Result\n\n- **Checked**\n\n| File | Status |\n|---|---|\n| main.swift | Ready |\n\n```swift\nlet value = 1\n```", thinking: "Fixture thinking text", streaming: state.working),
                        TranscriptMessage(role: "tool", text: "Read file\nFixture output", isError: phase == "interrupted")
                    ]
                    let view = VStack(spacing: 0) {
                        Text("Fixture · /project · " + phase).font(.caption).padding(8)
                        ConversationView(state: state, text: .constant("A draft"), delivery: .constant(.steer),
                                         sending: false, send: {}, stop: {}, extras: { EmptyView() })
                    }
                    .frame(width: compact ? 375 : 402, height: compact ? 367 : 874)
                    .background(.background).ignoresSafeArea()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, .accessibility3)
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
                    let previous = scene.windows.first { $0.isKeyWindow }
                    let window = UIWindow(windowScene: scene)
                    defer { window.isHidden = true; previous?.makeKeyAndVisible() }
                    let controller = UIHostingController(rootView: view)
                    controller.overrideUserInterfaceStyle = dark ? .dark : .light
                    window.rootViewController = controller
                    window.frame = CGRect(x: 0, y: 0, width: compact ? 375 : 402, height: compact ? 367 : 874)
                    window.makeKeyAndVisible()
                    controller.view.frame = window.bounds
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    let rendered = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                    }
                    if phase == "working" {
                        let attachment = XCTAttachment(image: rendered)
                        attachment.name = "Conversation-\(dark ? "dark" : "light")-\(compact ? "compact" : "full")"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
    }
}
