import XCTest

@MainActor
final class CompactionInterfaceTests: XCTestCase {
    private var application: XCUIApplication?

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let snapshot = XCTAttachment(string: app.debugDescription)
        snapshot.name = name + "-hierarchy"; snapshot.lifetime = .keepAlways; add(snapshot)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication, control: Bool = true) {
        for _ in 0..<16 {
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max() ?? 0
            let footer = app.buttons["compaction-review"]
            let reviewing = element.exists && element.identifier == "compaction-review"
            let bottom = footer.exists && footer.isHittable && !reviewing ? footer.frame.minY - 4 : app.frame.maxY - 4
            if element.exists, element.isHittable, element.frame.minY >= top,
               element.frame.maxY <= bottom, app.frame.contains(element.frame) {
                if control {
                    XCTAssertGreaterThanOrEqual(element.frame.width, 44)
                    XCTAssertGreaterThanOrEqual(element.frame.height, 44)
                }
                return
            }
            let down = element.exists && element.frame.minY < top
            let middle = (top + bottom) / 2
            let delta = min(120, (bottom - top) / 3)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 15, dy: middle + (down ? -delta / 2 : delta / 2)))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 15, dy: middle + (down ? delta / 2 : -delta / 2)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        capture(app, "compaction-unreachable-control")
        XCTFail("Control is not fully reachable: " + element.label)
    }

    func testCompactionRequiresConsentAndSendsReviewedCustomInstructions() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); application = app
        addTeardownBlock { @MainActor [weak self] () async throws in
            guard let self, let application = self.application else { return }
            self.capture(application, (self.testRun?.failureCount ?? 0) > 0 ? "compaction-failure" : "compaction-final")
        }
        app.launchArguments = ["idle"]
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        app.buttons["More"].tap(); app.buttons["Session controls"].tap()
        let compact = app.buttons["Compact context"]
        reveal(compact, app: app); compact.tap()
        XCTAssertTrue(app.navigationBars["Compact context"].waitForExistence(timeout: 5))
        let instructions = app.textViews["compaction-instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        reveal(instructions, app: app)
        instructions.tap(); instructions.typeText("Focus on Swift changes.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let done = app.buttons["Done editing"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(done.frame.height, 44)
        XCTAssertLessThanOrEqual(instructions.frame.maxY, done.frame.minY)
        XCTAssertGreaterThanOrEqual(instructions.frame.minY, app.navigationBars["Compact context"].frame.maxY)
        capture(app, "compact-large-text-keyboard")
        done.tap()
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed)
        let review = app.buttons["compaction-review"]
        reveal(review, app: app)
        capture(app, "compact-large-text-review-action")
        review.tap()
        let alert = app.alerts["Compact conversation context?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture(app, "compact-large-text-consent")
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["compaction-completed"].exists)
        XCTAssertEqual(instructions.value as? String, "Focus on Swift changes.")
        reveal(review, app: app); review.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Compact"].tap()
        let completed = app.staticTexts["compaction-completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        reveal(completed, app: app, control: false)
        capture(app, "compact-reviewed-summary-instructions")
        app.navigationBars["Compact context"].buttons["Session controls"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.buttons["Extension status"].tap()
        let received = app.staticTexts["Summary instructions: Focus on Swift changes."]
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        reveal(received, app: app, control: false)
        XCTAssertFalse(app.buttons["Stop"].exists)
    }
}
