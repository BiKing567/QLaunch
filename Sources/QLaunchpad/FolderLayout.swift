import CoreGraphics
import Foundation
import QLaunchpadCore

extension FolderCardMetrics {
    init(
        boundsSize: CGSize,
        safeInsets: LaunchpadSafeInsets = .zero,
        itemCount: Int
    ) {
        let preset = GridLayoutPreset.current
        let rootMetrics = GridMetrics(size: boundsSize, safeInsets: safeInsets)
        self.init(
            boundsSize: boundsSize,
            safeInsets: safeInsets,
            itemCount: itemCount,
            targetColumns: preset.columns,
            maxVisibleRows: preset.rows,
            iconSize: rootMetrics.iconSize
        )
    }
}
