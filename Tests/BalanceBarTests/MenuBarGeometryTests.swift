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

    func testSingleLineBalanceExpandsForLargePrimaryFontWithoutClipping() {
        let primary = NSTextField(labelWithString: "USD 123,456.78")
        primary.font = MenuBarLayout.primaryFont(size: 16)
        let geometry = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )

        XCTAssertGreaterThanOrEqual(geometry.contentHeight, geometry.textHeight)
        XCTAssertGreaterThanOrEqual(geometry.contentHeight, MenuBarLayout.singleLineHeight)
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

    func testMenuBarFontFactoriesUseLogicalAppKitPointSizes() {
        let primary = MenuBarLayout.primaryFont(size: 14.2)
        let secondary = MenuBarLayout.secondaryFont(size: 9.6)

        XCTAssertEqual(primary.pointSize, 14.2, accuracy: 0.001)
        XCTAssertEqual(secondary.pointSize, 9.6, accuracy: 0.001)
        XCTAssertEqual(MenuBarLayout.primaryFont.pointSize, 13, accuracy: 0.001)
        XCTAssertEqual(MenuBarLayout.secondaryFont.pointSize, 10, accuracy: 0.001)
    }

    func testActualFontMetricsKeepOfficialRowsLeftAlignedAndCentered() {
        let primary = NSTextField(labelWithString: "100% remaining")
        primary.font = MenuBarLayout.primaryFont(size: 14.2)
        let secondary = NSTextField(labelWithString: "Reset in 99h 23m")
        secondary.font = MenuBarLayout.secondaryFont(size: 9.6)
        let geometry = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: false,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let container = MenuBarTextView()

        MenuBarLayout.applyTextLayout(
            container: container,
            primary: primary,
            secondary: secondary,
            geometry: geometry,
            showAmount: true,
            hasSecondary: true
        )

        XCTAssertEqual(primary.frame.minX, secondary.frame.minX, accuracy: 0.001)
        XCTAssertEqual(primary.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(secondary.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(
            geometry.textWidth,
            ceil(max(primary.intrinsicContentSize.width, secondary.intrinsicContentSize.width))
                + MenuBarLayout.textWidthSlack,
            accuracy: 0.001
        )
        XCTAssertEqual(primary.frame.width, secondary.frame.width, accuracy: 0.001)

        let backgroundBounds = NSRect(x: 0, y: 0, width: 220, height: 42)
        let frames = MenuBarLayout.frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0
        )
        let measuredBounds = try! XCTUnwrap(
            MenuBarLayout.visibleTextBounds(
                for: frames,
                geometry: geometry,
                in: backgroundBounds
            )
        )
        let compensation = MenuBarLayout.horizontalCenteringCompensation(
            backgroundBounds: backgroundBounds,
            geometry: geometry,
            iconOffsetX: 0,
            textOffsetX: 0,
            centerTextBlock: true
        )
        let centeredFrames = MenuBarLayoutFrames(
            content: frames.content.offsetBy(dx: compensation, dy: 0),
            iconSlot: frames.iconSlot,
            icon: frames.icon,
            text: frames.text
        )
        let centeredTextBounds = try! XCTUnwrap(
            MenuBarLayout.visibleTextBounds(
                for: centeredFrames,
                geometry: geometry,
                in: backgroundBounds
            )
        )

        XCTAssertEqual(
            measuredBounds.width,
            geometry.measuredTextWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            centeredTextBounds.midX,
            backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
            accuracy: 0.001
        )
    }

    func testOfficialTwoLineTextBlockCentersAndReservesLeadingIcon() {
        let primary = NSTextField(labelWithString: "87%")
        primary.font = MenuBarLayout.primaryFont(size: 13)
        let secondary = NSTextField(labelWithString: "6d12h")
        secondary.font = MenuBarLayout.secondaryFont(size: 10)
        let geometry = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let leadingReserve = MenuBarLayout.textCenteringLeadingReserve(for: geometry)
        let backgroundBounds = NSRect(
            x: 0,
            y: 0,
            width: MenuBarLayout.statusItemLength(
                contentWidth: geometry.contentWidth,
                horizontalPadding: 10,
                widthAdjustment: -20,
                leadingContentReserve: leadingReserve
            ),
            height: 42
        )
        let baseFrames = MenuBarLayout.frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0
        )
        let adjustedFrames = MenuBarLayout.frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0,
            iconOffset: NSSize(width: 1.5, height: 0),
            textOffset: NSSize(width: -2.5, height: 0)
        )
        let compensation = MenuBarLayout.horizontalCenteringCompensation(
            backgroundBounds: backgroundBounds,
            geometry: geometry,
            iconOffsetX: 1.5,
            textOffsetX: -2.5,
            centerTextBlock: true
        )
        let centeredFrames = MenuBarLayoutFrames(
            content: adjustedFrames.content.offsetBy(dx: compensation, dy: 0),
            iconSlot: adjustedFrames.iconSlot,
            icon: adjustedFrames.icon,
            text: adjustedFrames.text
        )
        let centeredTextBounds = try! XCTUnwrap(
            MenuBarLayout.visibleTextBounds(
                for: centeredFrames,
                geometry: geometry,
                in: backgroundBounds
            )
        )
        let centeredIconBounds = adjustedFrames.icon.offsetBy(
            dx: adjustedFrames.content.minX + compensation,
            dy: adjustedFrames.content.minY
        )

        XCTAssertEqual(
            centeredTextBounds.midX,
            backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(centeredIconBounds.minX, backgroundBounds.minX)
        XCTAssertLessThanOrEqual(centeredIconBounds.maxX, backgroundBounds.maxX)
        XCTAssertGreaterThanOrEqual(centeredTextBounds.minX, backgroundBounds.minX)
        XCTAssertLessThanOrEqual(centeredTextBounds.maxX, backgroundBounds.maxX)
        XCTAssertEqual(
            (adjustedFrames.text.minX - adjustedFrames.icon.minX)
                - (baseFrames.text.minX - baseFrames.icon.minX),
            -2.5 - 1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(leadingReserve, geometry.iconWidth + geometry.gap, accuracy: 0.001)
        XCTAssertEqual(backgroundBounds.width, geometry.contentWidth + leadingReserve, accuracy: 0.001)
    }

    func testOfficialTwoLineFontRangeStaysInsideCenteredCardAtWidthBaseline() {
        let primaryText = "100% remaining"
        let secondaryText = "Reset in 99h 23m"

        for primarySize in stride(
            from: AppPreferences.menuBarPrimaryFontSizeRange.lowerBound,
            through: AppPreferences.menuBarPrimaryFontSizeRange.upperBound,
            by: AppPreferences.menuBarFontSizeStep
        ) {
            for secondarySize in stride(
                from: AppPreferences.menuBarSecondaryFontSizeRange.lowerBound,
                through: AppPreferences.menuBarSecondaryFontSizeRange.upperBound,
                by: AppPreferences.menuBarFontSizeStep
            ) {
                let primary = NSTextField(labelWithString: primaryText)
                primary.font = MenuBarLayout.primaryFont(size: CGFloat(primarySize))
                let secondary = NSTextField(labelWithString: secondaryText)
                secondary.font = MenuBarLayout.secondaryFont(size: CGFloat(secondarySize))
                let geometry = MenuBarLayout.geometry(
                    primarySize: primary.intrinsicContentSize,
                    secondarySize: secondary.intrinsicContentSize,
                    showIcon: true,
                    showAmount: true,
                    hasSecondary: true,
                    isBalance: false
                )
                let leadingReserve = MenuBarLayout.textCenteringLeadingReserve(for: geometry)
                let backgroundBounds = NSRect(
                    x: 0,
                    y: 0,
                    width: MenuBarLayout.statusItemLength(
                        contentWidth: geometry.contentWidth,
                        horizontalPadding: 10,
                        widthAdjustment: CGFloat(AppPreferences.menuBarStatusItemWidthBaseline),
                        leadingContentReserve: leadingReserve
                    ),
                    height: 42
                )
                let frames = MenuBarLayout.frames(
                    buttonSize: backgroundBounds.size,
                    geometry: geometry,
                    iconViewYOffset: 0
                )
                let compensation = MenuBarLayout.horizontalCenteringCompensation(
                    backgroundBounds: backgroundBounds,
                    geometry: geometry,
                    iconOffsetX: 0,
                    textOffsetX: 0,
                    centerTextBlock: true
                )
                let centeredFrames = MenuBarLayoutFrames(
                    content: frames.content.offsetBy(dx: compensation, dy: 0),
                    iconSlot: frames.iconSlot,
                    icon: frames.icon,
                    text: frames.text
                )
                let textBounds = try! XCTUnwrap(
                    MenuBarLayout.visibleTextBounds(
                        for: centeredFrames,
                        geometry: geometry,
                        in: backgroundBounds
                    )
                )
                let iconBounds = frames.icon.offsetBy(
                    dx: frames.content.minX + compensation,
                    dy: frames.content.minY
                )

                XCTAssertEqual(
                    textBounds.midX,
                    backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
                    accuracy: 0.001,
                    "primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertGreaterThanOrEqual(
                    iconBounds.minX,
                    backgroundBounds.minX - 0.001,
                    "icon left clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertLessThanOrEqual(
                    iconBounds.maxX,
                    backgroundBounds.maxX + 0.001,
                    "icon right clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertGreaterThanOrEqual(
                    textBounds.minX,
                    backgroundBounds.minX - 0.001,
                    "text left clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertLessThanOrEqual(
                    textBounds.maxX,
                    backgroundBounds.maxX + 0.001,
                    "text right clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
            }
        }
    }

    func testChangingOnlyOneFontSizeChangesItsMetricsWithoutChangingSharedRowOrigin() {
        let primary = NSTextField(labelWithString: "72%")
        let secondary = NSTextField(labelWithString: "Reset 2h")
        primary.font = MenuBarLayout.primaryFont(size: 13)
        secondary.font = MenuBarLayout.secondaryFont(size: 10)
        let baseline = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let baselinePrimaryWidth = primary.intrinsicContentSize.width
        let baselineSecondaryWidth = secondary.intrinsicContentSize.width

        primary.font = MenuBarLayout.primaryFont(size: 15)
        let enlargedPrimary = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        XCTAssertGreaterThan(enlargedPrimary.primaryHeight, baseline.primaryHeight)
        XCTAssertEqual(enlargedPrimary.secondaryHeight, baseline.secondaryHeight)
        XCTAssertGreaterThan(primary.intrinsicContentSize.width, baselinePrimaryWidth)

        primary.font = MenuBarLayout.primaryFont(size: 13)
        secondary.font = MenuBarLayout.secondaryFont(size: 12)
        let enlargedSecondary = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        XCTAssertEqual(enlargedSecondary.primaryHeight, baseline.primaryHeight)
        XCTAssertGreaterThan(enlargedSecondary.secondaryHeight, baseline.secondaryHeight)
        XCTAssertGreaterThan(secondary.intrinsicContentSize.width, baselineSecondaryWidth)

        let container = MenuBarTextView()
        let primaryLabel = NSTextField(labelWithString: "72%")
        let secondaryLabel = NSTextField(labelWithString: "Reset 2h")
        MenuBarLayout.applyTextLayout(
            container: container,
            primary: primaryLabel,
            secondary: secondaryLabel,
            geometry: enlargedSecondary,
            showAmount: true,
            hasSecondary: true
        )
        XCTAssertEqual(primaryLabel.frame.minX, secondaryLabel.frame.minX, accuracy: 0.001)
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
            MenuBarLayout.menuBarOpticalCenterNudgeX,
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
                baseBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
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

            // A two-component layout preserves the explicit relative offset;
            // a single visible component remains centered even when its
            // stored offset is non-zero. Icon-only uses its own optical
            // baseline, two points left of the combined card baseline.
            let expectedOpticalNudge = geometry.iconWidth > 0 && geometry.textWidth == 0
                ? MenuBarLayout.menuBarIconOnlyOpticalCenterNudgeX
                : MenuBarLayout.menuBarOpticalCenterNudgeX
            XCTAssertEqual(
                centeredBounds.midX,
                baseBounds.midX + expectedOpticalNudge,
                accuracy: 0.001
            )
            XCTAssertGreaterThan(centeredBounds.width, 0)
            XCTAssertLessThanOrEqual(centeredBounds.minX, backgroundBounds.maxX)
            XCTAssertGreaterThanOrEqual(centeredBounds.maxX, backgroundBounds.minX)
        }
    }

    func testSingleVisibleComponentCompensatesItsVisualOffsetButKeepsPreferenceValueUsable() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 50, height: 13),
            secondarySize: .zero,
            showIcon: false,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )
        let backgroundBounds = NSRect(x: 0, y: 0, width: 160, height: 24)

        XCTAssertEqual(
            MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: 0,
                textOffsetX: 10
            ),
            -8,
            accuracy: 0.001
        )

        let iconOnlyGeometry = MenuBarLayout.geometry(
            primarySize: .zero,
            secondarySize: .zero,
            showIcon: true,
            showAmount: false,
            hasSecondary: false,
            isBalance: false
        )
        XCTAssertEqual(
            MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: iconOnlyGeometry,
                iconOffsetX: 0,
                textOffsetX: 0
            ),
            MenuBarLayout.menuBarIconOnlyOpticalCenterNudgeX,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: iconOnlyGeometry,
                iconOffsetX: -4,
                textOffsetX: 0
            ),
            4,
            accuracy: 0.001
        )
    }

    func testAmountOnlyLayoutCentersAgainstUpdatedOuterWidth() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 42, height: 13),
            secondarySize: NSSize(width: 50, height: 9),
            showIcon: false,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let naturalContentWidth = geometry.contentWidth
        let backgroundBounds = NSRect(
            x: 0,
            y: 0,
            width: naturalContentWidth + 108,
            height: 24
        )
        let frames = MenuBarLayout.frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0
        )
        let visibleTextBounds = try! XCTUnwrap(
            MenuBarLayout.visibleTextBounds(
                for: frames,
                geometry: geometry,
                in: backgroundBounds
            )
        )

        XCTAssertEqual(frames.text.minX, 0, accuracy: 0.001)
        XCTAssertEqual(visibleTextBounds.width, geometry.measuredTextWidth, accuracy: 0.001)
        XCTAssertEqual(
            MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: 0,
                textOffsetX: 0,
                centerTextBlock: true
            ),
            backgroundBounds.midX
                + MenuBarLayout.menuBarOpticalCenterNudgeX
                - visibleTextBounds.midX,
            accuracy: 0.001
        )
    }

    func testStatusItemWidthAdjustmentChangesOuterFootprintOnly() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )
        let baseLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: 0
        )
        let narrowLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: -10
        )
        let wideLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: 10
        )

        XCTAssertEqual(baseLength, 93)
        XCTAssertEqual(narrowLength, 83)
        XCTAssertEqual(wideLength, 103)

        let base = MenuBarLayout.frames(
            buttonSize: NSSize(width: baseLength, height: 24),
            geometry: geometry,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )
        let wide = MenuBarLayout.frames(
            buttonSize: NSSize(width: wideLength, height: 24),
            geometry: geometry,
            iconViewYOffset: MenuBarLayout.singleLineIconYOffset
        )

        XCTAssertEqual(wide.content.width, base.content.width)
        XCTAssertEqual(wide.icon, base.icon)
        XCTAssertEqual(wide.text, base.text)
        XCTAssertEqual(wide.content.midX - base.content.midX, 5, accuracy: 0.001)
    }

    func testStatusItemWidthAdjustmentPreservesTenthPointSteps() {
        let geometry = MenuBarLayout.geometry(
            primarySize: NSSize(width: 43.2, height: 13.1),
            secondarySize: .zero,
            showIcon: true,
            showAmount: true,
            hasSecondary: false,
            isBalance: true
        )
        let baseLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: 0
        )

        XCTAssertEqual(
            MenuBarLayout.statusItemLength(
                contentWidth: geometry.contentWidth,
                horizontalPadding: 10,
                widthAdjustment: 0.3
            ),
            baseLength + 0.3,
            accuracy: 0.001
        )
    }

    func testStatusItemWidthAdjustmentNeverShrinksBelowNaturalContent() {
        XCTAssertEqual(
            MenuBarLayout.statusItemLength(
                contentWidth: 80,
                horizontalPadding: 1,
                widthAdjustment: -10
            ),
            80
        )
        XCTAssertEqual(
            MenuBarLayout.statusItemLength(
                contentWidth: 18,
                horizontalPadding: 10,
                widthAdjustment: -100
            ),
            MenuBarLayout.minimumStatusItemLength
        )
        XCTAssertEqual(
            MenuBarLayout.statusItemLength(
                contentWidth: 80,
                horizontalPadding: 1,
                widthAdjustment: -40
            ),
            80
        )
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
