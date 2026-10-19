import XCTest

@MainActor
final class DirectoryPathInterfaceTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func enter(_ path: String, app: XCUIApplication) {
        let field = app.textFields["mac-folder-path"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isEnabled)
        field.tap()
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        field.typeText(path)
        XCTAssertEqual(field.value as? String, path)
        XCTAssertFalse(app.buttons["Start Pi Here"].isEnabled,
                       "Edited text must not select the previously validated folder")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let go = app.buttons["mac-folder-go"]
        XCTAssertTrue(go.isEnabled)
        XCTAssertTrue(go.isHittable)
        XCTAssertGreaterThanOrEqual(go.frame.width, 44)
        XCTAssertGreaterThanOrEqual(go.frame.height, 44)
        XCTAssertTrue(app.frame.contains(go.frame))
        XCTAssertLessThanOrEqual(go.frame.maxY, keyboard.frame.minY + 1)
        capture(app, "phone-path-keyboard")
        go.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    }

    private func openPicker(_ app: XCUIApplication) {
        app.buttons["Spaces"].tap()
        XCTAssertTrue(app.navigationBars["Spaces"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["New fixture session"].exists)
        app.buttons["New session"].tap()
        XCTAssertTrue(app.buttons["project"].waitForExistence(timeout: 5))
    }

    func testTypedPathNavigationInvalidPathRecoveryAndExplicitStart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["idle"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Spaces"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.frame.width, 402)
        XCTAssertEqual(app.frame.height, 874)
        openPicker(app)

        let path = "/Users/fixture/project/nested"
        let start = app.buttons["Start Pi Here"]
        enter("~/project/nested", app: app)
        XCTAssertTrue(app.staticTexts[path].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This folder is empty."].exists)
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(app.navigationBars["Choose a Mac folder"].exists)
        capture(app, "phone-typed-path-opened-not-started")

        // Closing after Go must leave the original session and catalog unchanged.
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Spaces"].waitForExistence(timeout: 5))
        openPicker(app)
        enter("~/project/nested", app: app)
        XCTAssertTrue(app.staticTexts[path].waitForExistence(timeout: 5))

        enter("/Users/fixture/missing", app: app)
        let error = app.staticTexts["This folder or file changed, moved, or became unavailable. Browse again."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[path].exists)
        XCTAssertFalse(app.buttons["Parent folder"].exists)
        XCTAssertFalse(app.staticTexts["This folder is empty."].exists)
        XCTAssertFalse(start.isEnabled, "An invalid path must not leave the old folder selectable")
        XCTAssertEqual(app.textFields["mac-folder-path"].value as? String, "/Users/fixture/missing")
        capture(app, "phone-invalid-path-no-old-selection")

        enter(path, app: app)
        XCTAssertTrue(app.staticTexts[path].waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.isHittable)
        XCTAssertGreaterThanOrEqual(start.frame.width, 44)
        XCTAssertGreaterThanOrEqual(start.frame.height, 44)
        XCTAssertTrue(app.frame.contains(start.frame))
        XCTAssertTrue(app.navigationBars["Choose a Mac folder"].exists)
        capture(app, "phone-corrected-path-before-explicit-start")
        start.tap()
        XCTAssertTrue(app.navigationBars["Choose a Mac folder"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["nested"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        app.buttons["Session controls"].tap()
        XCTAssertTrue(app.staticTexts[path].waitForExistence(timeout: 5))
        capture(app, "phone-explicit-start-canonical-directory")
        app.buttons["Close"].tap()
        app.buttons["Spaces"].tap()
        XCTAssertFalse(app.collectionViews.staticTexts["New fixture session"].exists)
        app.buttons["space-/Users/fixture/project/nested"].tap()
        XCTAssertTrue(app.staticTexts["New fixture session"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.collectionViews.staticTexts.matching(identifier: "New fixture session").count, 1)
        XCTAssertFalse(app.collectionViews.staticTexts["Fixture session"].exists)
        app.navigationBars["Sessions"].buttons["Spaces"].tap()
        app.buttons["space-/Users/fixture/project"].tap()
        XCTAssertTrue(app.staticTexts["Fixture session"].waitForExistence(timeout: 5))
        capture(app, "phone-explicit-start-session-catalog")
    }
}
