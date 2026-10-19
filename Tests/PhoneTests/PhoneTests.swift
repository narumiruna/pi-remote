import PiRemoteClient
import PiRemoteCore
import SwiftUI
import UIKit
import XCTest
@testable import PiRemote

@MainActor
final class PhoneTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PiRemoteTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
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

    func testDismissedHostErrorDoesNotReturnUntilANewFailureOrContext() {
        withPreferences { defaults in
            let model = PhoneModel(defaults: defaults), host = UUID()
            model.chooseMac(host); model.locked = false
            var state = HostSnapshot(host: host, epoch: UUID()); state.error = .permissionDenied
            model.applyState(state)
            XCTAssertEqual(model.visibleFault, .permissionDenied)
            model.reviewedFault()
            XCTAssertNil(model.visibleFault)
            state.sequence += 1; model.applyState(state)
            XCTAssertNil(model.visibleFault)
            state.error = nil; model.applyState(state)
            state.error = .permissionDenied; model.applyState(state)
            XCTAssertEqual(model.visibleFault, .permissionDenied)
            model.reviewedFault(); state.epoch = UUID(); model.applyState(state)
            XCTAssertEqual(model.visibleFault, .permissionDenied)
            model.lock()
        }
    }

    func testMacTextAttachmentPreservesDraftAndRejectsStaleOrLockedActions() throws {
        try withPreferences { defaults in
            let model = PhoneModel(defaults: defaults), host = UUID()
            model.chooseMac(host); model.locked = false; model.covered = false
            var state = HostSnapshot(host: host, epoch: UUID()); state.selected = UUID()
            model.applyState(state); model.text = "Existing draft"
            let preview = FilePreview(name: "Mac.swift", text: "let attached = 42", truncated: false)
            try model.attachText(preview, context: state.context)
            let attached = model.text
            XCTAssertTrue(attached.hasPrefix("Existing draft\n\nFile: Mac.swift"))
            XCTAssertFalse(model.sending)
            let reloaded = PhoneModel(defaults: defaults)
            XCTAssertEqual(reloaded.text, attached)
            var stale = state.context; stale.session = UUID()
            XCTAssertThrowsError(try model.attachText(preview, context: stale)) { XCTAssertEqual($0 as? RemoteFault, .conflict) }
            XCTAssertEqual(model.text, attached)
            model.lock()
            XCTAssertThrowsError(try model.attachText(preview, context: state.context)) { XCTAssertEqual($0 as? RemoteFault, .unauthorized) }
            XCTAssertEqual(model.text, attached)
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

private actor SendConnection: PhoneConnection {
    private(set) var actions: [SessionAction] = []
    private(set) var contexts: [SessionContext] = []
    private let holdRequests: Bool
    private var pending: CheckedContinuation<AppResult, any Error>?

    init(holdRequests: Bool) { self.holdRequests = holdRequests }
    func pair(code: PairingCode, device: UUID, name: String) throws -> SavedMac { throw RemoteFault.unsupportedFeature }
    func updates() -> AsyncStream<ClientUpdate> { AsyncStream { $0.finish() } }
    func connect(_ mac: SavedMac) {}
    func disconnect(fault: RemoteFault) {}
    func forget(_ mac: SavedMac) {}
    func request(_ action: SessionAction, context: SessionContext) async throws -> AppResult {
        actions.append(action); contexts.append(context)
        guard holdRequests else { return .ok }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish() {
        pending?.resume(returning: .ok)
        pending = nil
    }
}

@MainActor
final class PhoneSendTests: XCTestCase {
    private func withFixture(uncertain: Bool = false, holdRequests: Bool = false,
                             _ body: @MainActor (PhoneModel, SendConnection, UserDefaults, HostSnapshot) async throws -> Void) async throws {
        let name = "PiRemoteSendTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(uncertain, forKey: "uncertainAction")
        let client = SendConnection(holdRequests: holdRequests)
        let model = PhoneModel(defaults: defaults, connection: client)
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        let host = UUID()
        model.chooseMac(host); model.locked = false; model.covered = false
        var state = HostSnapshot(host: host, epoch: UUID())
        state.selected = UUID(); state.phase = "idle"
        model.applyState(state)
        try await body(model, client, defaults, state)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The send fixture did not settle")
    }

    func testEmptyTextWithoutImageDoesNotSendOrOpenResendConfirmation() async throws {
        for uncertain in [false, true] {
            try await withFixture(uncertain: uncertain) { model, client, defaults, state in
                model.text = ""
                model.send(context: state.context)
                XCTAssertFalse(model.sending)
                XCTAssertFalse(model.confirmResend)
                try await Task.sleep(for: .milliseconds(30))
                let actions = await client.actions
                XCTAssertTrue(actions.isEmpty, "Empty input must not send any request")
                XCTAssertEqual(model.text, "")
                XCTAssertNil(model.image)
                XCTAssertEqual(model.needsActionReview, uncertain)
                XCTAssertEqual(defaults.bool(forKey: "uncertainAction"), uncertain)
                XCTAssertEqual(model.fault, uncertain ? .unknownOutcome : nil)
                model.lock()
                XCTAssertEqual(PhoneModel(defaults: defaults, connection: client).text, "")
            }
        }
    }

    func testWhitespaceOnlyTextWithoutImageKeepsDraftAndDoesNotSendOrOpenResendConfirmation() async throws {
        for uncertain in [false, true] {
            for text in ["   ", "\t\r\n", " \n\t\u{00a0}\u{2003} "] {
                try await withFixture(uncertain: uncertain) { model, client, defaults, state in
                    model.text = text
                    model.send(context: state.context)
                    XCTAssertFalse(model.sending)
                    XCTAssertFalse(model.confirmResend)
                    try await Task.sleep(for: .milliseconds(30))
                    let actions = await client.actions
                    XCTAssertTrue(actions.isEmpty, "Whitespace-only input must not send any request")
                    XCTAssertEqual(model.text, text, "A rejected send must not clear or trim the draft")
                    XCTAssertEqual(model.needsActionReview, uncertain)
                    XCTAssertEqual(defaults.bool(forKey: "uncertainAction"), uncertain)
                    XCTAssertEqual(model.fault, uncertain ? .unknownOutcome : nil)
                    model.lock()
                    XCTAssertEqual(PhoneModel(defaults: defaults, connection: client).text, text)
                }
            }
        }
    }

    func testNonemptyTextIsSentWithoutTrimmingAndKeptUntilAcknowledged() async throws {
        try await withFixture(holdRequests: true) { model, client, defaults, state in
            let text = " \n\tReview this change.\n  "
            model.text = text
            model.send(context: state.context)
            try await wait { await client.actions.count == 1 }
            let actions = await client.actions, contexts = await client.contexts
            XCTAssertEqual(actions, [.prompt(text: text, delivery: .prompt, image: nil)])
            XCTAssertEqual(contexts, [state.context])
            XCTAssertTrue(model.sending)
            XCTAssertEqual(model.text, text)
            XCTAssertEqual(PhoneModel(defaults: defaults, connection: client).text, text)
            await client.finish()
            try await wait { !model.sending }
            XCTAssertEqual(model.text, "")
            XCTAssertEqual(PhoneModel(defaults: defaults, connection: client).text, "")
        }
    }

    func testSuccessfulSendDoesNotClearDraftEditedWhileWaiting() async throws {
        try await withFixture(holdRequests: true) { model, client, defaults, state in
            model.text = "Submitted instruction"
            model.send(context: state.context)
            try await wait { await client.actions.count == 1 }
            model.text = "New unsent draft"
            await client.finish()
            try await wait { !model.sending }
            XCTAssertEqual(model.text, "New unsent draft")
            XCTAssertEqual(PhoneModel(defaults: defaults, connection: client).text, "New unsent draft")
            let actions = await client.actions
            XCTAssertEqual(actions, [.prompt(text: "Submitted instruction", delivery: .prompt, image: nil)])
        }
    }

    func testImageOnlyPromptIsSentAndAttachmentIsKeptUntilAcknowledged() async throws {
        for text in ["", " \n\t "] {
            try await withFixture(holdRequests: true) { model, client, _, state in
                let image = ImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png")
                model.text = text; model.image = image
                model.send(context: state.context)
                try await wait { await client.actions.count == 1 }
                let actions = await client.actions, contexts = await client.contexts
                XCTAssertEqual(actions, [.prompt(text: text, delivery: .prompt, image: image)])
                XCTAssertEqual(contexts, [state.context])
                XCTAssertTrue(model.sending)
                XCTAssertEqual(model.text, text)
                XCTAssertEqual(model.image, image)
                await client.finish()
                try await wait { !model.sending }
                XCTAssertEqual(model.text, "")
                XCTAssertNil(model.image)
            }
        }
    }
}
