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

    func testTrackCoverSlicesLeaveOnlyTheCurrentNativeKnobGap() {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 34)
        let oldHole = NSRect(x: 190, y: 3, width: 24, height: 28)
        let newHole = NSRect(x: 211, y: 3, width: 24, height: 28)
        let geometry = QuotaTrackCoverGeometry.make(bounds: bounds, hole: newHole)

        XCTAssertEqual(geometry.hole, newHole)
        XCTAssertFalse(geometry.hidesRightSlice)
        XCTAssertFalse(geometry.leftFrame.contains(NSPoint(x: newHole.midX, y: bounds.midY)))
        XCTAssertFalse(geometry.rightFrame.contains(NSPoint(x: newHole.midX, y: bounds.midY)))
        XCTAssertTrue(
            geometry.leftFrame.contains(NSPoint(x: oldHole.midX, y: bounds.midY)) ||
                geometry.rightFrame.contains(NSPoint(x: oldHole.midX, y: bounds.midY))
        )

        let movedLeft = QuotaTrackCoverGeometry.make(bounds: bounds, hole: oldHole)
        XCTAssertTrue(
            movedLeft.leftFrame.contains(NSPoint(x: newHole.midX, y: bounds.midY)) ||
                movedLeft.rightFrame.contains(NSPoint(x: newHole.midX, y: bounds.midY))
        )

        let idle = QuotaTrackCoverGeometry.make(bounds: bounds, hole: nil)
        XCTAssertEqual(idle.leftFrame, bounds)
        XCTAssertTrue(idle.hidesRightSlice)
        XCTAssertNil(idle.hole)

        let resizedBounds = NSRect(x: 0, y: 0, width: 260, height: 34)
        let resized = QuotaTrackCoverGeometry.make(bounds: resizedBounds, hole: newHole)
        XCTAssertEqual(resized.leftFrame.maxX, resized.hole?.minX)
        XCTAssertEqual(resized.rightFrame.minX, resized.hole?.maxX)
        XCTAssertGreaterThanOrEqual(resized.leftFrame.minX, resizedBounds.minX)
        XCTAssertLessThanOrEqual(resized.rightFrame.maxX, resizedBounds.maxX)
    }

    func testContinuousColorTrackRemainsUnderEveryNativeKnob() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let cases: [(CGFloat, QuotaProgressColorConfiguration)] = [
            (620, .default),
            (420, .default.settingEnabled(.orange, to: false)),
            (
                260,
                .default
                    .settingEnabled(.red, to: false)
                    .settingEnabled(.orange, to: false)
            )
        ]

        for (width, configuration) in cases {
            let slider = QuotaColorThresholdSlider(configuration: configuration)
            slider.frame = NSRect(x: 20, y: 30, width: width, height: 34)
            window.contentView?.addSubview(slider)
            window.contentView?.layoutSubtreeIfNeeded()

            let colors = configuration.enabledColorsInOrder
            let segments = slider.debugRenderedColorTrackSegments
            XCTAssertEqual(segments.count, colors.count)
            let firstSegment = try XCTUnwrap(segments.first)
            let lastSegment = try XCTUnwrap(segments.last)
            XCTAssertEqual(firstSegment.frame.minX, slider.debugNativeTrackRect.minX, accuracy: 0.01)
            XCTAssertEqual(lastSegment.frame.maxX, slider.debugNativeTrackRect.maxX, accuracy: 0.01)
            XCTAssertTrue(slider.debugColorTrackSourceFrames.contains { $0 == slider.bounds })

            for (index, color) in colors.enumerated() {
                let segment = try XCTUnwrap(segments[safe: index])
                XCTAssertEqual(segment.color, color)
                XCTAssertEqual(segment.frame.minY, slider.debugNativeTrackRect.minY, accuracy: 0.01)
                XCTAssertEqual(segment.frame.height, slider.debugNativeTrackRect.height, accuracy: 0.01)
                if let boundary = slider.debugRenderedColorBoundaryCenters[color] {
                    XCTAssertEqual(segment.frame.maxX, boundary, accuracy: 0.01)
                    if index + 1 < segments.count {
                        XCTAssertEqual(segments[index + 1].frame.minX, boundary, accuracy: 0.01)
                    }
                }
            }

            for color in colors.dropLast() {
                slider.setTrackingColorForTesting(color)
                XCTAssertNotNil(slider.debugCurrentNativeKnobGap)
                XCTAssertTrue(slider.debugHasContinuousColorTrackUnderNativeKnob)
            }
            slider.setTrackingColorForTesting(nil)
            slider.removeFromSuperview()
        }
    }

    func testCustomColorTrackMatchesConvertedNativeBarRect() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        for (width, configuration) in [
            (260, QuotaProgressColorConfiguration.default),
            (420, QuotaProgressColorConfiguration.default.settingEnabled(.orange, to: false)),
            (
                620,
                QuotaProgressColorConfiguration.default
                    .settingEnabled(.red, to: false)
                    .settingEnabled(.orange, to: false)
            )
        ] {
            let slider = QuotaColorThresholdSlider(configuration: configuration)
            slider.frame = NSRect(x: 20, y: 40, width: CGFloat(width), height: 34)
            window.contentView?.addSubview(slider)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(slider.debugCustomColorTrackRect, slider.debugNativeTrackRect)
            XCTAssertEqual(slider.debugCustomColorTrackRect.height, slider.debugNativeTrackRect.height)
            slider.removeFromSuperview()
        }

        let nonSixPointBar = NSRect(x: 9, y: 4, width: 280, height: 4)
        XCTAssertEqual(
            QuotaThresholdTrackGeometry.customColorTrackRect(from: nonSixPointBar),
            nonSixPointBar
        )
    }

    func testThumbCountMatchesEnabledColorCount() {
        let all = QuotaColorThresholdSlider(configuration: .default)
        XCTAssertEqual(all.thumbCount, 3)
        XCTAssertEqual(all.nativeThumbSliders.count, 3)
        XCTAssertEqual(all.passiveKnobCount, 0)
        XCTAssertEqual(all.subviews.compactMap { $0 as? NSSlider }.count, 3)
        XCTAssertTrue(all.usesNSSliderThumbs)
        XCTAssertFalse(all.usesCustomSliderCell)
        XCTAssertTrue(all.nativeThumbSliders.allSatisfy { $0.cell is NSSliderCell })
        XCTAssertEqual(all.nativeSliderBoundaryColors, [.red, .orange, .yellow])
        XCTAssertEqual(all.thumbIdentitySet.count, 3)
        XCTAssertEqual(all.nativeSliderCellIdentityByColor.count, 3)
        XCTAssertEqual(Set(all.nativeSliderCellIdentityByColor.values).count, 3)
        let identities = all.thumbIdentitySet
        let cellIdentities = all.nativeSliderCellIdentityByColor
        all.configuration = .default.settingBoundary(after: .orange, to: 35)
        XCTAssertEqual(all.thumbIdentitySet, identities)
        XCTAssertEqual(all.nativeSliderCellIdentityByColor, cellIdentities)
        let three = QuotaProgressColorConfiguration.default.settingEnabled(.orange, to: false)
        let threeSlider = QuotaColorThresholdSlider(configuration: three)
        XCTAssertEqual(threeSlider.thumbCount, 2)
        XCTAssertEqual(threeSlider.nativeThumbSliders.count, 2)
        XCTAssertEqual(threeSlider.passiveKnobCount, 0)
        XCTAssertEqual(threeSlider.nativeSliderBoundaryColors, [.red, .yellow])
        let two = three.settingEnabled(.red, to: false)
        let twoSlider = QuotaColorThresholdSlider(configuration: two)
        XCTAssertEqual(twoSlider.thumbCount, 1)
        XCTAssertEqual(twoSlider.nativeThumbSliders.count, 1)
        XCTAssertEqual(twoSlider.passiveKnobCount, 0)
        XCTAssertEqual(twoSlider.nativeSliderBoundaryColors, [.yellow])
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
        XCTAssertEqual(slider.nativeThumbSliders.count, 3)
        XCTAssertEqual(slider.passiveKnobCount, 0)
        XCTAssertFalse(slider.usesCustomSliderCell)
        XCTAssertTrue(slider.nativeThumbSliders.allSatisfy { $0.cell is NSSliderCell })
        for state in initial {
            guard let index = slider.nativeSliderBoundaryColors.firstIndex(of: state.color) else {
                return XCTFail("Missing native slider for \(state.color)")
            }
            XCTAssertTrue(slider.hitTest(NSPoint(x: state.knobMidX, y: state.knobMidY)) === slider.nativeThumbSliders[index])
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

    func testFirstSnapKeepsPersistentSliderIdentityAndRenderedBoundaryInSync() throws {
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

        let identities = slider.nativeSliderIdentityByColor
        let cellIdentities = slider.nativeSliderCellIdentityByColor
        let beforeCenters = slider.debugRenderedColorBoundaryCenters
        let beforeSegments = slider.debugRenderedColorTrackSegments

        slider.setTrackingColorForTesting(.red)
        slider.applyRawThumbValueForTesting(12.6, after: .red)

        XCTAssertEqual(slider.configuration.redUpperBound, 15)
        XCTAssertEqual(slider.nativeSliderIdentityByColor, identities)
        XCTAssertEqual(slider.nativeSliderCellIdentityByColor, cellIdentities)
        XCTAssertEqual(slider.thumbIdentitySet.count, 3)

        let afterState = try XCTUnwrap(slider.debugThumbStates.first(where: { $0.color == .red }))
        let afterCenter = try XCTUnwrap(slider.debugRenderedColorBoundaryCenters[.red])
        XCTAssertEqual(afterCenter, afterState.knobMidX, accuracy: 0.01)
        let beforeRedCenter = try XCTUnwrap(beforeCenters[.red])
        let beforeOrangeCenter = try XCTUnwrap(beforeCenters[.orange])
        let beforeYellowCenter = try XCTUnwrap(beforeCenters[.yellow])
        let afterOrangeCenter = try XCTUnwrap(slider.debugRenderedColorBoundaryCenters[.orange])
        let afterYellowCenter = try XCTUnwrap(slider.debugRenderedColorBoundaryCenters[.yellow])
        XCTAssertNotEqual(afterCenter, beforeRedCenter)
        XCTAssertEqual(afterOrangeCenter, beforeOrangeCenter, accuracy: 0.01)
        XCTAssertEqual(afterYellowCenter, beforeYellowCenter, accuracy: 0.01)

        let afterSegments = slider.debugRenderedColorTrackSegments
        XCTAssertNotEqual(afterSegments, beforeSegments)
        XCTAssertTrue(afterSegments.contains { $0.color == .red && $0.frame.maxX <= afterCenter + 0.01 })
        XCTAssertFalse(afterSegments.contains { $0.color == .red && $0.frame.minX < afterCenter - 0.01 && $0.frame.maxX > afterCenter + 0.01 })
    }

    func testFirstSnapRenderStateStaysSynchronizedForEveryBoundary() throws {
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
        let identities = slider.nativeSliderIdentityByColor
        let cellIdentities = slider.nativeSliderCellIdentityByColor

        for (color, rawValue) in [
            (QuotaProgressColor.red, 12.6),
            (.orange, 32.6),
            (.yellow, 57.6)
        ] {
            let oldCenter = try XCTUnwrap(slider.debugRenderedColorBoundaryCenters[color])
            slider.setTrackingColorForTesting(color)
            slider.applyRawThumbValueForTesting(rawValue, after: color)

            let state = try XCTUnwrap(slider.debugThumbStates.first(where: { $0.color == color }))
            let renderedCenter = try XCTUnwrap(slider.debugRenderedColorBoundaryCenters[color])
            XCTAssertEqual(renderedCenter, state.knobMidX, accuracy: 0.01)
            XCTAssertNotEqual(renderedCenter, oldCenter)
            XCTAssertEqual(slider.nativeSliderIdentityByColor, identities)
            XCTAssertEqual(slider.nativeSliderCellIdentityByColor, cellIdentities)
            XCTAssertTrue(slider.debugRenderedColorTrackSegments.contains {
                $0.color == color && $0.frame.minY == slider.debugNativeTrackRect.minY &&
                    $0.frame.height == slider.debugNativeTrackRect.height
            })
        }
    }

    func testPersistentSliderIdentitySurvivesResizeAndEnabledColorReconciliation() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let slider = QuotaColorThresholdSlider(configuration: .default)
        slider.frame = NSRect(x: 20, y: 40, width: 620, height: 34)
        window.contentView?.addSubview(slider)
        window.contentView?.layoutSubtreeIfNeeded()
        let initialIDs = slider.nativeSliderIdentityByColor
        let initialCellIDs = slider.nativeSliderCellIdentityByColor

        slider.frame.size.width = 260
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(slider.nativeSliderIdentityByColor, initialIDs)
        XCTAssertEqual(slider.nativeSliderCellIdentityByColor, initialCellIDs)
        XCTAssertEqual(slider.nativeThumbSliders.count, 3)
        XCTAssertEqual(slider.debugCustomColorTrackRect, slider.debugNativeTrackRect)

        slider.configuration = slider.configuration.settingEnabled(.orange, to: false)
        XCTAssertEqual(slider.nativeThumbSliders.count, 2)
        XCTAssertEqual(slider.nativeSliderBoundaryColors, [.red, .yellow])
        XCTAssertEqual(slider.nativeSliderIdentityByColor[.red], initialIDs[.red])
        XCTAssertEqual(slider.nativeSliderIdentityByColor[.yellow], initialIDs[.yellow])
        XCTAssertEqual(slider.nativeSliderCellIdentityByColor[.red], initialCellIDs[.red])
        XCTAssertEqual(slider.nativeSliderCellIdentityByColor[.yellow], initialCellIDs[.yellow])

        slider.configuration = slider.configuration.settingEnabled(.orange, to: true)
        XCTAssertEqual(slider.nativeThumbSliders.count, 3)
        XCTAssertEqual(slider.nativeSliderIdentityByColor[.red], initialIDs[.red])
        XCTAssertEqual(slider.nativeSliderIdentityByColor[.yellow], initialIDs[.yellow])
        XCTAssertNotEqual(slider.nativeSliderIdentityByColor[.orange], initialIDs[.orange])
        XCTAssertEqual(slider.nativeSliderCellIdentityByColor[.red], initialCellIDs[.red])
        XCTAssertEqual(slider.nativeSliderCellIdentityByColor[.yellow], initialCellIDs[.yellow])
        XCTAssertNotEqual(slider.nativeSliderCellIdentityByColor[.orange], initialCellIDs[.orange])
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

    func testPersistentNativeSlidersRouteBoundaryHitsToExactChild() {
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
        XCTAssertEqual(slider.nativeThumbSliders.count, 3)
        XCTAssertEqual(slider.passiveKnobCount, 0)
        XCTAssertTrue(slider.nativeThumbSliders.allSatisfy { $0.acceptsFirstMouse(for: nil) })

        for state in slider.debugThumbStates {
            guard let index = slider.nativeSliderBoundaryColors.firstIndex(of: state.color) else {
                return XCTFail("Missing native slider for \(state.color)")
            }
            let hit = slider.hitTest(NSPoint(x: state.knobMidX, y: state.knobMidY))
            XCTAssertTrue(hit === slider.nativeThumbSliders[index])
        }

        let emptyTrackPoint = NSPoint(x: slider.bounds.maxX - 2, y: slider.bounds.midY)
        XCTAssertTrue(emptyTrackPoint.x > slider.debugThumbStates.last!.knobMidX)
        XCTAssertTrue(slider.hitTest(emptyTrackPoint) === slider.nativeThumbSliders.last)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
