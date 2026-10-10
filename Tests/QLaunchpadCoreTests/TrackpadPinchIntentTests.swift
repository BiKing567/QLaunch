import XCTest
@testable import QLaunchpadCore

final class TrackpadPinchIntentTests: XCTestCase {
    func testInitialStateIsUndecided() {
        let intent = TrackpadPinchIntent()
        XCTAssertEqual(intent.phase, .undecided)
    }

    func testPinchInwardIsConfirmedWhenTravelIsLow() {
        var intent = TrackpadPinchIntent()
        // Baseline spread ratio = 1.0, small jitter inside deadZone
        XCTAssertFalse(intent.update(ratio: 0.98, travel: 0.01))
        XCTAssertEqual(intent.phase, .undecided)

        // Past deadZone (deadZone = 0.05), travel well below swipe threshold (0.05)
        let confirmed = intent.update(ratio: 0.88, travel: 0.015)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(intent.phase, .pinch)

        // Subsequent frames remain confirmed as pinch
        XCTAssertTrue(intent.update(ratio: 0.70, travel: 0.02))
        XCTAssertEqual(intent.phase, .pinch)
    }

    func testPinchOutwardIsConfirmedWhenTravelIsLow() {
        var intent = TrackpadPinchIntent()
        // Outward spread (ratio > 1 + 0.05)
        let confirmed = intent.update(ratio: 1.15, travel: 0.02)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(intent.phase, .pinch)
    }

    func testSwipeIsDetectedWhenCenterOfGravityTranslatesSignificantly() {
        var intent = TrackpadPinchIntent()
        // Fingers moving together across trackpad (travel >= 0.25) while spread barely changed
        let confirmed = intent.update(ratio: 0.98, travel: 0.25)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(intent.phase, .swipe)

        // Even if fingers subsequently gather inward upon liftoff, swipe status persists
        let subsequent = intent.update(ratio: 0.65, travel: 0.30)
        XCTAssertFalse(subsequent)
        XCTAssertEqual(intent.phase, .swipe)
    }

    func testAsymmetricalPinchWithMildTravelIsConfirmed() {
        var intent = TrackpadPinchIntent()
        // Natural human pinch where thumb is relatively stationary and index/middle sweep inward (travel = 0.12, ratio = 0.85)
        let confirmed = intent.update(ratio: 0.85, travel: 0.12)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(intent.phase, .pinch)
    }

    func testSimultaneousHighTravelAndRatioDeviationFavorsSwipeToPreventFalseOpens() {
        var intent = TrackpadPinchIntent()
        // If travel is huge (full hand sweep across pad, travel >= 0.35), reject as swipe even if fingers contract
        let confirmed = intent.update(ratio: 0.80, travel: 0.40)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(intent.phase, .swipe)
    }
}
