import AppKit
import XCTest
@testable import BalanceBar

final class QuotaProgressColorConfigurationTests: XCTestCase {
    func testDefaultPreservesExistingBoundarySemantics() {
        XCTAssertTrue(QuotaProgressView.progressColor(for: 9.99).isEqual(NSColor.systemRed))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 10).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 24.99).isEqual(NSColor.systemOrange))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 25).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50).isEqual(NSColor.systemYellow))
        XCTAssertTrue(QuotaProgressView.progressColor(for: 50.01).isEqual(NSColor.systemGreen))
    }

    func testPersistenceRoundTripAndNormalization() {
        let suite = "QuotaProgressColorConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["red"], forKey: AppPreferences.quotaProgressEnabledColorsKey)
        defaults.set(-12, forKey: AppPreferences.quotaProgressRedUpperBoundKey)
        defaults.set(27, forKey: AppPreferences.quotaProgressOrangeUpperBoundKey)
        defaults.set(108, forKey: AppPreferences.quotaProgressYellowUpperBoundKey)
        let configuration = AppPreferences(defaults: defaults).quotaProgressColorConfiguration
        XCTAssertEqual(configuration.enabledColors, Set(QuotaProgressColor.allCases))
        XCTAssertEqual([configuration.redUpperBound, configuration.orangeUpperBound, configuration.yellowUpperBound], [5, 25, 95])
        XCTAssertEqual(AppPreferences(defaults: defaults).quotaProgressColorConfiguration, configuration)
    }

    func testGetterDoesNotWriteNormalizedValues() {
        let suite = "QuotaProgressColorConfigurationTests.getter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["red"], forKey: AppPreferences.quotaProgressEnabledColorsKey)
        defaults.set(27, forKey: AppPreferences.quotaProgressOrangeUpperBoundKey)
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        _ = AppPreferences(defaults: defaults).quotaProgressColorConfiguration
        let after = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertTrue((before as NSDictionary).isEqual(to: after))
    }

    func testColorCountsDisableTakeoverAndHistoricalRestore() {
        let original = QuotaProgressColorConfiguration(enabledColors: Set(QuotaProgressColor.allCases), redUpperBound: 25, orangeUpperBound: 50, yellowUpperBound: 75).normalized()
        let three = original.settingEnabled(.orange, to: false)
        XCTAssertEqual(three.thumbCount, 2)
        XCTAssertEqual(three.orangeUpperBound, 50)
        XCTAssertTrue(QuotaProgressView.progressColor(for: 25, configuration: three).isEqual(NSColor.systemYellow))
        let two = three.settingEnabled(.red, to: false)
        XCTAssertEqual(two.thumbCount, 1)
        XCTAssertEqual(two.settingEnabled(.yellow, to: false).enabledColors.count, 2)
        XCTAssertEqual(three.settingEnabled(.orange, to: true), original)
    }

    func testMinimumGapSnapHapticAndAdaptiveTicks() {
        let configuration = QuotaProgressColorConfiguration.default.settingBoundary(after: .orange, to: 11)
        XCTAssertEqual(configuration.orangeUpperBound, 15)
        XCTAssertGreaterThanOrEqual(configuration.orangeUpperBound - configuration.redUpperBound, 5)
        XCTAssertEqual(QuotaThresholdSliderMath.snapped(12.6), 15)
        XCTAssertEqual(QuotaThresholdSliderMath.crossedTicks(from: 10, to: 25), [15, 20, 25])
        XCTAssertEqual(QuotaThresholdSliderMath.visibleTicks(width: 500, thumbValues: [15]).count, 21)
        XCTAssertTrue(QuotaThresholdSliderMath.visibleTicks(width: 180, thumbValues: [15]).contains(15))
        XCTAssertLessThan(QuotaThresholdSliderMath.visibleTicks(width: 180, thumbValues: [15]).count, 21)
        XCTAssertTrue(PreferencesMigrationPlan.allKeys.contains(AppPreferences.quotaProgressEnabledColorsKey))
    }

    func testNativeThumbCountMatchesEnabledColorCount() {
        let all = QuotaColorThresholdSlider(configuration: .default)
        XCTAssertEqual(all.thumbCount, 3)
        let identities = all.thumbIdentitySet
        all.configuration = .default.settingBoundary(after: .orange, to: 35)
        XCTAssertEqual(all.thumbIdentitySet, identities)
        let three = QuotaProgressColorConfiguration.default.settingEnabled(.orange, to: false)
        XCTAssertEqual(QuotaColorThresholdSlider(configuration: three).thumbCount, 2)
        let two = three.settingEnabled(.red, to: false)
        XCTAssertEqual(QuotaColorThresholdSlider(configuration: two).thumbCount, 1)
    }
}
