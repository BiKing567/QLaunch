import CoreGraphics
import Foundation
@testable import QLaunchpadCore
import XCTest

final class FolderCardMetricsTests: XCTestCase {
    func testDynamicRowsAdaptToItemCount() {
        let size = CGSize(width: 1440, height: 900)

        // 0 items -> 1 row
        let metrics0 = FolderCardMetrics(boundsSize: size, itemCount: 0, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics0.rows, 1)

        // 3 items -> 1 row
        let metrics3 = FolderCardMetrics(boundsSize: size, itemCount: 3, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics3.rows, 1)

        // 7 items -> 1 row
        let metrics7 = FolderCardMetrics(boundsSize: size, itemCount: 7, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics7.rows, 1)

        // 8 items -> 2 rows
        let metrics8 = FolderCardMetrics(boundsSize: size, itemCount: 8, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics8.rows, 2)

        // 14 items -> 2 rows
        let metrics14 = FolderCardMetrics(boundsSize: size, itemCount: 14, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics14.rows, 2)

        // 15 items -> 3 rows
        let metrics15 = FolderCardMetrics(boundsSize: size, itemCount: 15, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics15.rows, 3)

        // 28 items -> 4 rows (maxVisibleRows)
        let metrics28 = FolderCardMetrics(boundsSize: size, itemCount: 28, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics28.rows, 4)

        // 35 items -> capped at maxVisibleRows (4 rows), page capacity is 28
        let metrics35 = FolderCardMetrics(boundsSize: size, itemCount: 35, targetColumns: 7, maxVisibleRows: 4)
        XCTAssertEqual(metrics35.rows, 4)
        XCTAssertEqual(metrics35.pageCapacity, 28)
    }

    func testCardDimensionsAndCentering() {
        let size = CGSize(width: 1920, height: 1080)
        let safeInsets = LaunchpadSafeInsets(top: 25, left: 0, bottom: 0, right: 0)
        let metrics = FolderCardMetrics(
            boundsSize: size,
            safeInsets: safeInsets,
            itemCount: 9,
            targetColumns: 7,
            maxVisibleRows: 4,
            iconSize: 128
        )

        XCTAssertEqual(metrics.cardCornerRadius, 32)
        XCTAssertTrue(metrics.cardRect.width > 0)
        XCTAssertTrue(metrics.cardRect.height > 0)

        // Card should be horizontally centered
        let expectedCardX = (size.width - metrics.cardRect.width) * 0.5
        XCTAssertEqual(metrics.cardRect.origin.x, expectedCardX, accuracy: 0.1)

        // Title rect should be centered horizontally within card
        XCTAssertEqual(metrics.titleRect.midX, size.width * 0.5, accuracy: 0.1)

        // Content rect should be horizontally centered within card
        XCTAssertEqual(metrics.contentRect.midX, metrics.cardRect.midX, accuracy: 0.1)
    }

    func testCardContainment() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 5, targetColumns: 7, maxVisibleRows: 4)

        let insidePoint = CGPoint(x: metrics.cardRect.midX, y: metrics.cardRect.midY)
        XCTAssertTrue(metrics.isPointInsideCard(insidePoint))

        let outsideTopLeft = CGPoint(x: 10, y: 10)
        XCTAssertFalse(metrics.isPointInsideCard(outsideTopLeft))

        let outsideBottomRight = CGPoint(x: size.width - 10, y: size.height - 10)
        XCTAssertFalse(metrics.isPointInsideCard(outsideBottomRight))
    }

    func testHitTestingAndIconCenters() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 10, targetColumns: 7, maxVisibleRows: 4)

        // Verify icon 0 center hit test
        let icon0Center = metrics.iconCenter(globalIndex: 0, pageOffset: 0)
        let hit0 = metrics.hitTest(point: icon0Center, pageOffset: 0)
        XCTAssertEqual(hit0, 0)

        // Verify icon 7 (second row, first column)
        let icon7Center = metrics.iconCenter(globalIndex: 7, pageOffset: 0)
        let hit7 = metrics.hitTest(point: icon7Center, pageOffset: 0)
        XCTAssertEqual(hit7, 7)

        // Far outside point hits nothing
        let miss = metrics.hitTest(point: CGPoint(x: 10, y: 10), pageOffset: 0)
        XCTAssertNil(miss)
    }

    func testContinuousFractionalCenterInterpolation() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 5, targetColumns: 7, maxVisibleRows: 4)

        let c0 = metrics.iconCenter(globalIndex: 0.0, pageOffset: 0)
        let c1 = metrics.iconCenter(globalIndex: 1.0, pageOffset: 0)
        let cMid = metrics.iconCenter(globalIndex: 0.5, pageOffset: 0)

        XCTAssertEqual(cMid.x, (c0.x + c1.x) * 0.5, accuracy: 0.01)
        XCTAssertEqual(cMid.y, (c0.y + c1.y) * 0.5, accuracy: 0.01)
    }

    func testAppKitCoordinateConversionsAndHitTesting() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 60, targetColumns: 7, maxVisibleRows: 4)

        // Test AppKit card rect
        let cardTop = metrics.cardRect
        let cardAppKit = metrics.cardRectAppKit
        XCTAssertEqual(cardAppKit.origin.x, cardTop.origin.x)
        XCTAssertEqual(cardAppKit.origin.y, size.height - cardTop.maxY)
        XCTAssertEqual(cardAppKit.width, cardTop.width)
        XCTAssertEqual(cardAppKit.height, cardTop.height)

        // Point inside card in AppKit coordinates
        let insideTop = CGPoint(x: cardTop.midX, y: cardTop.midY)
        let insideAppKit = metrics.topLeftToAppKit(insideTop)
        XCTAssertTrue(metrics.isAppKitPointInsideCard(insideAppKit))
        XCTAssertEqual(metrics.appKitToTopLeft(insideAppKit), insideTop)

        // Click on first icon in AppKit coordinates (P1 issue reproduction & fix test)
        let firstTop = metrics.iconCenter(globalIndex: 0, pageOffset: 0)
        let appKitClick = CGPoint(x: firstTop.x, y: size.height - firstTop.y)
        let hit = metrics.hitTestAppKit(point: appKitClick, pageOffset: 0)
        XCTAssertEqual(hit, 0)

        // Far bottom-left click is outside card
        let outsideAppKit = CGPoint(x: 20, y: 20)
        XCTAssertFalse(metrics.isAppKitPointInsideCard(outsideAppKit))
    }

    func testPageIndicatorGeometryAndHitTesting() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 60, targetColumns: 7, maxVisibleRows: 4)

        let visualRectTop = metrics.pageIndicatorVisualRect(pageCount: 3, currentPage: 0, flipped: true)
        let visualRectAppKit = metrics.pageIndicatorVisualRect(pageCount: 3, currentPage: 0, flipped: false)

        // Check horizontal centering
        XCTAssertEqual(visualRectTop.midX, metrics.cardRect.midX, accuracy: 0.1)
        XCTAssertEqual(visualRectAppKit.midX, metrics.cardRect.midX, accuracy: 0.1)

        // Check vertical alignment
        XCTAssertEqual(visualRectTop.midY, metrics.cardRect.maxY - 14, accuracy: 0.1)
        XCTAssertEqual(visualRectAppKit.midY, size.height - (metrics.cardRect.maxY - 14), accuracy: 0.1)

        // Test hit testing on page indicator dots
        let centers = metrics.pageIndicatorDotCenters(pageCount: 3, currentPage: 0)
        XCTAssertEqual(centers.count, 3)

        // Click on page 1 dot in AppKit coordinates
        let page1Click = CGPoint(x: centers[1], y: visualRectAppKit.midY)
        let hitPage1 = metrics.pageIndicatorPageIndex(at: page1Click, pageCount: 3, currentPage: 0, flipped: false)
        XCTAssertEqual(hitPage1, 1)

        // Click on page 0 dot in flipped coordinates
        let page0ClickTop = CGPoint(x: centers[0], y: visualRectTop.midY)
        let hitPage0 = metrics.pageIndicatorPageIndex(at: page0ClickTop, pageCount: 3, currentPage: 0, flipped: true)
        XCTAssertEqual(hitPage0, 0)
    }

    func testClosingFromSecondPageMaintainsAppPosition() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 60, targetColumns: 7, maxVisibleRows: 4)

        // When resting on page 1:
        let firstOnPage1 = metrics.pageCapacity
        let restingCenter = metrics.iconCenter(globalIndex: Double(firstOnPage1), pageOffset: 1.0)

        // When closing transition captures folderPageOffset = 1.0, destination matches visual resting position:
        let closingDestinationCenter = metrics.iconCenter(globalIndex: Double(firstOnPage1), pageOffset: 1.0)
        XCTAssertEqual(restingCenter.x, closingDestinationCenter.x, accuracy: 0.001)
        XCTAssertEqual(restingCenter.y, closingDestinationCenter.y, accuracy: 0.001)

        // In contrast, if pageOffset was hardcoded to 0.0, it would jump horizontally across the screen:
        let page0Center = metrics.iconCenter(globalIndex: Double(firstOnPage1), pageOffset: 0.0)
        XCTAssertEqual(abs(page0Center.x - restingCenter.x), metrics.cardRect.width, accuracy: 0.1)
    }

    func testAnimatedHitTestingFollowsRenderedPositionNotDestinationSlot() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = FolderCardMetrics(boundsSize: size, itemCount: 9, targetColumns: 6, maxVisibleRows: 4)

        let sourceCenter = CGPoint(x: 186.66666666666669, y: 167.625)
        let app8From = FolderPreviewLayout.miniCenter(index: 8, folderCenter: sourceCenter, folderSize: 128, yIncreasesDown: true)
        let app8Dest = metrics.iconCenter(globalIndex: 8, pageOffset: 0)
        let app8Progress03 = CGPoint(
            x: app8From.x + (app8Dest.x - app8From.x) * 0.3,
            y: app8From.y + (app8Dest.y - app8From.y) * 0.3
        )

        // Clicking directly on app8's rendered center would falsely hit slot 0 if resting layout is checked prematurely:
        let appKitPoint = CGPoint(x: app8Progress03.x, y: size.height - app8Progress03.y)
        let prematureHit = metrics.hitTestAppKit(point: appKitPoint, pageOffset: 0, hitRadiusScale: 0.95)
        XCTAssertEqual(prematureHit, 0, "Confirms that premature destination layout test would have misdirected click to slot 0")

        // In contrast, checking visual distances to animated centers correctly identifies item 8:
        let centers: [CGPoint] = (0..<9).map { i in
            let from = FolderPreviewLayout.miniCenter(index: i, folderCenter: sourceCenter, folderSize: 128, yIncreasesDown: true)
            let dest = metrics.iconCenter(globalIndex: Double(i), pageOffset: 0)
            return CGPoint(x: from.x + (dest.x - from.x) * 0.3, y: from.y + (dest.y - from.y) * 0.3)
        }
        var bestIndex: Int?
        var bestDist: CGFloat = .infinity
        for (i, c) in centers.enumerated() {
            let dist = hypot(app8Progress03.x - c.x, app8Progress03.y - c.y)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        XCTAssertEqual(bestIndex, 8, "Animated visual hit test must return item 8, never slot 0")
    }
}
