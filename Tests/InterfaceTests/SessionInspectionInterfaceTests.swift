import XCTest

@MainActor
final class SessionInspectionInterfaceTests: XCTestCase {
    func testHistoryOpensReadOnlyTreeAndReportsUnsupportedFixtureWithoutForking() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["idle"]
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let link = app.descendants(matching: .any).matching(identifier: "session-tree-link").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertTrue(link.isHittable)
        link.tap()
        XCTAssertTrue(app.navigationBars["Session tree"].waitForExistence(timeout: 5))
        // The existing UI fixture does not implement this new RPC action. This
        // check covers native entry and explicit error recovery, not tree data.
        let error = app.descendants(matching: .any).matching(identifier: "session-tree-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Fork from this message"].exists)
        let reload = app.buttons["Reload tree"]
        for _ in 0..<8 {
            if reload.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(reload.isHittable)
        XCTAssertGreaterThanOrEqual(reload.frame.height, 44)
        reload.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Session tree explicit fixture error"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
