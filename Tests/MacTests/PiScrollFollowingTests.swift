import SwiftUI
import XCTest

final class PiScrollFollowingTests: XCTestCase {
    func testInitialStateFollowsLatest() {
        let following = PiScrollFollowing()
        XCTAssertTrue(following.isFollowing)
        XCTAssertTrue(following.atBottom)
    }

    func testEveryUserScrollPhasePausesFollowingUntilIdle() {
        for phase in [ScrollPhase.tracking, .interacting, .decelerating] {
            var following = PiScrollFollowing()
            following.phaseChanged(phase)
            XCTAssertFalse(following.isFollowing)
            following.geometryChanged(atBottom: true)
            XCTAssertFalse(following.isFollowing, "Geometry must not resume an active gesture")
            following.phaseChanged(.idle)
            XCTAssertTrue(following.isFollowing)
        }
    }

    func testScrollingAwayKeepsReadingPositionWhenOutputArrives() {
        var following = PiScrollFollowing()
        following.phaseChanged(.tracking)
        following.phaseChanged(.interacting)
        following.geometryChanged(atBottom: false)
        following.phaseChanged(.decelerating)
        following.phaseChanged(.idle)
        XCTAssertFalse(following.isFollowing)
        XCTAssertFalse(following.atBottom)
        following.geometryChanged(atBottom: false)
        XCTAssertFalse(following.isFollowing)
    }

    func testManualReturnToBottomResumesOnlyAfterGestureEnds() {
        var following = PiScrollFollowing()
        following.phaseChanged(.interacting)
        following.geometryChanged(atBottom: false)
        following.phaseChanged(.idle)
        XCTAssertFalse(following.isFollowing)

        following.phaseChanged(.tracking)
        following.phaseChanged(.interacting)
        following.geometryChanged(atBottom: true)
        following.phaseChanged(.decelerating)
        XCTAssertFalse(following.isFollowing)
        following.phaseChanged(.idle)
        XCTAssertTrue(following.isFollowing)
    }

    func testLayoutAndProgrammaticScrollingCannotResumePausedFollowing() {
        var following = PiScrollFollowing()
        following.phaseChanged(.interacting)
        following.geometryChanged(atBottom: false)
        following.phaseChanged(.idle)

        following.geometryChanged(atBottom: true)
        XCTAssertTrue(following.atBottom)
        XCTAssertFalse(following.isFollowing)
        following.phaseChanged(.animating)
        following.phaseChanged(.idle)
        XCTAssertFalse(following.isFollowing)
    }

    func testLayoutGrowthDoesNotPauseLiveFollowing() {
        var following = PiScrollFollowing()
        following.geometryChanged(atBottom: false)
        following.phaseChanged(.animating)
        following.phaseChanged(.idle)
        XCTAssertTrue(following.isFollowing)
    }

    func testLatestResumesAndClearsPendingUserGesture() {
        var following = PiScrollFollowing()
        following.phaseChanged(.interacting)
        following.geometryChanged(atBottom: false)
        following.resume()
        XCTAssertTrue(following.isFollowing)
        following.phaseChanged(.idle)
        XCTAssertTrue(following.isFollowing, "An old gesture must not undo explicit Latest")
    }

    func testResetRestoresInitialStateAndClearsPendingUserGesture() {
        var following = PiScrollFollowing()
        following.phaseChanged(.interacting)
        following.geometryChanged(atBottom: false)
        following.reset()
        XCTAssertTrue(following.isFollowing)
        XCTAssertTrue(following.atBottom)
        following.geometryChanged(atBottom: false)
        following.phaseChanged(.idle)
        XCTAssertTrue(following.isFollowing)
    }
}
