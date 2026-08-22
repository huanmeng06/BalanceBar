import AppKit
import XCTest
@testable import BalanceBar

final class MenuBarGeometryTests: XCTestCase {
    func testSingleLineBalanceWithIconUsesFixedHeightAndExpectedWidth() {
        let geometry = makeGeometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )

        XCTAssertEqual(geometry.iconWidth, 16)
        XCTAssertEqual(geometry.gap, 4)
        XCTAssertEqual(geometry.textWidth, 46)
        XCTAssertEqual(geometry.textHeight, 14)
        XCTAssertEqual(geometry.contentWidth, 66)
        XCTAssertEqual(geometry.contentHeight, 18)
    }

    func testTwoLineAmountWithoutIconUsesTallestTextWidthAndRowSpacing() {
        let geometry = makeGeometry(
            primarySize: NSSize(width: 31.1, height: 11.2),
            secondarySize: NSSize(width: 47.3, height: 9.1),
            showIcon: false,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )

        XCTAssertEqual(geometry.iconWidth, 0)
        XCTAssertEqual(geometry.gap, 0)
        XCTAssertEqual(geometry.textWidth, 50)
        XCTAssertEqual(geometry.primaryHeight, 12)
        XCTAssertEqual(geometry.secondaryHeight, 10)
        XCTAssertEqual(geometry.textHeight, 24)
        XCTAssertEqual(geometry.contentWidth, 50)
        XCTAssertEqual(geometry.contentHeight, 24)
    }

    func testIconOnlyGeometryHasNoTextOrGap() {
        let geometry = makeGeometry(
            primarySize: NSSize(width: 60, height: 14),
            secondarySize: NSSize(width: 70, height: 12),
            showIcon: true,
            showAmount: false,
            hasSecondary: false,
            isBalance: false
        )

        XCTAssertEqual(geometry.iconWidth, 16)
        XCTAssertEqual(geometry.gap, 0)
        XCTAssertEqual(geometry.textWidth, 0)
        XCTAssertEqual(geometry.textHeight, 0)
        XCTAssertEqual(geometry.contentWidth, 16)
        XCTAssertEqual(geometry.contentHeight, 16)
    }

    func testMenuBarLayoutCoversAllVisibleComponentCombinations() {
        let cases: [(String, Bool, Bool, Bool, Bool, CGFloat, CGFloat, CGFloat)] = [
            ("empty", false, false, false, false, 0, 0, 0),
            ("icon-only", true, false, false, false, 18, 18, 18),
            ("amount-only", false, true, false, true, 0, 80, 18),
            ("balance", true, true, false, true, 18, 104, 18),
            ("official-text-only", false, true, true, false, 0, 80, 22),
            ("official", true, true, true, false, 18, 104, 22),
        ]

        for (name, showIcon, showAmount, hasSecondary, isBalance, iconWidth, contentWidth, contentHeight) in cases {
            let geometry = MenuBarLayout.geometry(
                primarySize: NSSize(width: 74.2, height: 13.1),
                secondarySize: NSSize(width: 44.3, height: 9.1),
                showIcon: showIcon,
                showAmount: showAmount,
                hasSecondary: hasSecondary,
                isBalance: isBalance
            )

            XCTAssertEqual(geometry.iconWidth, iconWidth, accuracy: 0.001, "\(name) icon width")
            XCTAssertEqual(geometry.contentWidth, contentWidth, accuracy: 0.001, "\(name) content width")
            XCTAssertEqual(geometry.contentHeight, contentHeight, accuracy: 0.001, "\(name) content height")
        }
    }

    func testMenuBarFramesUseGeometryForContentIconAndText() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )

        let frames = MenuBarLayout.frames(
            buttonSize: NSSize(width: 100, height: 24),
            geometry: geometry,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )

        XCTAssertEqual(frames.content, NSRect(x: 13, y: 3, width: 73, height: 18))
        XCTAssertEqual(frames.iconSlot, NSRect(x: 0, y: 0, width: 18, height: 18))
        XCTAssertEqual(frames.icon, NSRect(x: 0, y: 0.25, width: 18, height: 18))
        XCTAssertEqual(frames.text, NSRect(x: 24, y: 2, width: 49, height: 14))
    }

    func testMenuBarFramesApplyIconAndTextOffsets() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )
        let base = MenuBarLayout.frames(
            buttonSize: NSSize(width: 100, height: 24),
            geometry: geometry,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )
        let offset = MenuBarLayout.frames(
            buttonSize: NSSize(width: 100, height: 24),
            geometry: geometry,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset,
            iconOffset: NSSize(width: 2, height: 3),
            textOffset: NSSize(width: -1, height: 4)
        )

        XCTAssertEqual(offset.content, base.content)
        XCTAssertEqual(offset.iconSlot, base.iconSlot)
        XCTAssertEqual(offset.icon, NSRect(
            x: base.icon.minX + 2,
            y: base.icon.minY + 3,
            width: base.icon.width,
            height: base.icon.height
        ))
        XCTAssertEqual(offset.text, NSRect(
            x: base.text.minX - 1,
            y: base.text.minY - 4,
            width: base.text.width,
            height: base.text.height
        ))
    }

    func testHorizontalCenteringCompensationKeepsDefaultAndExplicitOffsetsDistinct() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )
        let backgroundBounds = NSRect(x: 10, y: 2, width: 120, height: 24)
        let baseFrames = MenuBarLayout.frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )
        let baseBounds = try! XCTUnwrap(
            MenuBarLayout.visibleContentBounds(
                for: baseFrames,
                in: backgroundBounds
            )
        )

        XCTAssertEqual(
            MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: 0,
                textOffsetX: 0
            ),
            0,
            accuracy: 0.001
        )

        for (iconOffsetX, textOffsetX) in [
            (-2.0, 0.0),
            (2.0, 0.0),
            (0.0, -3.0),
            (0.0, 3.0),
            (-2.0, 3.0),
            (2.0, -3.0)
        ] {
            let compensation = MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: iconOffsetX,
                textOffsetX: textOffsetX
            )
            let adjustedFrames = MenuBarLayout.frames(
                buttonSize: backgroundBounds.size,
                geometry: geometry,
                iconViewYOffset: MenuBarLayout.singleLineIconYOffset,
                iconOffset: NSSize(width: iconOffsetX, height: 0),
                textOffset: NSSize(width: textOffsetX, height: 0)
            )
            let centeredFrames = MenuBarLayoutFrames(
                content: adjustedFrames.content.offsetBy(dx: compensation, dy: 0),
                iconSlot: adjustedFrames.iconSlot,
                icon: adjustedFrames.icon,
                text: adjustedFrames.text
            )
            let centeredBounds = try! XCTUnwrap(
                MenuBarLayout.visibleContentBounds(
                    for: centeredFrames,
                    in: backgroundBounds
                )
            )

            XCTAssertEqual(
                centeredBounds.midX,
                baseBounds.midX,
                accuracy: 0.001,
                "icon=\(iconOffsetX), amount=\(textOffsetX)"
            )
            XCTAssertEqual(
                (adjustedFrames.icon.minX - adjustedFrames.text.minX)
                    - (baseFrames.icon.minX - baseFrames.text.minX),
                iconOffsetX - textOffsetX,
                accuracy: 0.001,
                "explicit offsets must remain relative after compensation"
            )
        }
    }

    func testHorizontalCenteringUsesActualBackgroundWidthAndVisibleComponentSizes() {
        let geometries = [
            MenuBarLayout.geometry(
                primarySize: NSSize(width: 24, height: 13),
                secondarySize: .zero,
                showIcon: true,
                showAmount: true,
                hasSecondary: false,
                isBalance: true
            ),
            MenuBarLayout.geometry(
                primarySize: NSSize(width: 78, height: 13),
                secondarySize: NSSize(width: 35, height: 9),
                showIcon: true,
                showAmount: true,
                hasSecondary: true,
                isBalance: false
            ),
            MenuBarLayout.geometry(
                primarySize: NSSize(width: 40, height: 13),
                secondarySize: .zero,
                showIcon: false,
                showAmount: true,
                hasSecondary: false,
                isBalance: true
            ),
            MenuBarLayout.geometry(
                primarySize: .zero,
                secondarySize: .zero,
                showIcon: true,
                showAmount: false,
                hasSecondary: false,
                isBalance: false
            )
        ]

        for geometry in geometries {
            let backgroundBounds = NSRect(
                x: 17,
                y: 4,
                width: max(80, geometry.contentWidth + 42),
                height: 24
            )
            let baseFrames = MenuBarLayout.frames(
                buttonSize: backgroundBounds.size,
                geometry: geometry,
                iconViewYOffset: 0
            )
            guard let baseBounds = MenuBarLayout.visibleContentBounds(
                for: baseFrames,
                in: backgroundBounds
            ) else {
                XCTFail("Expected visible content for geometry \(geometry)")
                continue
            }
            let compensation = MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: -4,
                textOffsetX: 5
            )
            let adjustedFrames = MenuBarLayout.frames(
                buttonSize: backgroundBounds.size,
                geometry: geometry,
                iconViewYOffset: 0,
                iconOffset: NSSize(width: -4, height: 0),
                textOffset: NSSize(width: 5, height: 0)
            )
            let centeredFrames = MenuBarLayoutFrames(
                content: adjustedFrames.content.offsetBy(dx: compensation, dy: 0),
                iconSlot: adjustedFrames.iconSlot,
                icon: adjustedFrames.icon,
                text: adjustedFrames.text
            )
            let centeredBounds = try! XCTUnwrap(
                MenuBarLayout.visibleContentBounds(
                    for: centeredFrames,
                    in: backgroundBounds
                )
            )

            if geometry.iconWidth > 0, geometry.textWidth > 0 {
                XCTAssertEqual(centeredBounds.midX, baseBounds.midX, accuracy: 0.001)
            } else {
                // A single visible component has no two-part group to
                // recenter; its explicit offset remains absolute.
                XCTAssertNotEqual(centeredBounds.midX, baseBounds.midX, accuracy: 0.001)
            }
            XCTAssertGreaterThan(centeredBounds.width, 0)
            XCTAssertLessThanOrEqual(centeredBounds.minX, backgroundBounds.maxX)
            XCTAssertGreaterThanOrEqual(centeredBounds.maxX, backgroundBounds.minX)
        }
    }

    func testOfficialTextDefaultOffsetsFollowResetVisibility() {
        XCTAssertEqual(
            MenuBarLayout.officialTextYOffset(hasSecondary: false),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuBarLayout.officialTextYOffset(hasSecondary: true),
            -0.1,
            accuracy: 0.001
        )
    }

    func testOfficialBaselineMovesRealTextFramesUpAndDown() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: NSSize(width: 44.3, height: 9.1),
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let base = MenuBarLayout.frames(
            buttonSize: NSSize(width: 100, height: 24),
            geometry: geometry,
            iconViewYOffset: 0
        )
        let percentageOnly = MenuBarLayout.frames(
            buttonSize: NSSize(width: 100, height: 24),
            geometry: geometry,
            iconViewYOffset: 0,
            textOffset: NSSize(
                width: 0,
                height: MenuBarLayout.officialAmountOnlyTextYOffset
            )
        )
        let withReset = MenuBarLayout.frames(
            buttonSize: NSSize(width: 100, height: 24),
            geometry: geometry,
            iconViewYOffset: 0,
            textOffset: NSSize(
                width: 0,
                height: MenuBarLayout.officialSecondaryTextYOffset
            )
        )

        XCTAssertEqual(percentageOnly.text.minY, base.text.minY - 0.5, accuracy: 0.001)
        XCTAssertEqual(withReset.text.minY, base.text.minY + 0.1, accuracy: 0.001)
    }

    func testMenuBarOffsetDirectionsMatchRealAndPreview() {
        // Layouts: balance single-line, official one-line (percentage only),
        // official two-line (with reset time).
        let layouts: [(String, Bool, Bool)] = [
            ("balance", false, true),
            ("official-one-line", false, false),
            ("official-two-line", true, false)
        ]
        // Spaces used for the user-offset component on each side. The amount
        // preview Y uses unflipped layer semantics so "up" matches the real
        // menu bar; built-in baselines keep their existing visual unchanged.
        let elements: [(String, MenuBarOffsetSpace, MenuBarOffsetSpace)] = [
            ("icon", .unflippedFrame, .unflippedLayer),
            ("amount", .flippedFrame, .unflippedLayer)
        ]
        let directions: [(String, CGFloat, CGFloat)] = [
            ("up", 0, 1),
            ("down", 0, -1),
            ("left", -1, 0),
            ("right", 1, 0)
        ]

        for (layoutName, _, _) in layouts {
            for (elementName, realSpace, previewSpace) in elements {
                for (directionName, dx, dy) in directions {
                    let realDX = MenuBarOffsetLayout.xDelta(visualX: dx)
                    let realDY = MenuBarOffsetLayout.yDelta(
                        visualY: dy,
                        in: realSpace
                    )
                    let previewDX = MenuBarOffsetLayout.xDelta(visualX: dx)
                    let previewDY = MenuBarOffsetLayout.yDelta(
                        visualY: dy,
                        in: previewSpace
                    )

                    XCTAssertEqual(
                        MenuBarOffsetLayout.visualY(
                            forYDelta: realDY,
                            in: realSpace
                        ),
                        dy,
                        accuracy: 0.001,
                        "\(layoutName)/\(elementName)/\(directionName) real visual y"
                    )
                    XCTAssertEqual(
                        MenuBarOffsetLayout.visualY(
                            forYDelta: previewDY,
                            in: previewSpace
                        ),
                        dy,
                        accuracy: 0.001,
                        "\(layoutName)/\(elementName)/\(directionName) preview visual y"
                    )
                    XCTAssertEqual(realDX, previewDX, accuracy: 0.001)
                    XCTAssertEqual(realDX, dx, accuracy: 0.001)
                }
            }
        }
    }

    func testOfficialIconCenterRemainsAlignedToAPIReference() {
        let primarySize = NSSize(width: 43.2, height: 13.1)
        let secondarySize = NSSize(width: 44.3, height: 9.1)
        let buttonHeight: CGFloat = 24
        let apiGeometry = MenuBarLayout.geometry(
            primarySize: primarySize,
            secondarySize: secondarySize,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )
        let officialGeometry = MenuBarLayout.geometry(
            primarySize: primarySize,
            secondarySize: secondarySize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )

        let iconYOffset = officialGeometry.iconViewYOffset(
            alignedTo: apiGeometry,
            buttonHeight: buttonHeight,
            referenceIconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )
        let officialCenter = officialGeometry.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: iconYOffset
        )
        let apiCenter = apiGeometry.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )

        XCTAssertEqual(iconYOffset, 0.25, accuracy: 0.001)
        XCTAssertEqual(officialCenter, apiCenter, accuracy: 0.001)
        XCTAssertEqual(apiCenter, 11.75, accuracy: 0.001)
    }

    func testPassthroughViewsDoNotCaptureHitTests() {
        XCTAssertNil(PassthroughTextField(labelWithString: "text").hitTest(.zero))
        XCTAssertNil(PassthroughImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16)).hitTest(.zero))
        XCTAssertNil(PassthroughView(frame: NSRect(x: 0, y: 0, width: 16, height: 16)).hitTest(.zero))
    }

    func testAnimationStateAdvancesAndResetsWithoutRunLoop() {
        var state = MenuBarAnimationState()

        XCTAssertEqual(state.advance(frameCount: 3), 1)
        XCTAssertEqual(state.advance(frameCount: 3), 2)
        XCTAssertEqual(state.advance(frameCount: 3), 0)
        XCTAssertEqual(state.advance(frameCount: 0), nil)
        XCTAssertEqual(state.frameIndex, 0)
    }

    private func makeGeometry(
        primarySize: NSSize,
        secondarySize: NSSize,
        showIcon: Bool,
        showAmount: Bool,
        hasSecondary: Bool,
        isBalance: Bool
    ) -> MenuBarGeometry {
        MenuBarGeometry(
            primarySize: primarySize,
            secondarySize: secondarySize,
            showIcon: showIcon,
            showAmount: showAmount,
            hasSecondary: hasSecondary,
            isBalance: isBalance,
            iconSlotWidth: 16,
            iconTextSpacing: 4,
            textRowSpacing: 2,
            textWidthSlack: 2,
            singleLineHeight: 18
        )
    }
}
