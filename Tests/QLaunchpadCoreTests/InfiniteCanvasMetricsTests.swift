import XCTest
@testable import QLaunchpadCore

final class InfiniteCanvasMetricsTests: XCTestCase {
    private let viewport = CGSize(width: 1440, height: 900)

    func testReorderDoesNotChangeWorldSize() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        XCTAssertEqual(before.worldSize, after.worldSize)
        XCTAssertEqual(before.rows, after.rows)
        XCTAssertEqual(before.viewportFillingScale, after.viewportFillingScale, accuracy: 0.0001)
    }

    func testCameraPreservesScaleWhenItemCountChanges() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 39)
        let scale: CGFloat = 1.35
        let pan = CGPoint(x: 80, y: -40)

        let preserved = after.cameraPreservingGridPoint(
            from: before,
            scale: scale,
            pan: pan,
            minimumScale: max(after.fittedScale, 0.12),
            maximumScale: 2
        )

        XCTAssertEqual(preserved.scale, scale, accuracy: 0.0001)
    }

    func testCameraKeepsViewportCenterOnTheSameGridPoint() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 40)
        let after = InfiniteCanvasMetrics(size: viewport, itemCount: 24)
        let scale: CGFloat = 1.2
        let pan = CGPoint(x: 60, y: 30)
        let originalGrid = before.gridPoint(
            forWorldPoint: before.worldPoint(
                atScreenPoint: before.viewportCenter,
                scale: scale,
                pan: pan
            )
        )

        let preserved = after.cameraPreservingGridPoint(
            from: before,
            scale: scale,
            pan: pan,
            minimumScale: max(after.fittedScale, 0.12),
            maximumScale: 2
        )
        let newGrid = after.gridPoint(
            forWorldPoint: after.worldPoint(
                atScreenPoint: after.viewportCenter,
                scale: preserved.scale,
                pan: preserved.pan
            )
        )

        XCTAssertEqual(newGrid.x, originalGrid.x, accuracy: 0.0001)
        XCTAssertEqual(newGrid.y, originalGrid.y, accuracy: 0.0001)
    }

    func testCameraKeepsScaleAcrossViewportResize() {
        let before = InfiniteCanvasMetrics(size: viewport, itemCount: 48)
        let after = InfiniteCanvasMetrics(
            size: CGSize(width: 1680, height: 1050),
            itemCount: 48
        )
        let scale: CGFloat = 1.4
        let pan = CGPoint(x: -50, y: 20)

        let preserved = after.cameraPreservingGridPoint(
            from: before,
            scale: scale,
            pan: pan,
            minimumScale: max(after.fittedScale, 0.12),
            maximumScale: 2
        )

        XCTAssertEqual(preserved.scale, scale, accuracy: 0.0001)
    }

    func testScreenAndWorldRoundTrip() {
        let metrics = InfiniteCanvasMetrics(size: viewport, itemCount: 32)
        let scale: CGFloat = 1.15
        let pan = CGPoint(x: 25, y: -18)
        let screen = CGPoint(x: 700, y: 400)
        let world = metrics.worldPoint(atScreenPoint: screen, scale: scale, pan: pan)
        let restoredPan = metrics.pan(placing: world, atScreenPoint: screen, scale: scale)
        XCTAssertEqual(restoredPan.x, pan.x, accuracy: 0.0001)
        XCTAssertEqual(restoredPan.y, pan.y, accuracy: 0.0001)
    }
}
