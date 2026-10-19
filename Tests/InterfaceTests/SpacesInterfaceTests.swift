import XCTest

@MainActor
final class SpacesInterfaceTests: XCTestCase {
    private func launch(_ phase: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [phase]
        app.launch()
        XCTAssertTrue(app.buttons["Spaces"].waitForExistence(timeout: 10))
        app.buttons["Spaces"].tap()
        XCTAssertTrue(app.navigationBars["Spaces"].waitForExistence(timeout: 5))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSpacesGroupDirectoriesAndBrowsingDoesNotActivateSessions() {
        let app = launch("spaces")
        defer { app.terminate() }
        let project = app.buttons["space-/Users/fixture/project"]
        let other = app.buttons["space-/Users/fixture/other/project"]
        XCTAssertEqual(app.buttons.matching(identifier: project.identifier).count, 1)
        XCTAssertTrue(project.label.contains("2 sessions"))
        XCTAssertTrue(other.label.contains("1 session"))
        XCTAssertFalse(app.collectionViews.staticTexts["Fixture session"].exists)
        XCTAssertFalse(app.buttons["New in current directory"].exists)
        capture(app, "phone-spaces-grouped-directories")

        other.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["/Users/fixture/other/project"].exists)
        XCTAssertTrue(app.collectionViews.staticTexts["Other directory session"].exists)
        XCTAssertFalse(app.collectionViews.staticTexts["Fixture session"].exists)
        XCTAssertFalse(app.buttons["New in current directory"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Fixture session"].waitForExistence(timeout: 5), "Browsing a Space must not resume its sessions")

        app.buttons["Spaces"].tap()
        project.tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Other directory session"].exists)
        XCTAssertTrue(app.staticTexts["Current session"].exists)
        XCTAssertTrue(app.buttons["New in current directory"].exists)
        let interrupted = app.buttons["session-33333333-3333-3333-3333-333333333333"]
        XCTAssertTrue(interrupted.exists)
        capture(app, "phone-space-sessions")
        interrupted.tap()
        XCTAssertTrue(app.buttons["Resume without resending any prompt"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].exists)
    }

    func testSpacesRemainBrowsableWhileWorkingButSessionActionsAreDisabled() {
        let app = launch("spaces-working")
        defer { app.terminate() }
        XCTAssertFalse(app.buttons["New session"].isEnabled)
        XCTAssertFalse(app.buttons["Import JSONL session"].isEnabled)
        app.buttons["space-/Users/fixture/project"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New session"].isEnabled)
        XCTAssertFalse(app.buttons["New in current directory"].isEnabled)
        XCTAssertFalse(app.buttons["session-33333333-3333-3333-3333-333333333333"].isEnabled)
    }

    func testEmptySpacesKeepCreationAndImportAvailable() {
        let app = launch("spaces-empty")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No spaces yet. Start a session in a Mac folder to add a space."].exists)
        XCTAssertTrue(app.buttons["New session"].isEnabled)
        XCTAssertTrue(app.buttons["Import JSONL session"].isEnabled)
        XCTAssertFalse(app.buttons["New in current directory"].exists)
        capture(app, "phone-spaces-empty")
    }

    func testSpaceCreationOpensItsDirectoryWithoutStartingPi() {
        let app = launch("spaces")
        defer { app.terminate() }
        app.buttons["space-/Users/fixture/project"].tap()
        app.buttons["New session"].tap()
        XCTAssertTrue(app.navigationBars["Choose a Mac folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["/Users/fixture/project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start Pi Here"].isEnabled)
        app.navigationBars.buttons["Sessions"].tap()
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Fixture session"].waitForExistence(timeout: 5))
        app.buttons["Spaces"].tap()
        XCTAssertTrue(app.buttons["space-/Users/fixture/project"].label.contains("2 sessions"))
    }
}
