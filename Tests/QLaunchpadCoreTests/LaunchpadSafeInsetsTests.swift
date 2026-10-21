import XCTest
@testable import QLaunchpadCore

final class LaunchpadSafeInsetsTests: XCTestCase {
    func testZeroInsets() {
        let insets = LaunchpadSafeInsets.zero
        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.left, 0)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertEqual(insets.right, 0)
        XCTAssertTrue(insets.isZero)
    }

    func testClampedNegativeInsets() {
        let insets = LaunchpadSafeInsets(top: -10, left: -20, bottom: -30, right: -40)
        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.left, 0)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertEqual(insets.right, 0)
        XCTAssertTrue(insets.isZero)
    }

    func testCustomInsets() {
        let insets = LaunchpadSafeInsets(top: 30, left: 0, bottom: 70, right: 0)
        XCTAssertEqual(insets.top, 30)
        XCTAssertEqual(insets.left, 0)
        XCTAssertEqual(insets.bottom, 70)
        XCTAssertEqual(insets.right, 0)
        XCTAssertFalse(insets.isZero)
    }

    func testInfiniteCanvasMetricsDefaultInsetsAreZero() {
        let viewport = CGSize(width: 1440, height: 900)
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        XCTAssertEqual(metrics.safeInsets, .zero)
        XCTAssertEqual(metrics.viewportCenter.x, viewport.width * 0.5)
        XCTAssertEqual(metrics.viewportCenter.y, 120 + metrics.availableSize.height * 0.5)
    }

    func testInfiniteCanvasMetricsWithDockSafeInsets() {
        let viewport = CGSize(width: 1440, height: 900)
        let insets = LaunchpadSafeInsets(top: 30, left: 0, bottom: 80, right: 0)
        let metricsWithDock = InfiniteCanvasMetrics(size: viewport, itemCount: 40, safeInsets: insets)
        let metricsWithoutDock = InfiniteCanvasMetrics(size: viewport, itemCount: 40, safeInsets: .zero)

        // Available height must be reduced by top (30) and bottom (80)
        XCTAssertEqual(
            metricsWithDock.availableSize.height,
            metricsWithoutDock.availableSize.height - 30 - 80
        )
        // Viewport center Y should shift to accommodate top and bottom insets
        let expectedTop = 120 + insets.top
        let expectedCenterY = expectedTop + metricsWithDock.availableSize.height * 0.5
        XCTAssertEqual(metricsWithDock.viewportCenter.y, expectedCenterY, accuracy: 0.0001)
    }

    func testInfiniteCanvasMetricsWithLeftDockSafeInsets() {
        let viewport = CGSize(width: 1440, height: 900)
        let insets = LaunchpadSafeInsets(top: 0, left: 90, bottom: 0, right: 0)
        let metricsWithLeftDock = InfiniteCanvasMetrics(size: viewport, itemCount: 40, safeInsets: insets)
        let metricsWithoutDock = InfiniteCanvasMetrics(size: viewport, itemCount: 40, safeInsets: .zero)

        // Available width should be reduced by left inset (90)
        XCTAssertEqual(
            metricsWithLeftDock.availableSize.width,
            metricsWithoutDock.availableSize.width - 90
        )
        // Viewport center X should shift right
        let usableWidth = viewport.width - 90
        let expectedCenterX = 90 + usableWidth * 0.5
        XCTAssertEqual(metricsWithLeftDock.viewportCenter.x, expectedCenterX, accuracy: 0.0001)
    }

    func testInfiniteCanvasMetricsWithRightDockSafeInsets() {
        let viewport = CGSize(width: 1440, height: 900)
        let insets = LaunchpadSafeInsets(top: 0, left: 0, bottom: 0, right: 90)
        let metricsWithRightDock = InfiniteCanvasMetrics(size: viewport, itemCount: 40, safeInsets: insets)
        let metricsWithoutDock = InfiniteCanvasMetrics(size: viewport, itemCount: 40, safeInsets: .zero)

        // Available width should be reduced by right inset (90)
        XCTAssertEqual(
            metricsWithRightDock.availableSize.width,
            metricsWithoutDock.availableSize.width - 90
        )
        // Viewport center X should shift left
        let usableWidth = viewport.width - 90
        let expectedCenterX = usableWidth * 0.5
        XCTAssertEqual(metricsWithRightDock.viewportCenter.x, expectedCenterX, accuracy: 0.0001)
    }

    func testInfiniteCanvasMetricsWithMenuBarAndBottomDock() {
        let viewport = CGSize(width: 2560, height: 1440)
        let insets = LaunchpadSafeInsets(top: 32, left: 0, bottom: 64, right: 0)
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 50, safeInsets: insets)
        let uninsetMetrics = InfiniteCanvasMetrics(size: viewport, itemCount: 50, safeInsets: .zero)

        XCTAssertEqual(metrics.availableSize.width, uninsetMetrics.availableSize.width)
        XCTAssertEqual(metrics.availableSize.height, uninsetMetrics.availableSize.height - 32 - 64)
        XCTAssertEqual(metrics.viewportCenter.x, viewport.width * 0.5)
        XCTAssertEqual(
            metrics.viewportCenter.y,
            (120 + 32) + (uninsetMetrics.availableSize.height - 96) * 0.5,
            accuracy: 0.0001
        )
    }
}
