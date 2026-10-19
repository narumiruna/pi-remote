import Foundation
import PiRemoteClient
import PiRemoteCore
import XCTest
@testable import PiRemote

private actor RecoveryConnection: PhoneConnection {
    private(set) var actions: [SessionAction] = []
    private(set) var connections = 0
    private(set) var forgotten: [UUID] = []
    private var pending: [Int: CheckedContinuation<AppResult, any Error>] = [:]

    func pair(code: PairingCode, device: UUID, name: String) throws -> SavedMac { throw RemoteFault.unsupportedFeature }
    func updates() -> AsyncStream<ClientUpdate> { AsyncStream { $0.finish() } }
    func connect(_ mac: SavedMac) { connections += 1 }
    func disconnect(fault: RemoteFault) {}
    func forget(_ mac: SavedMac) { forgotten.append(mac.id) }
    func request(_ action: SessionAction, context: SessionContext) async throws -> AppResult {
        let index = actions.count
        actions.append(action)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ result: Result<AppResult, any Error>, request index: Int? = nil) {
        guard let index = index ?? pending.keys.min() else { return }
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}

@MainActor
final class PhoneRecoveryTests: XCTestCase {
    private func fixture() -> (PhoneModel, RecoveryConnection, UserDefaults, String, HostSnapshot) {
        let name = "PiRemoteRecoveryTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let client = RecoveryConnection()
        let mac = SavedMac(id: UUID(), name: "Recovery Mac", url: URL(string: "wss://fixture.invalid:7443/")!, certificate: Data(), device: UUID())
        let model = PhoneModel(defaults: defaults, connection: client)
        model.saved = [mac]; model.chooseMac(mac.id)
        model.locked = false; model.covered = false
        var state = HostSnapshot(host: mac.id, epoch: UUID())
        state.selected = UUID(); state.phase = "waiting"
        state.dialogs = [dialog("first")]
        model.applyState(state)
        return (model, client, defaults, name, state)
    }

    private func dialog(_ id: String) -> ExtensionDialog {
        ExtensionDialog(id: id, method: "confirm", title: "Review request", message: "Explicit answer required", options: [], text: "", expires: nil)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fixture did not settle")
    }

    func testLocalCloseReconnectAndSnapshotUpdatesNeverReplayOrReopenDismissedRequest() async throws {
        let (model, client, defaults, name, state) = fixture()
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(model.panel, "dialog")
        model.connected = false
        model.answerDialog(state.dialogs[0], in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
        XCTAssertEqual(model.dialogFault, .unavailable)
        model.closePanel()
        XCTAssertNil(model.panel)
        XCTAssertEqual(model.state?.dialogs, state.dialogs, "Local Close must preserve the Mac request")
        model.connect()
        try await wait { await client.connections == 1 && !model.connecting }
        var update = state; update.sequence += 1; model.applyState(update)
        XCTAssertNil(model.panel, "Reconnect must not reopen a locally closed request")
        update.sequence += 1; model.applyState(update)
        XCTAssertNil(model.panel)
        let actions = await client.actions
        XCTAssertTrue(actions.isEmpty, "Reconnect must not send or cancel an answer")
        model.reopenDialog()
        XCTAssertEqual(model.panel, "dialog")
        model.closePanel()
        update.dialogs = [dialog("second")]; model.applyState(update)
        XCTAssertEqual(model.panel, "dialog", "A new request must not inherit dismissal")
        model.closePanel(); update.selected = UUID(); model.applyState(update)
        XCTAssertEqual(model.panel, "dialog", "A new session must not inherit dismissal")
        model.closePanel(); update.epoch = UUID(); model.applyState(update)
        XCTAssertEqual(model.panel, "dialog", "A new host epoch must not inherit dismissal")
        model.closePanel(); update.dialogs = []; model.applyState(update)
        update.dialogs = [dialog("second")]; model.applyState(update)
        XCTAssertEqual(model.panel, "dialog", "A resolved and replaced request must be presented")
    }

    func testAnswerFailureIsInlineDuplicateAnswersAreBlockedAndRetryIsExplicit() async throws {
        let (model, client, defaults, name, state) = fixture()
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        let pending = state.dialogs[0]
        model.answerDialog(pending, in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
        model.answerDialog(pending, in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
        XCTAssertTrue(model.dialogSending)
        try await wait { await client.actions.count == 1 }
        await client.finish(.failure(RemoteFault.permissionDenied))
        try await wait { !model.dialogSending }
        XCTAssertEqual(model.dialogFault, .permissionDenied)
        XCTAssertEqual(model.panel, "dialog")
        model.closePanel(); model.applyState(state); model.reopenDialog()
        XCTAssertEqual(model.dialogFault, .permissionDenied)
        let beforeRetry = await client.actions.count
        XCTAssertEqual(beforeRetry, 1)
        model.answerDialog(pending, in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
        try await wait { await client.actions.count == 2 }
        await client.finish(.success(.ok))
        try await wait { !model.dialogSending }
        XCTAssertNil(model.dialogFault)
        XCTAssertNil(model.panel)
        model.applyState(state)
        XCTAssertNil(model.panel, "A lagging snapshot must not reopen an answered request")
    }

    func testAcknowledgedUnchangedSnapshotCannotReopenOrDispatchAnotherAnswer() async throws {
        let (model, client, defaults, name, state) = fixture()
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        let scope = model.contentScope
        model.answerDialog(state.dialogs[0], in: state, scope: scope, value: nil, confirmed: true, cancelled: false)
        try await wait { await client.actions.count == 1 }
        await client.finish(.success(.ok))
        try await wait { !model.dialogSending }
        model.applyState(state)
        XCTAssertNil(model.pendingDialog)
        model.reopenDialog()
        XCTAssertNil(model.panel)
        model.answerDialog(state.dialogs[0], in: state, scope: scope, value: nil, confirmed: true, cancelled: false)
        XCTAssertFalse(model.dialogSending)
        model.connected = false; model.connect()
        try await wait { !model.connecting }
        model.applyState(state)
        model.reopenDialog()
        XCTAssertNil(model.panel)
        XCTAssertNil(model.pendingDialog)
        let actions = await client.actions
        XCTAssertEqual(actions.count, 1, "An acknowledged answer must not be dispatched again")
        var next = state; next.dialogs = []
        model.applyState(next); model.applyState(state)
        XCTAssertNotNil(model.pendingDialog, "A changed pending scope must clear acknowledgement")
        XCTAssertEqual(model.panel, "dialog")
    }

    func testDelayedAnswerAfterLockCannotRestoreDialogOrReplayOnReconnect() async throws {
        for success in [false, true] {
            let (model, client, defaults, name, state) = fixture()
            defer { model.lock(); defaults.removePersistentDomain(forName: name) }
            model.answerDialog(state.dialogs[0], in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
            try await wait { await client.actions.count == 1 }
            model.lock()
            await client.finish(success ? .success(.ok) : .failure(RemoteFault.permissionDenied))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(model.locked)
            XCTAssertNil(model.state)
            XCTAssertNil(model.panel)
            XCTAssertNil(model.pendingDialog)
            XCTAssertNil(model.dialogFault)
            XCTAssertFalse(model.dialogSending)
            model.locked = false; model.covered = false
            model.connect()
            try await wait { !model.connecting }
            model.applyState(state)
            XCTAssertEqual(model.panel, "dialog")
            XCTAssertNotNil(model.pendingDialog)
            let actions = await client.actions
            XCTAssertEqual(actions.count, 1, "Unlock and reconnect must not replay an answer")
        }
    }

    func testDelayedAnswerAfterForgetCannotRestoreRemovedMacOrDialog() async throws {
        for success in [false, true] {
            let (model, client, defaults, name, state) = fixture()
            defer { model.lock(); defaults.removePersistentDomain(forName: name) }
            let mac = try XCTUnwrap(model.saved.first)
            model.answerDialog(state.dialogs[0], in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
            try await wait { await client.actions.count == 1 }
            model.requestForget(mac); model.confirmForget()
            try await wait { model.saved.isEmpty }
            await client.finish(success ? .success(.ok) : .failure(RemoteFault.permissionDenied))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(model.selectedMac)
            XCTAssertNil(model.state)
            XCTAssertNil(model.panel)
            XCTAssertNil(model.pendingDialog)
            XCTAssertNil(model.dialogFault)
            XCTAssertNil(model.fault)
            XCTAssertFalse(model.dialogSending)
            XCTAssertFalse(model.connected)
            model.connect(); model.applyState(state)
            XCTAssertNil(model.state)
            let actions = await client.actions
            XCTAssertEqual(actions.count, 1, "A forgotten Mac must not receive a repeated answer")
        }
    }

    func testStaleSuccessfulAnswerCannotClearReplacementAnswerBusyState() async throws {
        for changeSession in [false, true] {
            let (model, client, defaults, name, state) = fixture()
            defer { model.lock(); defaults.removePersistentDomain(forName: name) }
            model.answerDialog(state.dialogs[0], in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
            try await wait { await client.actions.count == 1 }
            var next = state
            if changeSession { next.selected = UUID() } else { next.dialogs = [dialog("replacement")] }
            model.applyState(next)
            model.answerDialog(next.dialogs[0], in: next, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
            try await wait { await client.actions.count == 2 }
            await client.finish(.success(.ok), request: 0)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(model.dialogSending, "Old completion must not clear the new answer token")
            XCTAssertNil(model.dialogFault)
            XCTAssertNotNil(model.pendingDialog)
            XCTAssertEqual(model.panel, "dialog")
            model.answerDialog(next.dialogs[0], in: next, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
            let actions = await client.actions
            XCTAssertEqual(actions.count, 2, "The replacement answer must remain protected against duplicates")
            await client.finish(.success(.ok), request: 1)
            try await wait { !model.dialogSending }
            XCTAssertNil(model.pendingDialog)
            XCTAssertNil(model.panel)
        }
    }

    func testLateAnswerFailureCannotChangeNewDialogOrSessionPresentation() async throws {
        for changeSession in [false, true] {
            let (model, client, defaults, name, state) = fixture()
            defer { model.lock(); defaults.removePersistentDomain(forName: name) }
            model.answerDialog(state.dialogs[0], in: state, scope: model.contentScope, value: nil, confirmed: true, cancelled: false)
            try await wait { await client.actions.count == 1 }
            var next = state
            if changeSession { next.selected = UUID() } else { next.dialogs = [dialog("new")] }
            model.applyState(next)
            XCTAssertFalse(model.dialogSending)
            await client.finish(.failure(RemoteFault.permissionDenied))
            // Wait for the old task to process its continuation.
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(model.dialogFault)
            XCTAssertFalse(model.dialogSending)
            XCTAssertEqual(model.panel, "dialog")
            XCTAssertEqual(model.state?.context, next.context)
            if changeSession { XCTAssertNil(model.fault) }
        }
    }

    func testUnknownAnswerOutcomeIsShownWithoutAutomaticReplayAndOfflineActionsDoNotDispatch() async throws {
        let (model, client, defaults, name, state) = fixture()
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        model.answerDialog(state.dialogs[0], in: state, scope: model.contentScope, value: nil, confirmed: nil, cancelled: true)
        try await wait { await client.actions.count == 1 }
        await client.finish(.failure(RemoteFault.unknownOutcome))
        try await wait { !model.dialogSending }
        XCTAssertEqual(model.dialogFault, .unknownOutcome)
        XCTAssertTrue(model.needsActionReview)
        model.connected = false; model.text = "Keep this offline draft"
        model.send(context: state.context)
        XCTAssertFalse(model.sending)
        do { _ = try await model.scopedRequest(for: state)(.stop); XCTFail("Offline Stop must fail") }
        catch { XCTAssertEqual(error as? RemoteFault, .unavailable) }
        let preview = FilePreview(name: "fixture", text: "text", truncated: false)
        XCTAssertThrowsError(try model.attachText(preview, context: state.context))
        model.closePanel(); model.connect()
        try await wait { !model.connecting }
        model.applyState(state)
        XCTAssertNil(model.panel)
        XCTAssertEqual(model.text, "Keep this offline draft")
        let actions = await client.actions
        XCTAssertEqual(actions.count, 1)
    }

    func testForgetNeedsConfirmationAndCancelKeepsPairingAndConnection() async throws {
        let (model, client, defaults, name, _) = fixture()
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        let mac = try XCTUnwrap(model.saved.first)
        model.requestForget(mac)
        XCTAssertEqual(model.macToForget?.name, "Recovery Mac")
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.saved, [mac])
        model.macToForget = nil // The native Cancel action.
        model.confirmForget()
        let cancelled = await client.forgotten
        XCTAssertTrue(cancelled.isEmpty)
        XCTAssertEqual(model.selectedMac, mac.id)
        XCTAssertTrue(model.connected)
        model.requestForget(mac); model.confirmForget()
        try await wait { model.saved.isEmpty }
        let forgotten = await client.forgotten
        XCTAssertEqual(forgotten, [mac.id])
        XCTAssertNil(model.selectedMac)
        XCTAssertNil(model.state)
        XCTAssertFalse(model.connected)
    }

    func testAnswerCallbackCannotCrossLocalConnectionGenerationEvenForSameMacSessionAndDialog() async {
        let (model, client, defaults, name, state) = fixture()
        defer { model.lock(); defaults.removePersistentDomain(forName: name) }
        let scope = model.contentScope
        model.chooseMac(state.host); model.applyState(state)
        model.answerDialog(state.dialogs[0], in: state, scope: scope, value: nil, confirmed: true, cancelled: false)
        XCTAssertFalse(model.dialogSending)
        let actions = await client.actions
        XCTAssertTrue(actions.isEmpty)
    }

    func testStatusWidgetsAndRecoveryRemainAvailableWithZeroTypedNotices() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.notices = ["Recovered state", "Build ready", "Above editor", "Below editor"]
        state.extensionDisplay = ExtensionDisplayState(
            statuses: [ExtensionStatus(id: "build", text: "Build ready")],
            widgets: [ExtensionWidget(id: "above", text: "Above editor", placement: .aboveEditor),
                      ExtensionWidget(id: "below", text: "Below editor", placement: .belowEditor)])
        XCTAssertTrue(PhoneExtensionNotices.notices(in: state).isEmpty)
        XCTAssertEqual(PhoneExtensionNotices.information(in: state), ["Recovered state", "Build ready", "Above editor", "Below editor"])
        state.notices.append("Warning")
        state.extensionDisplay?.notices = [ExtensionNotice(id: "warning", text: "Warning", severity: .warning),
                                          ExtensionNotice(id: "recovery", text: "Recovered state", severity: .warning)]
        XCTAssertEqual(PhoneExtensionNotices.information(in: state), ["Build ready", "Above editor", "Below editor"])
        XCTAssertEqual(PhoneExtensionNotices.notices(in: state).map(\.severity), [.warning, .warning])
    }

    func testLegacyTerminalControlsAndRecoveryNoticeLimitDoNotDuplicateTypedNotices() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        let rawNotices = (0..<8).map { "\u{001B}[31mNotice \($0)\u{001B}[0m" }
        state.notices = ["Recovered state", "\u{001B}[32mReady\u{001B}[0m", "Widget"] + rawNotices
        state.extensionDisplay = ExtensionDisplayState(
            statuses: [ExtensionStatus(id: "status", text: "Ready")],
            widgets: [ExtensionWidget(id: "widget", text: "Widget")],
            notices: [ExtensionNotice(id: "recovery", text: "Recovered state", severity: .warning)] +
                (1..<8).map { ExtensionNotice(id: "notice-\($0)", text: "Notice \($0)") })
        XCTAssertEqual(PhoneExtensionNotices.information(in: state), ["Ready", "Widget"])
        XCTAssertEqual(PhoneExtensionNotices.notices(in: state).count, 8)
        state.notices = ["\u{001B}[32mReady\u{001B}[0m", "Widget", rawNotices[0]]
        state.extensionDisplay?.notices = [ExtensionNotice(id: "notice", text: "Notice 0")]
        XCTAssertEqual(PhoneExtensionNotices.information(in: state), ["Ready", "Widget"])
    }

    func testNoticeSummaryCountsSeverityWithoutIncludingDiagnosticText() {
        let notices = [ExtensionNotice(id: "i", text: "Private information"),
                       ExtensionNotice(id: "w", text: String(repeating: "Long warning\n", count: 100), severity: .warning),
                       ExtensionNotice(id: "e", text: "Private error", severity: .error)]
        XCTAssertEqual(PhoneExtensionNotices.summary(for: notices), "1 error · 1 warning")
        XCTAssertEqual(PhoneExtensionNotices.summary(for: notices + notices), "2 errors · 2 warnings")
        XCTAssertEqual(PhoneExtensionNotices.summary(for: [notices[1]]), "1 warning")
        XCTAssertEqual(PhoneExtensionNotices.summary(for: [notices[0]]), "Extension information")
        XCTAssertEqual(PhoneExtensionNotices.summary(for: []), "Extension information")
    }

    func testTypedNoticesKeepSeverityAndLegacyFallbackDoesNotDuplicate() {
        var state = HostSnapshot(host: UUID(), epoch: UUID())
        state.notices = ["Information", "Warning", "Error"]
        XCTAssertEqual(PhoneExtensionNotices.notices(in: state).map(\.text), state.notices)
        let typed = [ExtensionNotice(id: "i", text: "Information"), ExtensionNotice(id: "w", text: "Warning", severity: .warning), ExtensionNotice(id: "e", text: "Error", severity: .error)]
        state.extensionDisplay = ExtensionDisplayState(notices: typed)
        XCTAssertEqual(PhoneExtensionNotices.notices(in: state), typed)
        XCTAssertTrue(PhoneExtensionNotices.information(in: state).isEmpty)
        state.extensionDisplay = ExtensionDisplayState()
        XCTAssertTrue(PhoneExtensionNotices.notices(in: state).isEmpty, "Do not show stale flattened notices when typed state is present")
    }
}
