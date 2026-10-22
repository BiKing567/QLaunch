import XCTest
@testable import QLaunchpadCore

final class IconSizeTierTests: XCTestCase {
    func testAllFiveTiersHaveExpectedPointSizes() {
        XCTAssertEqual(IconSizeTier.allCases.count, 5)
        XCTAssertEqual(IconSizeTier.extraSmall.pointSize, 64)
        XCTAssertEqual(IconSizeTier.small.pointSize, 96)
        XCTAssertEqual(IconSizeTier.medium.pointSize, 128)
        XCTAssertEqual(IconSizeTier.large.pointSize, 160)
        XCTAssertEqual(IconSizeTier.extraLarge.pointSize, 192)
    }

    func testDefaultTierIsMedium() {
        XCTAssertEqual(IconSizeTier.defaultTier, .medium)
        XCTAssertEqual(IconSizeTier.defaultTier.pointSize, 128)
    }

    func testSpacingScalesAreCohesive() {
        XCTAssertEqual(IconSizeTier.extraSmall.spacingScale, 0.70, accuracy: 0.001)
        XCTAssertEqual(IconSizeTier.small.spacingScale, 0.85, accuracy: 0.001)
        XCTAssertEqual(IconSizeTier.medium.spacingScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(IconSizeTier.large.spacingScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(IconSizeTier.extraLarge.spacingScale, 1.0, accuracy: 0.001)
    }

    func testMigrationFromLegacyPresets() {
        let defaults = UserDefaults.standard
        let originalPreset = defaults.string(forKey: LaunchpadPersistence.gridLayoutPresetKey)
        let originalTier = defaults.object(forKey: LaunchpadPersistence.iconSizeTierKey)
        defer {
            defaults.setValue(originalPreset, forKey: LaunchpadPersistence.gridLayoutPresetKey)
            defaults.setValue(originalTier, forKey: LaunchpadPersistence.iconSizeTierKey)
        }

        defaults.removeObject(forKey: LaunchpadPersistence.iconSizeTierKey)

        defaults.setValue("7x5-64", forKey: LaunchpadPersistence.gridLayoutPresetKey)
        XCTAssertEqual(IconSizeTier.current, .extraSmall)

        defaults.setValue("4x2-256", forKey: LaunchpadPersistence.gridLayoutPresetKey)
        XCTAssertEqual(IconSizeTier.current, .extraLarge)

        defaults.setValue("6x4-128", forKey: LaunchpadPersistence.gridLayoutPresetKey)
        XCTAssertEqual(IconSizeTier.current, .medium)
    }
}
