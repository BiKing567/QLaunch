import CoreGraphics
import Foundation

/// Geometry and layout calculations for an opened folder modal card.
///
/// Instead of spreading folder apps across the full screen, the opened folder
/// is presented as an enclosed, centered frosted-glass card with dynamic height
/// that adapts to the number of rows needed by its contents.
public struct FolderCardMetrics: Equatable, Sendable {
    public let boundsSize: CGSize
    public let safeInsets: LaunchpadSafeInsets
    public let itemCount: Int

    public let columns: Int
    public let maxRows: Int
    public let rows: Int
    public let pageCapacity: Int

    public let iconSize: CGFloat
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat

    public let cardRect: CGRect
    public let contentRect: CGRect
    public let titleRect: CGRect
    public let cardCornerRadius: CGFloat

    public init(
        boundsSize: CGSize,
        safeInsets: LaunchpadSafeInsets = .zero,
        itemCount: Int,
        targetColumns: Int = 7,
        maxVisibleRows: Int = 4,
        iconSize: CGFloat = 128
    ) {
        self.boundsSize = boundsSize
        self.safeInsets = safeInsets
        self.itemCount = max(itemCount, 0)
        self.iconSize = iconSize

        self.columns = max(1, min(targetColumns, 7))
        self.maxRows = max(1, min(maxVisibleRows, 4))
        self.pageCapacity = max(1, self.columns * self.maxRows)

        let firstPageItems = min(self.itemCount, self.pageCapacity)
        self.rows = max(1, min(Int(ceil(Double(firstPageItems) / Double(self.columns))), self.maxRows))

        self.cellWidth = self.iconSize + 32
        self.cellHeight = self.iconSize + 40

        let headerHeight: CGFloat = 64
        let hPadding: CGFloat = 32
        let bottomPadding: CGFloat = 24

        let rawCardWidth = CGFloat(self.columns) * self.cellWidth + hPadding * 2
        let maxAllowedWidth = max(boundsSize.width - safeInsets.left - safeInsets.right - 48, 320)
        let cardWidth = min(rawCardWidth, maxAllowedWidth)

        let rawCardHeight = headerHeight + CGFloat(self.rows) * self.cellHeight + bottomPadding
        let maxAllowedHeight = max(boundsSize.height - safeInsets.top - safeInsets.bottom - 48, 200)
        let cardHeight = min(rawCardHeight, maxAllowedHeight)

        let cardX = (boundsSize.width - cardWidth) * 0.5
        let usableHeight = max(boundsSize.height - safeInsets.top - safeInsets.bottom, 1)
        let opticalY = safeInsets.top + (usableHeight - cardHeight) * 0.5 - 12
        let cardY = max(safeInsets.top + 20, opticalY)

        self.cardRect = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        self.cardCornerRadius = 32

        let contentWidth = CGFloat(self.columns) * self.cellWidth
        let contentLeft = cardX + (cardWidth - contentWidth) * 0.5
        self.contentRect = CGRect(
            x: contentLeft,
            y: cardY + headerHeight,
            width: contentWidth,
            height: CGFloat(self.rows) * self.cellHeight
        )

        let titleW = min(cardWidth - 80, 420)
        let titleH: CGFloat = 36
        self.titleRect = CGRect(
            x: (boundsSize.width - titleW) * 0.5,
            y: cardY + 16,
            width: titleW,
            height: titleH
        )
    }

    /// Center of an icon in top-left coordinates.
    public func iconCenter(localIndex: Int, page: Int, pageOffset: Double) -> CGPoint {
        let col = localIndex % columns
        let row = (localIndex / columns) % maxRows
        let pageShift = CGFloat(Double(page) - pageOffset) * cardRect.width
        return CGPoint(
            x: contentRect.minX + cellWidth * (CGFloat(col) + 0.5) + pageShift,
            y: contentRect.minY + cellHeight * (CGFloat(row) + 0.5)
        )
    }

    /// Continuous icon center for fractional global index (supports smooth reorder animation).
    public func iconCenter(globalIndex: Double, pageOffset: Double) -> CGPoint {
        let lowerIndex = max(0, Int(floor(globalIndex)))
        let upperIndex = max(lowerIndex, Int(ceil(globalIndex)))
        let fraction = CGFloat(globalIndex - floor(globalIndex))
        let lower = iconCenter(
            localIndex: lowerIndex % pageCapacity,
            page: lowerIndex / pageCapacity,
            pageOffset: pageOffset
        )
        let upper = iconCenter(
            localIndex: upperIndex % pageCapacity,
            page: upperIndex / pageCapacity,
            pageOffset: pageOffset
        )
        return CGPoint(
            x: lower.x + (upper.x - lower.x) * fraction,
            y: lower.y + (upper.y - lower.y) * fraction
        )
    }

    /// Label center below the app icon.
    public func labelCenter(localIndex: Int, page: Int, pageOffset: Double) -> CGPoint {
        let center = iconCenter(localIndex: localIndex, page: page, pageOffset: pageOffset)
        return CGPoint(x: center.x, y: center.y + iconSize * 0.5 + 6 + 10)
    }

    /// Hit-tests a point against icons on the current page.
    public func hitTest(point: CGPoint, pageOffset: Double, hitRadiusScale: CGFloat = 0.62) -> Int? {
        let radius = max(cellWidth, cellHeight) * 0.5 * hitRadiusScale
        let radiusSq = radius * radius
        for i in 0..<itemCount {
            let center = iconCenter(globalIndex: Double(i), pageOffset: pageOffset)
            let dx = point.x - center.x
            let dy = point.y - center.y
            if dx * dx + dy * dy <= radiusSq {
                return i
            }
        }
        return nil
    }

    /// Checks if a point falls inside the modal card.
    public func isPointInsideCard(_ point: CGPoint) -> Bool {
        cardRect.contains(point)
    }

    // MARK: - AppKit Coordinate Helpers (y = 0 at bottom)

    /// Converts an AppKit point (y = 0 at bottom) to top-left view coordinates.
    public func appKitToTopLeft(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: boundsSize.height - point.y)
    }

    /// Converts a top-left point to AppKit coordinates (y = 0 at bottom).
    public func topLeftToAppKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: boundsSize.height - point.y)
    }

    /// Card rectangle in AppKit coordinates (y = 0 at bottom).
    public var cardRectAppKit: CGRect {
        CGRect(
            x: cardRect.origin.x,
            y: boundsSize.height - cardRect.maxY,
            width: cardRect.width,
            height: cardRect.height
        )
    }

    /// Checks if an AppKit point (y = 0 at bottom) falls inside the modal card.
    public func isAppKitPointInsideCard(_ point: CGPoint) -> Bool {
        cardRectAppKit.contains(point)
    }

    /// Hit-tests an AppKit point (y = 0 at bottom) against icons on the current page.
    public func hitTestAppKit(point: CGPoint, pageOffset: Double, hitRadiusScale: CGFloat = 0.62) -> Int? {
        hitTest(point: appKitToTopLeft(point), pageOffset: pageOffset, hitRadiusScale: hitRadiusScale)
    }

    // MARK: - Page Indicator Geometry & Hit Testing

    public static let indicatorDotWidth: CGFloat = 5
    public static let indicatorActiveDotWidth: CGFloat = 15
    public static let indicatorDotHeight: CGFloat = 5
    public static let indicatorSpacing: CGFloat = 6
    public static let indicatorHorizontalPadding: CGFloat = 11
    public static let indicatorVerticalPadding: CGFloat = 7
    public static let indicatorHitSlopX: CGFloat = 28
    public static let indicatorHitSlopY: CGFloat = 24

    /// Center of the page indicator in top-left coordinates (flipped = true) or AppKit coordinates (flipped = false).
    public func pageIndicatorCenter(flipped: Bool = false) -> CGPoint {
        let yTop = cardRect.maxY - 14
        let y = flipped ? yTop : (boundsSize.height - yTop)
        return CGPoint(x: cardRect.midX, y: y)
    }

    public static func pageIndicatorVisualSize(pageCount: Int, currentPage: Int) -> CGSize {
        guard pageCount > 0 else { return .zero }
        var content: CGFloat = 0
        for index in 0..<pageCount {
            content += index == currentPage ? indicatorActiveDotWidth : indicatorDotWidth
            if index + 1 < pageCount { content += indicatorSpacing }
        }
        return CGSize(
            width: content + indicatorHorizontalPadding * 2,
            height: indicatorDotHeight + indicatorVerticalPadding * 2
        )
    }

    /// Visual rect of the card's page indicator.
    public func pageIndicatorVisualRect(pageCount: Int, currentPage: Int, flipped: Bool = false) -> CGRect {
        let size = Self.pageIndicatorVisualSize(pageCount: pageCount, currentPage: currentPage)
        let center = pageIndicatorCenter(flipped: flipped)
        return CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }

    /// Hit rect of the card's page indicator (visual rect expanded by hit slop).
    public func pageIndicatorHitRect(pageCount: Int, currentPage: Int, flipped: Bool = false) -> CGRect {
        pageIndicatorVisualRect(pageCount: pageCount, currentPage: currentPage, flipped: flipped)
            .insetBy(dx: -Self.indicatorHitSlopX, dy: -Self.indicatorHitSlopY)
    }

    /// Returns dot center X positions for each page.
    public func pageIndicatorDotCenters(pageCount: Int, currentPage: Int) -> [CGFloat] {
        let size = Self.pageIndicatorVisualSize(pageCount: pageCount, currentPage: currentPage)
        let visualLeft = cardRect.midX - size.width * 0.5
        var cursor = visualLeft + Self.indicatorHorizontalPadding
        var centers: [CGFloat] = []
        for page in 0..<pageCount {
            let width = page == currentPage ? Self.indicatorActiveDotWidth : Self.indicatorDotWidth
            centers.append(cursor + width * 0.5)
            cursor += width + Self.indicatorSpacing
        }
        return centers
    }

    /// Resolves which page index was clicked.
    public func pageIndicatorPageIndex(
        at point: CGPoint,
        pageCount: Int,
        currentPage: Int,
        requireHitPad: Bool = true,
        flipped: Bool = false
    ) -> Int? {
        guard pageCount > 1 else { return nil }
        if requireHitPad {
            let pad = pageIndicatorHitRect(pageCount: pageCount, currentPage: currentPage, flipped: flipped)
            guard pad.contains(point) else { return nil }
        }
        let centers = pageIndicatorDotCenters(pageCount: pageCount, currentPage: currentPage)
        guard !centers.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(center - point.x)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
