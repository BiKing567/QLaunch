import CoreGraphics
import Foundation

/// Five-tier icon size scale for QLaunchpad.
public enum IconSizeTier: Int, CaseIterable, Identifiable, Sendable {
    case extraSmall = 1
    case small = 2
    case medium = 3
    case large = 4
    case extraLarge = 5

    public static let defaultsKey = LaunchpadPersistence.iconSizeTierKey
    public static let defaultTier: Self = .medium

    public var id: Int { rawValue }

    /// Base icon point size corresponding to each tier.
    public var pointSize: CGFloat {
        switch self {
        case .extraSmall: 64
        case .small: 96
        case .medium: 128
        case .large: 160
        case .extraLarge: 192
        }
    }

    /// Spacing factor for grid padding to keep compact tiers visually cohesive.
    public var spacingScale: CGFloat {
        switch self {
        case .extraSmall: 0.70
        case .small: 0.85
        case .medium, .large, .extraLarge: 1.0
        }
    }

    /// Read the active icon size tier with fallback / migration support.
    public static var current: Self {
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        if stored >= 1 && stored <= 5, let tier = Self(rawValue: stored) {
            return tier
        }
        // Backward compatibility migration based on legacy preset names
        if let rawPreset = UserDefaults.standard.string(forKey: LaunchpadPersistence.gridLayoutPresetKey) {
            if rawPreset.hasSuffix("-64") {
                return .extraSmall
            } else if rawPreset.hasSuffix("-256") {
                return .extraLarge
            }
        }
        return defaultTier
    }
}
