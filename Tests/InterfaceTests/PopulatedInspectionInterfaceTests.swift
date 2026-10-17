import XCTest

@MainActor
final class PopulatedInspectionInterfaceTests: XCTestCase {
    private func openTree() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["idle", "inspection"]
        app.launch()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let link = app.descendants(matching: .any).matching(identifier: "session-tree-link").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        XCTAssertTrue(app.navigationBars["Session tree"].waitForExistence(timeout: 5))
        let leaf = app.staticTexts["session-tree-leaf"]
        XCTAssertTrue(leaf.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Active leaf in snapshot: active-leaf"), object: leaf)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication, up: Bool = false) {
        _ = revealElement({ element }, app: app, up: up)
    }
    private func revealLabel(_ label: String, app: XCUIApplication, up: Bool = false) -> XCUIElement {
        revealElement({ app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch }, app: app, up: up)
    }
    private func revealElement(_ resolve: () -> XCUIElement, app: XCUIApplication, up: Bool) -> XCUIElement {
        var towardTop = up
        for attempt in 0..<30 {
            let element = resolve()
            let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max() ?? 0
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists, !frame.isEmpty {
                if element.isHittable, frame.minY >= top, frame.maxY <= app.frame.maxY - 4 {
                    XCTAssertTrue(app.frame.contains(frame))
                    if element.elementType == .button {
                        XCTAssertGreaterThanOrEqual(frame.width, 44)
                        XCTAssertGreaterThanOrEqual(frame.height, 44)
                    }
                    return element
                }
                towardTop = frame.minY < top
            }
            XCTContext.runActivity(named: "Inspector scroll \(attempt): earlier=\(towardTop), targetExists=\(exists), frame=\(frame), top=\(top)") { _ in }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: towardTop ? 0.45 : 0.75))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: towardTop ? 0.75 : 0.45)))
        }
        capture(app, "populated-inspection-unreachable-control")
        let snapshot = XCTAttachment(string: app.debugDescription)
        snapshot.name = "Populated inspection unreachable hierarchy"; snapshot.lifetime = .keepAlways; add(snapshot)
        XCTFail("Inspection control did not become fully reachable; see the attached hierarchy.")
        return resolve()
    }
    private func closeForegroundPreview(_ app: XCUIApplication) {
        let button = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(button, "The foreground preview must have a visible Done action")
        button?.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testPopulatedTreePreservesLeafResolvedLabelTimestampAndPaging() {
        let app = openTree()
        defer { app.terminate() }
        let label = app.staticTexts["Label: Root checkpoint"]
        reveal(label, app: app)
        let timestamp = app.staticTexts["Label timestamp: 2024-12-03T14:30:00.125Z"]
        reveal(timestamp, app: app)
        XCTAssertTrue(timestamp.exists)
        XCTAssertFalse(app.staticTexts["session-tree-error"].exists)
        capture(app, "populated-inspection-label-and-timestamp")
        let next = app.buttons["Next tree page"]
        reveal(next, app: app); next.tap()
        _ = revealLabel("message · whitespace", app: app)
        let empty = revealLabel("message · empty-text", app: app)
        XCTAssertTrue(empty.exists)
        capture(app, "populated-inspection-second-page")
        XCTAssertFalse(app.buttons["Next tree page"].exists)
        // The only option on page two is nonempty whitespace. Empty text has none.
        let fork = revealLabel("Fork from this message", app: app, up: true)
        XCTAssertEqual(fork.elementType, .button)
        XCTAssertEqual(app.buttons.matching(identifier: "Fork from this message").count, 1)
        let previous = revealLabel("Previous tree page", app: app, up: true)
        XCTAssertEqual(previous.elementType, .button); previous.tap()
        let leaf = revealLabel("Active leaf in snapshot: active-leaf", app: app, up: true)
        XCTAssertEqual(leaf.label, "Active leaf in snapshot: active-leaf")
        let restoredLabel = revealLabel("Label: Root checkpoint", app: app)
        XCTAssertTrue(restoredLabel.exists)
    }

    func testPopulatedTreeOpensFullTextAndOriginalImagePreviews() {
        let app = openTree()
        defer { app.terminate() }
        let fork = app.buttons["Fork from this message"]
        reveal(fork, app: app)
        let textRead = app.buttons.matching(identifier: "Read entry").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(textRead); textRead?.tap()
        XCTAssertTrue(app.navigationBars["Abandoned entry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Exact full preview beyond abbreviated tree text.")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "populated-inspection-full-text-preview")
        closeForegroundPreview(app)
        let textDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Abandoned entry"])
        XCTAssertEqual(XCTWaiter.wait(for: [textDismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Session tree"].waitForExistence(timeout: 5))
        let imageNode = app.staticTexts["message · image-only"]
        reveal(imageNode, app: app)
        // List virtualization can leave only the preceding text row's action loaded.
        // Select a fully visible Read entry below the visible image-node heading.
        var imageRead: XCUIElement?
        for _ in 0..<8 {
            if imageNode.exists {
                let header = imageNode.frame
                imageRead = app.buttons.matching(identifier: "Read entry").allElementsBoundByIndex.first {
                    let frame = $0.frame
                    return $0.isHittable && frame.minY >= header.maxY && frame.maxY <= app.frame.maxY - 4
                }
                if imageRead != nil { break }
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.65))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.45)))
        }
        XCTAssertNotNil(imageRead, "The image node must expose its own visible Read entry action")
        if let imageRead { reveal(imageRead, app: app); capture(app, "populated-inspection-image-entry-action"); imageRead.tap() }
        XCTAssertTrue(app.navigationBars["Image-only entry"].waitForExistence(timeout: 5))
        let image = app.buttons["View image 1"]
        XCTAssertTrue(image.waitForExistence(timeout: 5)); image.tap()
        XCTAssertTrue(app.navigationBars["Image output"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["32 × 32 pixels"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Pi image output"].exists)
        let full = app.switches["Full resolution"]
        XCTAssertTrue(full.isHittable)
        full.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let original = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: full)
        XCTAssertEqual(XCTWaiter.wait(for: [original], timeout: 5), .completed)
        capture(app, "populated-inspection-image-preview")
        closeForegroundPreview(app)
        let imageDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Image output"])
        XCTAssertEqual(XCTWaiter.wait(for: [imageDismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Image-only entry"].waitForExistence(timeout: 5))
        closeForegroundPreview(app)
        let entryDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Image-only entry"])
        XCTAssertEqual(XCTWaiter.wait(for: [entryDismissed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Session tree"].waitForExistence(timeout: 5))
    }

    func testPopulatedTreeOffersOnlyEligibleForkAndRestoresAbandonedDraftWithoutSending() {
        let app = openTree()
        defer { app.terminate() }
        let fork = app.buttons["Fork from this message"]
        reveal(fork, app: app)
        XCTAssertEqual(app.buttons.matching(identifier: "Fork from this message").count, 1)
        XCTAssertTrue(app.staticTexts["Abandoned branch preview"].exists)
        capture(app, "populated-inspection-abandoned-fork-option")
        fork.tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        let instruction = app.descendants(matching: .any).matching(identifier: "instruction").firstMatch
        XCTAssertTrue(instruction.waitForExistence(timeout: 5))
        let draft = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Abandoned branch draft; not sent."), object: instruction)
        XCTAssertEqual(XCTWaiter.wait(for: [draft], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["Stop"].exists)
        XCTAssertFalse(app.navigationBars["Session tree"].exists)
    }
}
