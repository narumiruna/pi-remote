import AppKit
import PiRemoteCore
import PiRemoteSecurity
import SwiftUI
import XCTest

private final class DesktopSessionSecrets: SecretStore, @unchecked Sendable {
    func get(_ account: String) throws -> Data? { nil }
    func put(_ data: Data, account: String) throws {}
    func remove(_ account: String) throws {}
}

@MainActor final class MacDesktopSessionActionTests: XCTestCase {
    private func fixture(_ body: (CompanionModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PiRemote.DesktopSessionActions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = CompanionModel(support: root, secrets: DesktopSessionSecrets(), defaults: defaults,
                                   debugDirectory: root.appendingPathComponent("debug"))
        do { try await body(model) }
        catch {
            await model.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.shutdown(); defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    func testClosedRowsOfferReopenWithoutChangingCoreCloseIdempotency() async throws {
        try await fixture { model in
            let saved = SessionInfo(id: UUID(), title: "Saved fixture", directory: "/tmp/desktop-actions")
            model.state.sessions = [saved]
            model.text = "Keep draft"
            XCTAssertEqual(macOpenSessionLabel(saved.id, model: model), "Open")
            XCTAssertNil(macCloseSessionDisabledReason(saved.id, model: model))
            let closed = await model.closeSession(saved.id)
            XCTAssertTrue(closed)
            let before = model.state
            XCTAssertEqual(macOpenSessionLabel(saved.id, model: model), "Reopen")
            XCTAssertNotNil(macCloseSessionDisabledReason(saved.id, model: model))
            XCTAssertNil(model.closeSessionDisabledReason(saved.id), "UI availability must not break idempotent core retries")
            let repeated = await model.closeSession(saved.id)
            XCTAssertTrue(repeated)
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(model.state.sessions, [saved])
            XCTAssertEqual(model.text, "Keep draft")
        }
    }

    func testLoadedAndMissingSessionAvailabilityKeepsExistingGuards() async throws {
        try await fixture { model in
            let active = SessionInfo(id: UUID(), title: "Active fixture", directory: "/tmp/desktop-actions")
            model.state.sessions = [active]; model.state.selected = active.id
            model.state.phase = "working"
            XCTAssertEqual(macOpenSessionLabel(active.id, model: model), "View conversation")
            XCTAssertTrue(model.closeSessionRequiresConfirmation(active.id))
            XCTAssertNil(macCloseSessionDisabledReason(active.id, model: model))
            let unconfirmed = await model.closeSession(active.id)
            XCTAssertFalse(unconfirmed)
            XCTAssertEqual(model.state.selected, active.id)
            model.state.phase = "waiting"
            XCTAssertNotNil(macCloseSessionDisabledReason(active.id, model: model))
            XCTAssertNotNil(macCloseSessionDisabledReason(UUID(), model: model))
            model.state.phase = "idle"; model.openingSession = true
            XCTAssertNotNil(macCloseSessionDisabledReason(active.id, model: model))
            model.openingSession = false
        }
    }

    func testClosedOverviewStartsCollapsedWithoutDisabledCloseRows() async throws {
        try await fixture { model in
            _ = NSApplication.shared
            let saved = SessionInfo(id: UUID(), title: "Closed fixture", directory: "/tmp/desktop-actions")
            model.state.sessions = [saved]
            let closed = await model.closeSession(saved.id)
            XCTAssertTrue(closed)
            model.destination = .overview; model.interfaceMode = .desktop
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: CompanionWindow(model: model).environment(\.accessibilityEnabled, true))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            var stack: [NSObject] = [host], seen = Set<ObjectIdentifier>()
            var foundClose = false, foundReopen = false, foundClosedGroup = false
            while let item = stack.popLast(), seen.count < 8192 {
                guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
                func value(_ key: String) -> Any? {
                    let selector = NSSelectorFromString(key)
                    return item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() : nil
                }
                if value("accessibilityIdentifier") as? String == "mac-overview-close-" + saved.id.uuidString {
                    foundClose = true
                }
                if value("accessibilityLabel") as? String == "Reopen" { foundReopen = true }
                if value("accessibilityIdentifier") as? String == "mac-overview-closed-sessions" { foundClosedGroup = true }
                stack.append(contentsOf: (item as? NSView)?.subviews ?? [])
                stack.append(contentsOf: value("accessibilityChildren") as? [NSObject] ?? [])
            }
            XCTAssertFalse(foundClose); XCTAssertFalse(foundReopen)
            XCTAssertTrue(foundClosedGroup)
            XCTAssertNil(model.state.selected)
            XCTAssertTrue(model.closedSessionIDs.contains(saved.id))
        }
    }
}
