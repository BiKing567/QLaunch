import XCTest
@testable import QLaunchpadCore

final class VersionComparatorTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(VersionComparator.isVersion("v1.1", greaterThan: "1.0.24"))
        XCTAssertTrue(VersionComparator.isVersion("V1.1", greaterThan: "1.0.24"))
        XCTAssertTrue(VersionComparator.isVersion("1.1.0", greaterThan: "1.0.24"))
        XCTAssertTrue(VersionComparator.isVersion("v1.2", greaterThan: "v1.1"))
        XCTAssertTrue(VersionComparator.isVersion("1.1.1", greaterThan: "1.1.0"))
        XCTAssertTrue(VersionComparator.isVersion("2.0.0", greaterThan: "1.9.9"))

        XCTAssertFalse(VersionComparator.isVersion("1.1.0", greaterThan: "1.1.0"))
        XCTAssertFalse(VersionComparator.isVersion("v1.1", greaterThan: "1.1.0"))
        XCTAssertFalse(VersionComparator.isVersion("V1.1", greaterThan: "1.1.0"))
        XCTAssertFalse(VersionComparator.isVersion("1.0.24", greaterThan: "1.1.0"))
        XCTAssertFalse(VersionComparator.isVersion("1.0.24", greaterThan: "1.0.24"))
        XCTAssertFalse(VersionComparator.isVersion("1.0.24-preview", greaterThan: "1.0.24"))
    }
}
