import CoreGraphics
import XCTest

final class MacConversationLayoutTests: XCTestCase {
    func testDesktopDockDoesNotDependOnHistoryPosition() {
        for height: CGFloat in [600, 900] {
            for flowY: CGFloat in [-2_000, 0, 500, 2_000] {
                let layout = PiConversationLayout(isDesktop: true, viewportHeight: height,
                                                  naturalDockHeight: 180, flowDockY: flowY)
                XCTAssertEqual(layout.dockY + layout.dockHeight, height)
                XCTAssertTrue(layout.dockIntersectsViewport)
            }
        }
    }

    func testPiDockUsesFlowPositionAndDoesNotInterceptOutsideViewport() {
        for flowY: CGFloat in [-2_000, -180, 600, 2_000] {
            let layout = PiConversationLayout(isDesktop: false, viewportHeight: 600,
                                              naturalDockHeight: 180, flowDockY: flowY)
            XCTAssertEqual(layout.dockY, flowY)
            XCTAssertFalse(layout.dockIntersectsViewport)
        }
        let partiallyVisible = PiConversationLayout(isDesktop: false, viewportHeight: 600,
                                                    naturalDockHeight: 180, flowDockY: -90)
        XCTAssertTrue(partiallyVisible.dockIntersectsViewport)
    }

    func testOversizedDockLeavesHistorySpaceWithoutChangingNaturalHeight() {
        for height: CGFloat in [600, 900] {
            for desktop in [false, true] {
                let layout = PiConversationLayout(isDesktop: desktop, viewportHeight: height,
                                                  naturalDockHeight: 10_000, flowDockY: 0)
                XCTAssertEqual(layout.dockHeight, height * 0.75)
                XCTAssertLessThan(layout.dockHeight, height)
                XCTAssertEqual(layout.naturalDockHeight, 10_000)
            }
        }
    }
}
