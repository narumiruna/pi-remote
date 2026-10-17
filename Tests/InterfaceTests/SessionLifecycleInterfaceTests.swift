import XCTest

@MainActor
final class SessionLifecycleInterfaceTests: XCTestCase {
    private var application: XCUIApplication?

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let snapshot = XCTAttachment(string: app.debugDescription)
        snapshot.name = name + "-hierarchy"; snapshot.lifetime = .keepAlways; add(snapshot)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<16 {
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max() ?? 0
            let footer = app.buttons["new-session-review"]
            let reviewing = element.exists && element.identifier == "new-session-review"
            let bottom = footer.exists && footer.isHittable && !reviewing ? footer.frame.minY - 4 : app.frame.maxY - 4
            if element.exists, element.isHittable, element.frame.minY >= top,
               element.frame.maxY <= bottom, app.frame.contains(element.frame) {
                XCTAssertGreaterThanOrEqual(element.frame.width, 44)
                XCTAssertGreaterThanOrEqual(element.frame.height, 44)
                return
            }
            let down = element.exists && element.frame.minY < top
            let middle = (top + bottom) / 2
            let delta = min(120, (bottom - top) / 3)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 15, dy: middle + (down ? -delta / 2 : delta / 2)))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 15, dy: middle + (down ? delta / 2 : -delta / 2)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        capture(app, "new-session-unreachable-control")
        XCTFail("Control is not fully reachable: " + element.label)
    }

    func testSameDirectoryNewSessionRequiresConfirmationAndPreservesParentChoice() {
        continueAfterFailure = false
        let app = XCUIApplication(); application = app
        addTeardownBlock { @MainActor [weak self] () async throws in
            guard let self, let application = self.application else { return }
            self.capture(application, (self.testRun?.failureCount ?? 0) > 0 ? "new-session-failure" : "new-session-final")
        }
        app.launchArguments = ["idle"]
        app.launch()
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 10))
        app.buttons["Sessions"].tap()
        let link = app.buttons["New in current directory"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        reveal(link, app: app); link.tap()
        XCTAssertTrue(app.navigationBars["New session"].waitForExistence(timeout: 5))
        let parent = app.switches["new-session-parent"]
        reveal(parent, app: app)
        let switchControl = parent.switches.firstMatch
        XCTAssertTrue(switchControl.exists && switchControl.isHittable)
        XCTAssertTrue(parent.frame.contains(switchControl.frame))
        switchControl.tap()
        XCTAssertEqual(parent.value as? String, "1")
        let review = app.buttons["new-session-review"]
        reveal(review, app: app)
        capture(app, "new-session-large-text-parent-choice")
        review.tap()
        let alert = app.alerts["Start an empty session?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture(app, "new-session-large-text-consent")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertEqual(parent.value as? String, "1")
        XCTAssertFalse(app.staticTexts["New child fixture"].exists)
        reveal(review, app: app); review.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Start new session"].tap()
        XCTAssertTrue(app.buttons["Sessions"].waitForExistence(timeout: 5))
        app.buttons["Sessions"].tap()
        let child = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New child fixture")).firstMatch
        reveal(child, app: app)
        XCTAssertTrue(child.isHittable)
        let original = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture session")).firstMatch
        reveal(original, app: app)
        XCTAssertTrue(original.isHittable)
    }
}
