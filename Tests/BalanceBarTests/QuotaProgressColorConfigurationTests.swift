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
        XCTAssertTrue(QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: nil, newValue: 10))
        XCTAssertFalse(QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: 10, newValue: 10))
        XCTAssertTrue(QuotaThresholdSliderMath.shouldEmitAlignmentHaptic(lastSnappedValue: 10, newValue: 15))
        XCTAssertEqual(QuotaThresholdSliderMath.crossedTicks(from: 10, to: 25), [15, 20, 25])
        XCTAssertEqual(QuotaThresholdSliderMath.visibleTicks(width: 500, thumbValues: [15]).count, 21)
        XCTAssertTrue(QuotaThresholdSliderMath.visibleTicks(width: 180, thumbValues: [15]).contains(15))
        XCTAssertLessThan(QuotaThresholdSliderMath.visibleTicks(width: 180, thumbValues: [15]).count, 21)
        XCTAssertTrue(PreferencesMigrationPlan.allKeys.contains(AppPreferences.quotaProgressEnabledColorsKey))
    }

    func testThumbCountMatchesEnabledColorCount() {
        let all = QuotaColorThresholdSlider(configuration: .default)
        XCTAssertEqual(all.thumbCount, 3)
        XCTAssertEqual(all.nativeThumbSliders.count, 1)
        XCTAssertEqual(all.passiveKnobCount, 3)
        XCTAssertEqual(all.subviews.compactMap { $0 as? NSSlider }.count, 1)
        XCTAssertTrue(all.usesNSSliderThumbs)
        XCTAssertFalse(all.usesCustomSliderCell)
        XCTAssertTrue(all.nativeThumbSliders.allSatisfy { $0.cell is NSSliderCell })
        let identities = all.thumbIdentitySet
        all.configuration = .default.settingBoundary(after: .orange, to: 35)
        XCTAssertEqual(all.thumbIdentitySet, identities)
        let three = QuotaProgressColorConfiguration.default.settingEnabled(.orange, to: false)
        let threeSlider = QuotaColorThresholdSlider(configuration: three)
        XCTAssertEqual(threeSlider.thumbCount, 2)
        XCTAssertEqual(threeSlider.nativeThumbSliders.count, 1)
        XCTAssertEqual(threeSlider.passiveKnobCount, 2)
        let two = three.settingEnabled(.red, to: false)
        let twoSlider = QuotaColorThresholdSlider(configuration: two)
        XCTAssertEqual(twoSlider.thumbCount, 1)
        XCTAssertEqual(twoSlider.nativeThumbSliders.count, 1)
        XCTAssertEqual(twoSlider.passiveKnobCount, 1)
    }

    func testThumbRangesValuesAndGeometrySurviveUpdates() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let slider = QuotaColorThresholdSlider(configuration: .default)
        slider.frame = NSRect(x: 20, y: 30, width: 420, height: 34)
        window.contentView?.addSubview(slider)
        window.contentView?.layoutSubtreeIfNeeded()

        let initial = slider.debugThumbStates
        XCTAssertEqual(initial.map(\.color), [.red, .orange, .yellow])
        XCTAssertEqual(initial.map(\.minimumValue), [0, 0, 0])
        XCTAssertEqual(initial.map(\.maximumValue), [100, 100, 100])
        XCTAssertEqual(initial.map(\.value), [10, 25, 50])
        XCTAssertEqual(initial.map(\.knobMidX), initial.map(\.knobMidX).sorted())
        XCTAssertTrue(slider.usesNSSliderThumbs)
        XCTAssertEqual(slider.nativeThumbSliders.count, 1)
        XCTAssertEqual(slider.passiveKnobCount, 3)
        XCTAssertFalse(slider.usesCustomSliderCell)
        XCTAssertTrue(slider.nativeThumbSliders.allSatisfy { $0.cell is NSSliderCell })
        for state in initial {
            XCTAssertTrue(slider.hitTest(NSPoint(x: state.knobMidX, y: state.knobMidY)) is NSSlider)
        }

        slider.configuration = .default.settingBoundary(after: .red, to: 15)
        let moved = slider.debugThumbStates
        XCTAssertNotEqual(moved[0].knobMidX, initial[0].knobMidX)
        XCTAssertEqual(moved[1].knobMidX, initial[1].knobMidX, accuracy: 0.01)
        XCTAssertEqual(moved[2].knobMidX, initial[2].knobMidX, accuracy: 0.01)
        XCTAssertEqual(moved.map(\.minimumValue), [0, 0, 0])
        XCTAssertEqual(moved.map(\.maximumValue), [100, 100, 100])

        slider.applyRawThumbValueForTesting(12.6, after: .red)
        XCTAssertEqual(slider.configuration.redUpperBound, 15)
        XCTAssertEqual(slider.debugThumbStates.first?.value, 15)

        let identities = slider.thumbIdentitySet
        slider.configuration = slider.configuration
        XCTAssertEqual(slider.thumbIdentitySet, identities)
        XCTAssertEqual(slider.debugThumbStates.map(\.minimumValue), [0, 0, 0])
        XCTAssertEqual(slider.debugThumbStates.map(\.maximumValue), [100, 100, 100])

        slider.configuration = slider.configuration.settingEnabled(.orange, to: false)
        slider.configuration = slider.configuration.settingEnabled(.orange, to: true)
        XCTAssertEqual(slider.debugThumbStates.map(\.minimumValue), [0, 0, 0])
        XCTAssertEqual(slider.debugThumbStates.map(\.maximumValue), [100, 100, 100])
    }

    func testResetButtonUsesNativeSmallBezelStyle() {
        let button = NSButton()
        DashboardMenuPage.configureQuotaColorResetButton(button)
        XCTAssertEqual(button.controlSize, .small)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(button.bezelStyle, .glass)
        } else {
            XCTAssertEqual(button.bezelStyle, .rounded)
        }
    }

    func testSingleNativeInteractionSliderReceivesAllTrackHits() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let slider = QuotaColorThresholdSlider(configuration: .default)
        slider.frame = NSRect(x: 20, y: 30, width: 420, height: 34)
        window.contentView?.addSubview(slider)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(slider.acceptsFirstMouse(for: nil))
        XCTAssertEqual(slider.nativeThumbSliders.count, 1)
        XCTAssertEqual(slider.passiveKnobCount, 3)
        XCTAssertTrue(slider.nativeThumbSliders.allSatisfy { $0.acceptsFirstMouse(for: nil) })

        for state in slider.debugThumbStates {
            let hit = slider.hitTest(NSPoint(x: state.knobMidX, y: state.knobMidY))
            XCTAssertTrue(hit is NSSlider)
            XCTAssertFalse(hit === slider)
        }

        let emptyTrackPoint = NSPoint(x: slider.bounds.maxX - 2, y: slider.bounds.midY)
        XCTAssertTrue(slider.hitTest(emptyTrackPoint) is NSSlider)
    }
}
