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

    func testCompactWorkingComposerKeepsTranscriptVisibleWithKeyboard() {
        let app = launch("compact-working")
        defer { app.terminate() }
        let editor = app.textFields["instruction"]
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        editor.typeText("Keep this draft")
        for _ in 0..<30 {
            if keyboard.frame.minY < app.frame.maxY - 200 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "compact-working-keyboard"
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertLessThan(keyboard.frame.minY, app.frame.maxY - 200)
        let transcript = app.scrollViews["phone-conversation-transcript"]
        let send = app.buttons["Send"]
        let stop = app.buttons["Stop"]
        let delivery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send as")).firstMatch
        XCTAssertTrue(transcript.exists)
        // Keyboard accessibility bounds can exclude the prediction row above the keys.
        XCTAssertLessThanOrEqual(keyboard.frame.minY - send.frame.minY, 112)
        let top = app.navigationBars.firstMatch.frame.maxY
        let space = keyboard.frame.minY - top
        let visibleTranscript = transcript.frame.intersection(CGRect(x: 0, y: top, width: app.frame.width, height: space))
        XCTAssertGreaterThanOrEqual(visibleTranscript.height, 200)
        XCTAssertGreaterThanOrEqual(visibleTranscript.height, space * 0.6)
        for button in [send, stop, delivery, app.buttons["Attach"]] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        XCTAssertLessThanOrEqual(send.frame.height, 48)
        XCTAssertLessThan(abs(delivery.frame.midY - send.frame.midY), 10)
        XCTAssertTrue(app.buttons["extension-notice-summary"].isHittable)
        XCTAssertTrue(app.staticTexts["Fixture session"].exists)
        XCTAssertTrue(app.staticTexts["Working"].exists)
        delivery.tap()
        app.buttons["Follow-up"].tap()
        XCTAssertTrue(delivery.label.contains("Follow-up"))
        XCTAssertEqual(editor.value as? String, "Keep this draft")
    }

    func testToolArgumentsAndOutputStartCollapsedAndCanCollapseAgain() {
        let app = launch("tool-details")
        defer { app.terminate() }
        let tools = app.buttons.matching(NSPredicate(format: "label == %@", "bash"))
        let call = tools.element(boundBy: 0)
        let arguments = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "phone-tool-arguments-")).firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertTrue(call.label.contains("bash"))
        XCTAssertGreaterThanOrEqual(call.frame.height, 44)
        XCTAssertLessThanOrEqual(call.frame.height, 60)
        XCTAssertTrue(app.staticTexts["Before the tool call."].isHittable)
        XCTAssertTrue(app.staticTexts["After the tool call."].isHittable)
        XCTAssertTrue(app.staticTexts["read {\"path\":\"ordinary prose\"}"].isHittable)
        XCTAssertFalse(arguments.exists)
        let output = app.staticTexts["bash\nFixture tool output."]
        XCTAssertFalse(output.exists)
        call.tap()
        XCTAssertTrue(arguments.waitForExistence(timeout: 5))
        XCTAssertTrue(arguments.label.contains("echo fixture;"))
        app.scrollViews.firstMatch.swipeDown()
        call.tap()
        XCTAssertTrue(arguments.waitForNonExistence(timeout: 5))
        let result = tools.element(boundBy: 1)
        result.tap()
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(output.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send"].isHittable)
    }

    func testLargeEditArgumentsDoNotReplaceVisibleAssistantText() {
        let app = launch("tool-edit")
        defer { app.terminate() }
        let call = app.buttons["edit"]
        let arguments = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "phone-tool-arguments-")).firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(call.frame.height, 60)
        XCTAssertFalse(arguments.exists)
        XCTAssertTrue(app.staticTexts["I will update the Spaces list."].isHittable)
        XCTAssertTrue(app.staticTexts["The explanation stays visible."].isHittable)
        XCTAssertTrue(app.buttons["Stop"].isHittable)
        call.tap()
        XCTAssertTrue(arguments.waitForExistence(timeout: 5))
        XCTAssertTrue(arguments.label.contains("struct SpaceListView"))
        XCTAssertTrue(arguments.label.contains("newText"))
        app.scrollViews.firstMatch.swipeDown()
        call.tap()
        XCTAssertTrue(arguments.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The explanation stays visible."].isHittable)
    }

    func testToolFailureStaysVisibleWithOutputCollapsed() {
        let app = launch("tool-details-error")
        defer { app.terminate() }
        let error = app.staticTexts["Tool error: bash\nFixture tool output."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.staticTexts["bash\nFixture tool output."].exists)
        XCTAssertTrue(app.buttons["Send"].isHittable)
    }

    func testWarningAndErrorUseCompactSummaryWithCompleteDetails() {
        let app = launch("extension-notices")
        defer { app.terminate() }
        let warning = app.descendants(matching: .any)["extension-notice-warning"]
        let error = app.descendants(matching: .any)["extension-notice-error"]
        let summary = app.buttons["extension-notice-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "1 error · 1 warning")
        XCTAssertGreaterThanOrEqual(summary.frame.height, 44)
        XCTAssertLessThanOrEqual(summary.frame.height, 60)
        XCTAssertFalse(warning.exists)
        XCTAssertFalse(error.exists)
        XCTAssertFalse(app.descendants(matching: .any)["extension-notice-info"].exists)
        summary.tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertEqual(warning.label, "Warning: Fixture warning")
        XCTAssertTrue(warning.isHittable)
        XCTAssertEqual(error.label, "Error: Fixture error")
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.staticTexts["Fixture warning"].exists, "Do not duplicate flattened legacy notices")
        let info = app.descendants(matching: .any)["extension-notice-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        XCTAssertEqual(info.label, "Information: Fixture information")
        app.buttons["Close"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertFalse(warning.exists)
        XCTAssertTrue(app.buttons["Send"].isHittable)
    }

    func testLongWarningDoesNotReduceTranscriptWithKeyboardOpen() {
        let app = launch("extension-notices-long")
        defer { app.terminate() }
        let summary = app.buttons["extension-notice-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        app.textFields["instruction"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.isHittable)
        XCTAssertLessThanOrEqual(summary.frame.height, 60)
        XCTAssertTrue(app.buttons["Send"].isHittable)
        XCTAssertTrue(app.staticTexts["Pi"].firstMatch.isHittable, "The transcript must remain visible above the summary")
        summary.tap()
        let warning = app.descendants(matching: .any)["extension-notice-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.label.hasPrefix("Warning: MCP servers need attention:"))
        XCTAssertTrue(warning.label.hasSuffix("Run /mcp to fix."))
        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.buttons["Close"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(summary.frame.height, 60)
    }

    func testRecoveryInstructionStaysVisibleOutsideDetails() {
        let app = launch("extension-notices-recovery")
        defer { app.terminate() }
        let recovery = app.descendants(matching: .any)["extension-notice-recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        XCTAssertEqual(recovery.label, "Warning: Use Stop, then reopen the saved session.")
        XCTAssertTrue(recovery.isHittable)
        XCTAssertEqual(app.buttons["extension-notice-summary"].label, "1 error · 1 warning")
    }

    func testStatusWidgetsAndRecoveryStayInDetailsWithoutTypedNotices() {
        let app = launch("extension-notices-empty")
        defer { app.terminate() }
        let disclosure = app.buttons["extension-notice-summary"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Fixture status"].exists)
        XCTAssertFalse(app.staticTexts["Fixture above widget"].exists)
        XCTAssertFalse(app.staticTexts["Fixture below widget"].exists)
        XCTAssertFalse(app.staticTexts["Fixture recovery diagnostic"].exists)
        XCTAssertEqual(disclosure.label, "Extension information")
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
