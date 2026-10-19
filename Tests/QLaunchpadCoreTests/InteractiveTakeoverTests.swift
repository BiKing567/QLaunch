import XCTest
@testable import QLaunchpadCore

final class InteractiveTakeoverTests: XCTestCase {
    func testClosingTakeoverDoesNotJump() {
        // Interrupted closing at 0.20 receives fresh gesture at 0.02.
        // Previously jumped from 0.20 to 1.0 - 0.02 = 0.98.
        let p = InteractiveTakeover.rebasedProgress(
            baseProgress: 0.20,
            gestureProgress: 0.02,
            isOpening: false
        )
        XCTAssertEqual(p, 0.196, accuracy: 0.0001)

        // As gesture completes, it smoothly reaches 0.0.
        let finished = InteractiveTakeover.rebasedProgress(
            baseProgress: 0.20,
            gestureProgress: 1.0,
            isOpening: false
        )
        XCTAssertEqual(finished, 0.0, accuracy: 0.0001)
    }

    func testOpeningTakeoverDoesNotResetToZero() {
        // Interrupted opening at 0.12 receives fresh gesture at 0.02.
        // Previously reset to 0.00 then jumped to 0.02.
        let p = InteractiveTakeover.rebasedProgress(
            baseProgress: 0.12,
            gestureProgress: 0.02,
            isOpening: true
        )
        XCTAssertEqual(p, 0.1376, accuracy: 0.0001)

        // As gesture completes, it smoothly reaches 1.0.
        let finished = InteractiveTakeover.rebasedProgress(
            baseProgress: 0.12,
            gestureProgress: 1.0,
            isOpening: true
        )
        XCTAssertEqual(finished, 1.0, accuracy: 0.0001)
    }

    func testDefaultOpeningAndClosingFromEndpoints() {
        // Normal open from 0.0.
        let openHalf = InteractiveTakeover.rebasedProgress(
            baseProgress: 0.0,
            gestureProgress: 0.5,
            isOpening: true
        )
        XCTAssertEqual(openHalf, 0.5, accuracy: 0.0001)

        // Normal close from 1.0.
        let closeHalf = InteractiveTakeover.rebasedProgress(
            baseProgress: 1.0,
            gestureProgress: 0.5,
            isOpening: false
        )
        XCTAssertEqual(closeHalf, 0.5, accuracy: 0.0001)
    }

    func testClampingOutOfBounds() {
        let clampedOpen = InteractiveTakeover.rebasedProgress(
            baseProgress: -0.5,
            gestureProgress: 1.5,
            isOpening: true
        )
        XCTAssertEqual(clampedOpen, 1.0, accuracy: 0.0001)

        let clampedClose = InteractiveTakeover.rebasedProgress(
            baseProgress: 1.5,
            gestureProgress: -0.2,
            isOpening: false
        )
        XCTAssertEqual(clampedClose, 1.0, accuracy: 0.0001)
    }

    func testFinishEntryPreservesStartingProgressWhenTargetingOne() {
        // Committing open or cancelling close at 0.8:
        let finish = InteractiveTakeover.finishParameters(currentProgress: 0.8, target: 1.0)
        XCTAssertEqual(finish.from, 0.8, accuracy: 0.0001, "Finish start must retain current progress 0.8, not 0")
        XCTAssertEqual(finish.to, 1.0, accuracy: 0.0001)
        XCTAssertFalse(finish.isDismissing)
        XCTAssertGreaterThanOrEqual(finish.duration, 0.12)
        XCTAssertLessThanOrEqual(finish.duration, 0.30)
    }

    func testFinishEntryPreservesStartingProgressWhenTargetingZero() {
        // Committing close or cancelling open at 0.2:
        let finish = InteractiveTakeover.finishParameters(currentProgress: 0.2, target: 0.0)
        XCTAssertEqual(finish.from, 0.2, accuracy: 0.0001, "Finish start must retain current progress 0.2, not 1")
        XCTAssertEqual(finish.to, 0.0, accuracy: 0.0001)
        XCTAssertTrue(finish.isDismissing)
        XCTAssertGreaterThanOrEqual(finish.duration, 0.12)
        XCTAssertLessThanOrEqual(finish.duration, 0.30)
    }
}
