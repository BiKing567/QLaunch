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
        // Four fingers moving across trackpad (travel > 0.05) while spread barely changed
        let confirmed = intent.update(ratio: 0.99, travel: 0.08)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(intent.phase, .swipe)

        // Even if fingers subsequently gather inward upon liftoff, swipe status persists
        let subsequent = intent.update(ratio: 0.65, travel: 0.12)
        XCTAssertFalse(subsequent)
        XCTAssertEqual(intent.phase, .swipe)
    }

    func testSimultaneousHighTravelAndRatioDeviationFavorsSwipeToPreventFalseOpens() {
        var intent = TrackpadPinchIntent()
        // If travel and ratio both exceed thresholds on the same frame, must reject as swipe
        let confirmed = intent.update(ratio: 0.80, travel: 0.09)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(intent.phase, .swipe)
    }
}
