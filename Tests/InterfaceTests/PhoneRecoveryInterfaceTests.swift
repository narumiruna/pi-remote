import XCTest

@MainActor
final class PhoneRecoveryInterfaceTests: XCTestCase {
    private func launch(_ phase: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [phase]
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        return app
    }

    func testOfflineDialogClosesLocallyCachedReadingWorksAndReconnectDoesNotReplay() {
        let app = launch("dialog-recovery")
        defer { app.terminate() }
        let confirm = app.buttons["extension-dialog-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["extension-dialog-error"].waitForExistence(timeout: 5))
        let reconnect = app.buttons["extension-dialog-reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertFalse(app.buttons["extension-dialog-cancel"].isEnabled)
        let close = app.buttons["extension-dialog-close"]
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reconnect"].isEnabled)
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.buttons["Stop"].isEnabled)
        XCTAssertFalse(app.buttons["Attach"].isEnabled)
        let thinking = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Thinking")).firstMatch
        XCTAssertTrue(thinking.isEnabled)
        thinking.tap()
        XCTAssertTrue(app.staticTexts["Fixture thinking"].waitForExistence(timeout: 5))
        let tool = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Read file")).firstMatch
        XCTAssertTrue(tool.isEnabled)
        tool.tap()
        XCTAssertTrue(app.staticTexts["Read file\nFixture output"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.isEnabled)
        latest.tap()
        XCTAssertTrue(tool.isHittable, "Latest must keep working while disconnected")
        app.buttons["reconnect"].tap()
        XCTAssertTrue(app.buttons["reconnect"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(confirm.exists, "Reconnect must not reopen the dismissed request")
        let pending = app.buttons["reopen-extension-dialog"]
        XCTAssertTrue(pending.exists, "Reconnect must not answer or cancel the pending request")
        pending.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertFalse(pending.exists)
    }

    func testWarningAndErrorHaveVisibleSeverityAndOnlyInformationStartsCollapsed() {
        let app = launch("extension-notices")
        defer { app.terminate() }
        let warning = app.descendants(matching: .any)["extension-notice-warning"]
        let error = app.descendants(matching: .any)["extension-notice-error"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(warning.label, "Warning: Fixture warning")
        XCTAssertTrue(warning.isHittable)
        XCTAssertEqual(error.label, "Error: Fixture error")
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["extension-notice-info"].exists)
        XCTAssertFalse(app.staticTexts["Fixture warning"].exists, "Do not duplicate flattened legacy notices")
        app.buttons["Extension information"].tap()
        let info = app.descendants(matching: .any)["extension-notice-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        XCTAssertEqual(info.label, "Information: Fixture information")
    }

    func testStatusWidgetsAndRecoveryStayCollapsedWithoutTypedNotices() {
        let app = launch("extension-notices-empty")
        defer { app.terminate() }
        let disclosure = app.buttons["Extension status and diagnostics"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture status"].exists)
        XCTAssertFalse(app.staticTexts["Fixture above widget"].exists)
        XCTAssertFalse(app.staticTexts["Fixture below widget"].exists)
        XCTAssertFalse(app.staticTexts["Fixture recovery diagnostic"].exists)
        XCTAssertFalse(app.buttons["Extension information"].exists)
        disclosure.tap()
        for text in ["Fixture status", "Fixture above widget", "Fixture below widget", "Fixture recovery diagnostic"] {
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count, 1)
        }
    }

    func testForgetNamesMacExplainsLocalDeletionAndCancelPreservesPairing() {
        let app = launch("idle")
        defer { app.terminate() }
        app.buttons["More"].tap()
        app.buttons["Connections"].tap()
        XCTAssertTrue(app.buttons["Fixture Mac"].waitForExistence(timeout: 5))
        app.buttons["Forget"].tap()
        XCTAssertTrue(app.staticTexts["Forget Fixture Mac?"].waitForExistence(timeout: 5))
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "deletes its saved credentials")).firstMatch
        XCTAssertTrue(message.exists)
        XCTAssertTrue(message.label.contains("Pair again"))
        XCTAssertTrue(message.label.contains("does not revoke"))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Fixture Mac"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        app.buttons["More"].tap()
        app.buttons["Connections"].tap()
        XCTAssertTrue(app.buttons["Fixture Mac"].waitForExistence(timeout: 5))
    }
}
