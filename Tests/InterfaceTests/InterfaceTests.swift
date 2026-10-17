import XCTest

@MainActor
final class InterfaceTests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        return app
    }
    private func instruction(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "instruction").firstMatch
    }
    private func reachable(_ element: XCUIElement, app: XCUIApplication, keyboard: Bool = false) {
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable, element.label)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44)
        XCTAssertTrue(app.frame.contains(element.frame), element.label)
        if keyboard { XCTAssertLessThanOrEqual(element.frame.maxY, app.keyboards.firstMatch.frame.minY + 1) }
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<32 {
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max() ?? 0
            var down = towardTop
            if element.exists, element.isHittable {
                if element.frame.midY > top + 25, element.frame.midY < app.frame.maxY - 60 { return }
                down = element.frame.midY <= top + 25
            }
            // Drag the leading gutter so menu pickers do not consume the gesture.
            // Short drags avoid skipping a row behind the navigation bar.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: down ? 0.5 : 0.72))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: down ? 0.72 : 0.5)))
        }
        XCTFail("Control did not become fully reachable: " + element.label)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func audit(_ app: XCUIApplication) throws {
        // Contrast uses resolved-color tests and capture review. Whole-screen pixel audits
        // misclassify clipped SwiftUI scroll content. Layout is checked with real keyboard frames.
        let requested: XCUIAccessibilityAuditType = [.hitRegion, .sufficientElementDescription]
        try app.performAccessibilityAudit(for: requested) { issue in
            guard !requested.contains(issue.auditType) else { return false }
            let detail = XCTAttachment(string: "The framework returned an unrequested audit type: \(issue.auditType.rawValue). " + issue.detailedDescription)
            detail.name = "Unrequested accessibility audit"; detail.lifetime = .keepAlways; self.add(detail)
            return true
        }
    }
    private func controls(_ app: XCUIApplication) {
        app.buttons["More"].tap()
        app.buttons["Session controls"].tap()
        XCTAssertTrue(app.navigationBars["Session controls"].waitForExistence(timeout: 5))
    }

    private func openImportReview(_ app: XCUIApplication) {
        app.buttons["Sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        app.buttons["Import JSONL session"].tap()
        XCTAssertTrue(app.navigationBars["Import session"].waitForExistence(timeout: 5))
        let choose = app.buttons["Choose session file"]
        reveal(choose, app: app); choose.tap()
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 5)); local.tap()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "PiRemoteInterfaceFixture")).firstMatch
        revealPickerItem(folder, app: app); folder.tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Import fixture")).firstMatch
        revealPickerItem(file, app: app); file.tap()
    }
    private func revealPickerItem(_ item: XCUIElement, app: XCUIApplication) {
        let files = app.collectionViews["File View"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        if files.value as? String != "List Mode" {
            let more = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
            capture(app, "Import picker view options")
            let list = app.buttons["List"]
            XCTAssertTrue(list.waitForExistence(timeout: 5)); list.tap()
        }
        for _ in 0..<20 {
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max() ?? 0
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            if item.exists, item.isHittable, item.frame.minY >= top, item.frame.maxY <= bottom {
                XCTAssertGreaterThanOrEqual(item.frame.width, 44)
                XCTAssertGreaterThanOrEqual(item.frame.height, 44)
                return
            }
            let down = item.exists && item.frame.minY < top
            let middle = (top + bottom) / 2
            let delta = min(160, (bottom - top) / 2)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 8, dy: middle + (down ? -delta / 2 : delta / 2)))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 8, dy: middle + (down ? delta / 2 : -delta / 2)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        capture(app, "Import picker unreachable item")
        let snapshot = XCTAttachment(string: app.debugDescription)
        snapshot.name = "Import picker hierarchy"; snapshot.lifetime = .keepAlways; add(snapshot)
        XCTFail("File picker item is not fully reachable: " + item.label)
    }
    private func chooseImportFolder(_ app: XCUIApplication) {
        let choose = app.buttons["Choose import folder"]
        reveal(choose, app: app, towardTop: true); choose.tap()
        XCTAssertTrue(app.navigationBars["Choose a Mac folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["project"].waitForExistence(timeout: 5)); app.buttons["project"].tap()
        XCTAssertTrue(app.buttons["nested"].waitForExistence(timeout: 5)); app.buttons["nested"].tap()
        let use = app.buttons["Use this folder"]
        XCTAssertTrue(use.waitForExistence(timeout: 5)); use.tap()
        XCTAssertTrue(app.navigationBars["Import session"].waitForExistence(timeout: 5))
    }

    func testCoreModelAndThinkingCyclingRefreshTheControls() throws {
        let app = launch(["idle"])
        controls(app)
        let modelCycle = app.buttons["Cycle model"]
        reveal(modelCycle, app: app); reachable(modelCycle, app: app); modelCycle.tap()
        let model = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Model,")).firstMatch
        reveal(model, app: app, towardTop: true)
        XCTAssertTrue(model.label.contains("Fixture Two"))
        let thinkingCycle = app.buttons["Cycle thinking level"]
        reveal(thinkingCycle, app: app); reachable(thinkingCycle, app: app); thinkingCycle.tap()
        let thinking = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Thinking level,")).firstMatch
        reveal(thinking, app: app, towardTop: true)
        XCTAssertTrue(thinking.label.contains("high"))
        capture(app, "compact-core-cycling")
    }

    func testRetrySettingsDistinguishAcknowledgementFromReadBack() throws {
        let app = launch(["idle"])
        controls(app)
        let retry = app.buttons["Automatic retry controls"]
        reveal(retry, app: app); retry.tap()
        let disable = app.buttons["Disable automatic retry"]
        reveal(disable, app: app); disable.tap()
        XCTAssertTrue(app.alerts["Update Pi settings on the Mac?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        let acknowledgment = app.staticTexts["retry-acknowledgment"]
        reveal(acknowledgment, app: app, towardTop: true)
        XCTAssertTrue(acknowledgment.label.contains("No retry setting request"))
        reveal(disable, app: app); disable.tap(); app.alerts.buttons["Apply"].tap()
        reveal(acknowledgment, app: app, towardTop: true)
        XCTAssertEqual(acknowledgment.label, "Last acknowledged request: disabled")
        let refresh = app.buttons["Refresh settings"]
        reveal(refresh, app: app); reachable(refresh, app: app); refresh.tap()
        reveal(acknowledgment, app: app, towardTop: true)
        XCTAssertEqual(acknowledgment.label, "Last acknowledged request: disabled")
        capture(app, "compact-retry-acknowledgment")
    }

    func testRetryWaitCanBeCancelledWithoutOpeningIdleOnlySettings() throws {
        let app = launch(["retrying"])
        controls(app)
        let cancel = app.buttons["Cancel retry wait"]
        reveal(cancel, app: app); reachable(cancel, app: app); cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
    }

    func testReleaseNotesPageNavigationAndReload() throws {
        let app = launch(["idle"])
        controls(app)
        let notes = app.buttons["Pi changelog"]
        reveal(notes, app: app); notes.tap()
        XCTAssertTrue(app.navigationBars["Pi changelog"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pi 1.3.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["# Release fixture\nNative page one 🦉"].exists)
        XCTAssertFalse(app.buttons["Previous"].isEnabled)
        reachable(app.buttons["Next"], app: app); app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Native page two — final notes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Next"].isEnabled)
        app.buttons["Previous"].tap()
        XCTAssertTrue(app.staticTexts["# Release fixture\nNative page one 🦉"].waitForExistence(timeout: 5))
        app.buttons["Next"].tap(); app.buttons["Reload"].tap()
        XCTAssertTrue(app.staticTexts["# Release fixture\nNative page one 🦉"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Previous"].isEnabled)
        capture(app, "compact-native-release-notes")
    }

    func testLightConversationWithKeyboardStopAndRetainedDraft() throws {
        let app = launch(["working"])
        try audit(app)
        let tool = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Read file")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5) && tool.isHittable)
        let input = instruction(app)
        XCTAssertEqual(input.label, "Prompt")
        let delivery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send as")).firstMatch
        XCTAssertTrue(delivery.waitForExistence(timeout: 5))
        XCTAssertTrue(delivery.label.contains("Steering"))
        delivery.tap()
        XCTAssertTrue(app.buttons["Follow-up"].waitForExistence(timeout: 5))
        app.buttons["Follow-up"].tap()
        XCTAssertTrue(delivery.label.contains("Follow-up"))
        input.tap(); input.typeText("Keyboard fixture")
        XCTAssertTrue((instruction(app).value as? String)?.contains("Keyboard fixture") == true)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reachable(app.buttons["Stop"], app: app, keyboard: true)
        reachable(app.buttons["Send"], app: app, keyboard: true)
        XCTAssertTrue(tool.isHittable, "Opening the keyboard must keep the latest output in view")
        capture(app, "compact-light-working-keyboard")
        app.buttons["Send"].tap()
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 5))
        instruction(app).tap(); instruction(app).typeText("Retained fixture draft")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(instruction(app).waitForExistence(timeout: 5))
        XCTAssertTrue((instruction(app).value as? String)?.contains("Retained fixture draft") == true)
    }

    func testBoundedTranscriptWithOneHundredMessagesRemainsUsable() throws {
        let app = launch(["large"])
        let last = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Bounded transcript complete")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5) && last.isHittable)
        reachable(app.buttons["Send"], app: app)
        last.tap()
        capture(app, "compact-bounded-transcript")
        controls(app)
        XCTAssertTrue(app.buttons["Close"].isHittable)
    }

    func testReadingPositionSurvivesNewOutputAndLatestReturnsToTheBottom() throws {
        let app = launch(["streaming"])
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown()
        let first = app.staticTexts["Review the fixture change."]
        XCTAssertTrue(first.waitForExistence(timeout: 5) && first.isHittable)
        let position = first.frame.minY
        let output = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming fixture output"))
        let count = output.count
        let more = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", count), object: output)
        XCTAssertEqual(XCTWaiter.wait(for: [more], timeout: 8), .completed)
        XCTAssertEqual(first.frame.minY, position, accuracy: 2)
        reachable(app.buttons["Latest"], app: app)
        capture(app, "compact-reading-position")
        app.buttons["Latest"].tap()
        let tool = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Read file")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5) && tool.isHittable)
    }

    func testLastResponseCopyAndIdleSessionCloseUseExplicitActions() throws {
        let app = launch(["idle"])
        controls(app)
        let copyLink = app.buttons["Copy last assistant message"]
        for _ in 0..<8 where !copyLink.isHittable { app.swipeUp() }
        XCTAssertTrue(copyLink.isHittable); copyLink.tap()
        XCTAssertTrue(app.navigationBars["Last assistant message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Native copy fixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Copied to this device"].exists)
        let copy = app.buttons["Copy text"]
        reachable(copy, app: app); copy.tap()
        XCTAssertTrue(app.staticTexts["Copied to this device"].waitForExistence(timeout: 5))
        capture(app, "compact-last-response-copy")
        reachable(app.buttons["Done"], app: app); app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Session controls"].waitForExistence(timeout: 5))
        let close = app.buttons["Close Pi session"].firstMatch
        reveal(close, app: app)
        XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertTrue(app.staticTexts["Close this Pi session?"].waitForExistence(timeout: 5))
        let confirm = try XCTUnwrap(app.buttons.matching(identifier: "Close Pi session").allElementsBoundByIndex.first { $0.isHittable })
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture session")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.buttons["Stop"].exists)
    }

    func testSessionExportRequiresConsentSupportsCancelDiscardAndSave() throws {
        let app = launch(["idle"])
        controls(app)
        let link = app.buttons["Review and export session"]
        reveal(link, app: app)
        XCTAssertTrue(link.isHittable); link.tap()
        XCTAssertTrue(app.navigationBars["Export session"].waitForExistence(timeout: 5))
        let prepare = app.buttons["Prepare HTML export"]
        reveal(prepare, app: app)
        XCTAssertFalse(prepare.isEnabled)
        let consent = app.switches["export-consent"]
        reveal(consent.switches.firstMatch, app: app, towardTop: true)
        consent.switches.firstMatch.tap()
        XCTAssertEqual(consent.value as? String, "1")
        reveal(prepare, app: app)
        XCTAssertTrue(prepare.isEnabled); prepare.tap()
        let save = app.buttons["Save HTML file"]
        reveal(save, app: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["export-saved"].exists)
        save.tap()
        XCTAssertTrue(app.textFields["DOCPicker.filenameTextField"].waitForExistence(timeout: 5))
        // The system picker exposes a misplaced Cancel proxy on this SDK.
        // Dismiss its sheet with the standard downward gesture instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.065))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.textFields["DOCPicker.filenameTextField"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["export-saved"].exists)
        let discard = app.buttons["Discard export"]
        reveal(discard, app: app)
        reachable(discard, app: app); discard.tap()
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertFalse(prepare.isEnabled)
        XCTAssertFalse(save.exists)
        reveal(consent.switches.firstMatch, app: app, towardTop: true)
        consent.switches.firstMatch.tap()
        XCTAssertEqual(consent.value as? String, "1")
        reveal(prepare, app: app)
        prepare.tap()
        reveal(save, app: app)
        save.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 5))
        filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (filename.value as? String ?? "").count))
        filename.typeText("pi-export-" + UUID().uuidString)
        app.buttons["Save"].tap()
        let saved = app.staticTexts["export-saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertFalse(save.exists)
    }

    func testSystemSharingRequiresConsentAndCancelKeepsTheExport() throws {
        verifySystemSharing(jsonl: false)
    }

    func testJSONLSystemSharingPreservesTheFilenameAndResetsConsent() throws {
        verifySystemSharing(jsonl: true)
    }

    private func verifySystemSharing(jsonl: Bool) {
        let app = launch(["idle"])
        controls(app)
        let link = app.buttons["Review and export session"]
        reveal(link, app: app); link.tap()
        if jsonl {
            let format = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Export format")).firstMatch
            XCTAssertTrue(format.waitForExistence(timeout: 5)); format.tap()
            app.buttons["JSONL (.jsonl)"].tap()
        }
        let consent = app.switches["export-consent"]
        reveal(consent.switches.firstMatch, app: app); consent.switches.firstMatch.tap()
        let prepare = app.buttons[jsonl ? "Prepare JSONL export" : "Prepare HTML export"]
        reveal(prepare, app: app); prepare.tap()
        let review = app.buttons["Review sharing options"]
        reveal(review, app: app); review.tap()
        XCTAssertTrue(app.navigationBars["Share export"].waitForExistence(timeout: 5))
        let service = app.buttons["share-service"]
        reveal(service, app: app)
        XCTAssertFalse(service.isEnabled)
        let sharing = app.switches["share-consent"].switches.firstMatch
        reveal(sharing, app: app, towardTop: true); sharing.tap()
        reveal(service, app: app); reachable(service, app: app); service.tap()
        let activity = app.otherElements["ActivityListView"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars[jsonl ? "pi-session.jsonl" : "pi-session.html"].exists)
        capture(app, jsonl ? "compact-jsonl-system-share-picker" : "compact-system-share-picker")
        app.otherElements["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(activity.waitForNonExistence(timeout: 5))
        XCTAssertTrue(service.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["export-saved"].exists)
        app.navigationBars["Share export"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Export session"].waitForExistence(timeout: 5))
        reveal(review, app: app, towardTop: true); review.tap()
        reveal(service, app: app)
        XCTAssertFalse(service.isEnabled, "Leaving the sharing review must reset consent.")
        capture(app, jsonl ? "compact-jsonl-system-share-consent" : "compact-system-share-consent")
        if jsonl {
            reveal(sharing, app: app, towardTop: true); sharing.tap()
            reveal(service, app: app); service.tap()
            let localFiles = app.cells["Save to Files"]
            XCTAssertTrue(localFiles.waitForExistence(timeout: 10)); localFiles.tap()
            let filename = app.textFields["DOCPicker.filenameTextField"]
            XCTAssertTrue(filename.waitForExistence(timeout: 5)); filename.tap()
            filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (filename.value as? String ?? "").count))
            filename.typeText("pi-system-share-" + UUID().uuidString)
            app.buttons["Save"].tap()
            XCTAssertTrue(filename.waitForNonExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["export-saved"].exists, "System sharing must not report the app's separate Save action as completed.")
        } else {
            reveal(sharing, app: app, towardTop: true); sharing.tap()
            reveal(service, app: app); service.tap()
            XCTAssertTrue(activity.waitForExistence(timeout: 10))
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(activity.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["Share export"].exists)
        }
    }

    func testJSONLExportSavesThroughTheNativeFilePicker() throws {
        let app = launch(["idle"])
        controls(app)
        let link = app.buttons["Review and export session"]
        reveal(link, app: app); link.tap()
        let format = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Export format")).firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 5)); format.tap()
        app.buttons["JSONL (.jsonl)"].tap()
        let consent = app.switches["export-consent"]
        reveal(consent.switches.firstMatch, app: app)
        consent.switches.firstMatch.tap()
        XCTAssertEqual(consent.value as? String, "1")
        let prepare = app.buttons["Prepare JSONL export"]
        reveal(prepare, app: app); prepare.tap()
        let save = app.buttons["Save JSONL file"]
        reveal(save, app: app); save.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 5)); filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (filename.value as? String ?? "").count))
        filename.typeText("pi-jsonl-export-" + UUID().uuidString)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["export-saved"].waitForExistence(timeout: 5))
        XCTAssertFalse(save.exists)
    }

    func testMissingImportDirectoryRequiresAnExplicitChoiceAndConfirmation() throws {
        let app = launch(["import-missing-directory"])
        openImportReview(app)
        let missing = app.staticTexts["Not recorded. Choose a Mac folder."]
        reveal(missing, app: app)
        let open = app.buttons["Import and open"]
        reveal(open, app: app); XCTAssertFalse(open.isEnabled)
        chooseImportFolder(app)
        let target = app.staticTexts["/Users/fixture/project/nested"]
        reveal(target, app: app); XCTAssertTrue(target.exists)
        let clear = app.buttons["Clear chosen directory"]
        reveal(clear, app: app); clear.tap()
        reveal(open, app: app); XCTAssertFalse(open.isEnabled)
        chooseImportFolder(app)
        reveal(open, app: app); open.tap()
        XCTAssertTrue(app.alerts["Import and open this session?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Import and open"].tap()
        XCTAssertTrue(app.staticTexts["Imported native fixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop"].exists)
        controls(app)
        reveal(app.staticTexts["/Users/fixture/project/nested"], app: app)
        XCTAssertTrue(app.staticTexts["/Users/fixture/project/nested"].exists)
    }

    func testSessionImportReviewsTheDirectoryAndRequiresConfirmation() throws {
        let app = launch(["legacy-import"])
        openImportReview(app)
        reveal(app.staticTexts["/Users/fixture/project"], app: app)
        XCTAssertTrue(app.staticTexts["/Users/fixture/project"].exists)
        let migration = app.staticTexts["Pi migrates the managed copy to its current session format. The source file remains unchanged."]
        reveal(migration, app: app); XCTAssertTrue(migration.exists)
        let open = app.buttons["Import and open"]
        reveal(open, app: app); open.tap()
        XCTAssertTrue(app.alerts["Import and open this session?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Import session"].exists)
        open.tap()
        app.alerts.buttons["Import and open"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertTrue(app.staticTexts["Imported native fixture"].exists)
    }

    func testRuntimeSettingsRequireConfirmationAndRefreshTheAppliedValue() throws {
        let app = launch(["idle"])
        controls(app)
        let runtime = app.buttons["Pi runtime settings"]
        for _ in 0..<8 where !runtime.isHittable { app.swipeUp() }
        XCTAssertTrue(runtime.isHittable); runtime.tap()
        XCTAssertTrue(app.navigationBars["Pi runtime settings"].waitForExistence(timeout: 5))
        let steering = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Steering mode")).firstMatch
        XCTAssertTrue(steering.waitForExistence(timeout: 5)); steering.tap()
        app.buttons["All queued messages"].tap()
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(steering.label.contains("One at a time"))
        steering.tap(); app.buttons["All queued messages"].tap()
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 5)); app.buttons["Apply"].tap()
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "All queued messages"), object: steering)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 5), .completed)
        let compaction = app.switches["Automatic compaction"]
        reveal(compaction.switches.firstMatch, app: app)
        XCTAssertEqual(compaction.value as? String, "1")
        compaction.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5)); app.buttons["Cancel"].tap()
        XCTAssertEqual(compaction.value as? String, "1")
        compaction.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 5)); app.buttons["Apply"].tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: compaction)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        capture(app, "compact-confirmed-runtime-settings")
    }

    func testMacFileAttachmentAppendsToTheDraftWithoutSending() throws {
        let app = launch(["idle"])
        instruction(app).tap(); instruction(app).typeText("Keep this draft")
        app.buttons["More"].tap(); app.buttons["Mac files"].tap()
        XCTAssertTrue(app.buttons["project"].waitForExistence(timeout: 5))
        app.buttons["project"].tap()
        XCTAssertTrue(app.buttons["fixture.swift"].waitForExistence(timeout: 5))
        app.buttons["fixture.swift"].tap()
        XCTAssertTrue(app.navigationBars["fixture.swift"].waitForExistence(timeout: 5))
        let attach = app.buttons["Attach text"]
        reachable(attach, app: app, keyboard: app.keyboards.firstMatch.exists)
        reachable(app.buttons["Done"], app: app, keyboard: app.keyboards.firstMatch.exists)
        capture(app, "compact-mac-text-attachment")
        attach.tap()
        XCTAssertTrue(instruction(app).waitForExistence(timeout: 5))
        let draft = instruction(app).value as? String ?? ""
        XCTAssertTrue(draft.hasPrefix("Keep this draft\n\nFile: fixture.swift"))
        XCTAssertTrue(draft.contains("let attached = 42"))
        XCTAssertFalse(app.buttons["Stop"].exists, "Attaching text must not start a run")
    }

    func testImageOutputOpensNativePreviewAndFullResolution() throws {
        let app = launch(["images"])
        let viewImage = app.buttons["View image 1"]
        for _ in 0..<6 where !viewImage.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(viewImage.isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Image 2:")).firstMatch.exists)
        viewImage.tap()
        XCTAssertTrue(app.navigationBars["Image output"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["32 × 32 pixels"].waitForExistence(timeout: 5))
        let image = app.images["Pi image output"]
        XCTAssertTrue(image.isHittable)
        let full = app.switches["Full resolution"]
        XCTAssertTrue(full.isHittable)
        XCTAssertEqual(full.value as? String, "0")
        // SwiftUI exposes the label and switch as one accessibility element.
        // Activate the visible switch, not the noninteractive label center.
        full.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: full)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["32 × 32 pixels"].waitForExistence(timeout: 5))
        XCTAssertTrue(image.isHittable)
        capture(app, "compact-native-output-image")
        reachable(app.buttons["Done"], app: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(viewImage.waitForExistence(timeout: 5))
        viewImage.tap()
        XCTAssertTrue(app.navigationBars["Image output"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(viewImage.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Image output"].exists, "Background protection must remove image output sheets")
    }

    func testSessionUsageIsReadableAndRefreshable() throws {
        let app = launch(["idle"])
        controls(app)
        let usage = app.buttons["Session tokens and cost"]
        for _ in 0..<6 where !usage.isHittable { app.swipeUp() }
        XCTAssertTrue(usage.isHittable)
        usage.tap()
        XCTAssertTrue(app.navigationBars["Session usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Session totals"].waitForExistence(timeout: 5))
        capture(app, "compact-session-usage")
        let refresh = app.buttons["Refresh usage"]
        for _ in 0..<10 where !refresh.isHittable { app.swipeUp() }
        reachable(refresh, app: app)
        refresh.tap()
        XCTAssertTrue(app.staticTexts["Estimated tokens"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Used"].isHittable)
        try audit(app)
        capture(app, "compact-session-usage-context")
    }

    func testDarkErrorsAndSessionControlsRemainReadable() throws {
        let app = launch(["dark", "error"])
        let failure = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Permission denied for the fixture file")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "Tool errors must not require expanding a result")
        try audit(app)
        capture(app, "compact-dark-error")
        app.buttons["Access denied"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Grant access on the Mac")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "compact-dark-recovery")
        app.buttons["Close"].tap()
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(app.buttons["Access denied"].waitForNonExistence(timeout: 5))
        controls(app)
        try audit(app)
        capture(app, "compact-dark-session-controls")
        app.buttons["Close"].tap()
        reachable(app.buttons["Send"], app: app)
    }

    func testDisconnectedRecoveryAndSavedConnectionsRemainReachable() throws {
        let app = launch(["disconnected"])
        XCTAssertTrue(app.buttons["Unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sessions"].isEnabled)
        let reconnect = app.buttons["Reconnect"]
        for _ in 0..<6 where !reconnect.isHittable { app.scrollViews.firstMatch.swipeUp() }
        reachable(reconnect, app: app)
        reconnect.tap()
        let connections = app.buttons["Connections"]
        for _ in 0..<6 where !connections.isHittable { app.scrollViews.firstMatch.swipeUp() }
        reachable(connections, app: app)
        capture(app, "compact-disconnected")
        connections.tap()
        XCTAssertTrue(app.buttons["Fixture Mac"].waitForExistence(timeout: 5))
        try audit(app)
        capture(app, "compact-saved-connections")
        app.buttons["Close"].tap()
    }

    func testDirectorySelectionAndEditorWithKeyboard() throws {
        let app = launch([])
        instruction(app).tap(); instruction(app).typeText("Directory draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Sessions"].tap()
        app.buttons["New session"].tap()
        XCTAssertTrue(app.buttons["project"].waitForExistence(timeout: 5))
        app.buttons["project"].tap()
        XCTAssertTrue(app.buttons["nested"].waitForExistence(timeout: 5))
        app.buttons["nested"].tap()
        XCTAssertTrue(app.staticTexts["/Users/fixture/project/nested"].waitForExistence(timeout: 5))
        reachable(app.buttons["Start Pi Here"], app: app)
        try audit(app)
        capture(app, "compact-directory")
        app.buttons["Start Pi Here"].tap()
        XCTAssertTrue(app.staticTexts["nested"].waitForExistence(timeout: 5))
        controls(app)
        XCTAssertTrue(app.staticTexts["/Users/fixture/project/nested"].waitForExistence(timeout: 5))
        let command = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "/fixture-dialog")).firstMatch
        for _ in 0..<8 where !command.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(command.isHittable)
        command.tap()
        XCTAssertTrue(app.staticTexts["Fixture editor"].waitForExistence(timeout: 5))
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText(" edited")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reachable(app.buttons["Submit"], app: app, keyboard: true)
        reachable(app.buttons["Cancel"], app: app, keyboard: true)
        capture(app, "compact-editor-keyboard")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Fixture editor"].waitForNonExistence(timeout: 5))
    }
}
