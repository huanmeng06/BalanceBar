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

    func testSingleLinePrimaryAutomaticYOffsetOnlyAppliesToLargePreset() {
        XCTAssertEqual(
            MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                fontSize: CGFloat(MenuBarFontSizePreset.large.primarySize)
            ),
            MenuBarLayout.officialAmountOnlyTextYOffset * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                fontSize: CGFloat(MenuBarFontSizePreset.medium.primarySize)
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                fontSize: CGFloat(MenuBarFontSizePreset.small.primarySize)
            ),
            0,
            accuracy: 0.001
        )
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
            centerVisibleUnionOnBackground: true
        )
        let centeredFrames = MenuBarLayoutFrames(
            content: frames.content.offsetBy(dx: compensation, dy: 0),
            iconSlot: frames.iconSlot,
            icon: frames.icon,
            text: frames.text
        )
        let centeredVisibleBounds = try! XCTUnwrap(
            MenuBarLayout.visibleContentBounds(
                for: centeredFrames,
                in: backgroundBounds
            )
        )

        XCTAssertEqual(
            measuredBounds.width,
            geometry.measuredTextWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            centeredVisibleBounds.midX,
            backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
            accuracy: 0.001
        )
    }

    func testOfficialTwoLineVisibleUnionCentersAndPreservesLeadingIcon() {
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
        let backgroundBounds = NSRect(
            x: 0,
            y: 0,
            width: MenuBarLayout.statusItemLength(
                contentWidth: geometry.contentWidth,
                horizontalPadding: 10,
                widthAdjustment: -20
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
            centerVisibleUnionOnBackground: true
        )
        let centeredFrames = MenuBarLayoutFrames(
            content: adjustedFrames.content.offsetBy(dx: compensation, dy: 0),
            iconSlot: adjustedFrames.iconSlot,
            icon: adjustedFrames.icon,
            text: adjustedFrames.text
        )
        let centeredVisibleBounds = try! XCTUnwrap(
            MenuBarLayout.visibleContentBounds(
                for: centeredFrames,
                in: backgroundBounds
            )
        )
        let centeredIconBounds = adjustedFrames.icon.offsetBy(
            dx: adjustedFrames.content.minX + compensation,
            dy: adjustedFrames.content.minY
        )
        // NSStatusItem.length is the button allocation. AppKit's rendered
        // status-item window/card supplies symmetric side chrome outside that
        // allocation, so the visual clipping boundary is wider than the
        // button frame.
        let visualCardBounds = backgroundBounds.insetBy(
            dx: -MenuBarLayout.menuBarStatusItemVisualOverhangX,
            dy: 0
        )

        XCTAssertEqual(
            centeredVisibleBounds.midX,
            backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(centeredIconBounds.minX, visualCardBounds.minX)
        XCTAssertLessThanOrEqual(centeredIconBounds.maxX, visualCardBounds.maxX)
        XCTAssertGreaterThanOrEqual(centeredVisibleBounds.minX, visualCardBounds.minX)
        XCTAssertLessThanOrEqual(centeredVisibleBounds.maxX, visualCardBounds.maxX)
        XCTAssertEqual(
            (adjustedFrames.text.minX - adjustedFrames.icon.minX)
                - (baseFrames.text.minX - baseFrames.icon.minX),
            -2.5 - 1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(backgroundBounds.width, geometry.contentWidth, accuracy: 0.001)
    }

    func testOfficialTwoLineWidthAdjustmentUsesCenteredPhysicalRange() {
        let primary = NSTextField(labelWithString: "85%")
        primary.font = MenuBarLayout.primaryFont(size: 13)
        let secondary = NSTextField(labelWithString: "6d11h")
        secondary.font = MenuBarLayout.secondaryFont(size: 10)
        let geometry = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        let defaultPhysicalAdjustment = CGFloat(
            AppPreferences.menuBarStatusItemWidthBaseline
        )
        let defaultLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: defaultPhysicalAdjustment
        )
        let narrowLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: defaultPhysicalAdjustment - 10
        )
        let wideLength = MenuBarLayout.statusItemLength(
            contentWidth: geometry.contentWidth,
            horizontalPadding: 10,
            widthAdjustment: defaultPhysicalAdjustment + 10
        )

        XCTAssertEqual(defaultPhysicalAdjustment, 0, accuracy: 0.001)
        XCTAssertEqual(
            defaultLength,
            geometry.contentWidth + 20,
            accuracy: 0.001,
            "logical 0pt keeps the native status-item footprint"
        )
        XCTAssertEqual(narrowLength - defaultLength, -10, accuracy: 0.001)
        XCTAssertEqual(wideLength - defaultLength, 10, accuracy: 0.001)
        XCTAssertEqual(
            wideLength - narrowLength,
            20,
            accuracy: 0.001
        )

        for (label, length) in [
            ("default", defaultLength),
            ("narrow", narrowLength),
            ("wide", wideLength)
        ] {
            let backgroundBounds = NSRect(
                x: 0,
                y: 0,
                width: length,
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
                centerVisibleUnionOnBackground: true
            )
            let centeredFrames = MenuBarLayoutFrames(
                content: frames.content.offsetBy(dx: compensation, dy: 0),
                iconSlot: frames.iconSlot,
                icon: frames.icon,
                text: frames.text
            )
            let visibleBounds = try! XCTUnwrap(
                MenuBarLayout.visibleContentBounds(
                    for: centeredFrames,
                    in: backgroundBounds
                )
            )
            let visualCardBounds = backgroundBounds.insetBy(
                dx: -MenuBarLayout.menuBarStatusItemVisualOverhangX,
                dy: 0
            )

            XCTAssertEqual(
                visibleBounds.midX,
                backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
                accuracy: 0.001,
                "visible union drifted at width \(label)"
            )
            XCTAssertGreaterThanOrEqual(
                visibleBounds.minX,
                visualCardBounds.minX - 0.001,
                "visible union clipped left at width \(label)"
            )
            XCTAssertLessThanOrEqual(
                visibleBounds.maxX,
                visualCardBounds.maxX + 0.001,
                "visible union clipped right at width \(label)"
            )
        }
    }

    func testOfficialTwoLineFontRangeStaysInsideCenteredCardAtWidthBaseline() {
        let primaryText = "100% remaining"
        let secondaryText = "Reset in 99h 23m"

        for preset in MenuBarFontSizePreset.allCases {
                let primarySize = preset.primarySize
                let secondarySize = preset.secondarySize
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
                let backgroundBounds = NSRect(
                    x: 0,
                    y: 0,
                    width: MenuBarLayout.statusItemLength(
                        contentWidth: geometry.contentWidth,
                        horizontalPadding: 10,
                        widthAdjustment: CGFloat(AppPreferences.menuBarStatusItemWidthBaseline)
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
                    centerVisibleUnionOnBackground: true
                )
                let centeredFrames = MenuBarLayoutFrames(
                    content: frames.content.offsetBy(dx: compensation, dy: 0),
                    iconSlot: frames.iconSlot,
                    icon: frames.icon,
                    text: frames.text
                )
                let visibleBounds = try! XCTUnwrap(
                    MenuBarLayout.visibleContentBounds(
                        for: centeredFrames,
                        in: backgroundBounds
                    )
                )
                let iconBounds = frames.icon.offsetBy(
                    dx: frames.content.minX + compensation,
                    dy: frames.content.minY
                )
                let visualCardBounds = backgroundBounds.insetBy(
                    dx: -MenuBarLayout.menuBarStatusItemVisualOverhangX,
                    dy: 0
                )

                XCTAssertEqual(
                    visibleBounds.midX,
                    backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX,
                    accuracy: 0.001,
                    "primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertGreaterThanOrEqual(
                    iconBounds.minX,
                    visualCardBounds.minX - 0.001,
                    "icon left clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertLessThanOrEqual(
                    iconBounds.maxX,
                    visualCardBounds.maxX + 0.001,
                    "icon right clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertGreaterThanOrEqual(
                    visibleBounds.minX,
                    visualCardBounds.minX - 0.001,
                    "text left clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertLessThanOrEqual(
                    visibleBounds.maxX,
                    visualCardBounds.maxX + 0.001,
                    "text right clipped at primary=\(primarySize), secondary=\(secondarySize)"
                )
                XCTAssertEqual(
                    (visibleBounds.minX - visualCardBounds.minX)
                        - (visualCardBounds.maxX - visibleBounds.maxX),
                    MenuBarLayout.menuBarOpticalCenterNudgeX * 2,
                    accuracy: 0.001,
                    "visible union lost optical centering at primary=\(primarySize), secondary=\(secondarySize)"
                )
        }
    }

    func testSharedFontSizeChangesBothRowsAtDefaultRatioAndKeepsRowOrigin() {
        let primary = NSTextField(labelWithString: "72%")
        let secondary = NSTextField(labelWithString: "Reset 2h")
        primary.font = MenuBarLayout.primaryFont(
            size: CGFloat(MenuBarFontSizePreset.large.primarySize)
        )
        secondary.font = MenuBarLayout.secondaryFont(
            size: CGFloat(MenuBarFontSizePreset.large.secondarySize)
        )
        let baseline = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )

        primary.font = MenuBarLayout.primaryFont(
            size: CGFloat(MenuBarFontSizePreset.medium.primarySize)
        )
        secondary.font = MenuBarLayout.secondaryFont(
            size: CGFloat(MenuBarFontSizePreset.medium.secondarySize)
        )
        let enlargedPrimary = MenuBarLayout.geometry(
            primarySize: primary.intrinsicContentSize,
            secondarySize: secondary.intrinsicContentSize,
            showIcon: true,
            showAmount: true,
            hasSecondary: true,
            isBalance: false
        )
        XCTAssertLessThan(enlargedPrimary.primaryHeight, baseline.primaryHeight)
        XCTAssertLessThanOrEqual(enlargedPrimary.secondaryHeight, baseline.secondaryHeight)
        XCTAssertEqual(
            primary.font?.pointSize ?? .nan,
            MenuBarFontSizePreset.medium.primarySize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            secondary.font?.pointSize ?? .nan,
            MenuBarFontSizePreset.medium.secondarySize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            (secondary.font?.pointSize ?? .nan) / (primary.font?.pointSize ?? .nan),
            AppPreferences.menuBarSecondaryToPrimaryFontRatio,
            accuracy: 0.000_001
        )

        let container = MenuBarTextView()
        let primaryLabel = NSTextField(labelWithString: "72%")
        let secondaryLabel = NSTextField(labelWithString: "Reset 2h")
        MenuBarLayout.applyTextLayout(
            container: container,
            primary: primaryLabel,
            secondary: secondaryLabel,
            geometry: enlargedPrimary,
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
        let visibleContentBounds = try! XCTUnwrap(
            MenuBarLayout.visibleContentBounds(
                for: frames,
                in: backgroundBounds
            )
        )

        XCTAssertEqual(frames.text.minX, 0, accuracy: 0.001)
        let measuredTextBounds = try! XCTUnwrap(
            MenuBarLayout.visibleTextBounds(
                for: frames,
                geometry: geometry,
                in: backgroundBounds
            )
        )
        XCTAssertEqual(measuredTextBounds.width, geometry.measuredTextWidth, accuracy: 0.001)
        XCTAssertEqual(
            MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: backgroundBounds,
                geometry: geometry,
                iconOffsetX: 0,
                textOffsetX: 0,
                centerVisibleUnionOnBackground: true
            ),
            backgroundBounds.midX
                + MenuBarLayout.menuBarOpticalCenterNudgeX
                - visibleContentBounds.midX,
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

    func testSingleLineReserveUsesCurrentTextAndIconModeAcrossAllPresets() {
        let primaryText = "USD 123,456.78"
        let padding: CGFloat = 10

        for isBalance in [false, true] {
            let iconLength = MenuBarLayout.singleLineStatusItemLength(
                primaryText: primaryText,
                showIcon: true,
                isBalance: isBalance,
                horizontalPadding: padding
            )
            let amountOnlyLength = MenuBarLayout.singleLineStatusItemLength(
                primaryText: primaryText,
                showIcon: false,
                isBalance: isBalance,
                horizontalPadding: padding
            )

            XCTAssertGreaterThan(
                iconLength,
                amountOnlyLength,
                "hidden icons must not be reserved in amount-only mode"
            )
            XCTAssertEqual(
                iconLength,
                MenuBarLayout.singleLineStatusItemLength(
                    primaryText: primaryText,
                    showIcon: true,
                    isBalance: isBalance,
                    horizontalPadding: padding,
                    widthAdjustment: 0
                ),
                accuracy: 0.001
            )

            for showIcon in [false, true] {
                let reservedLength = MenuBarLayout.singleLineStatusItemLength(
                    primaryText: primaryText,
                    showIcon: showIcon,
                    isBalance: isBalance,
                    horizontalPadding: padding
                )
                for preset in MenuBarFontSizePreset.allCases {
                    let label = NSTextField(labelWithString: primaryText)
                    label.font = MenuBarLayout.primaryFont(
                        size: CGFloat(preset.primarySize)
                    )
                    let geometry = MenuBarLayout.geometry(
                        primarySize: label.intrinsicContentSize,
                        secondarySize: .zero,
                        showIcon: showIcon,
                        showAmount: true,
                        hasSecondary: false,
                        isBalance: isBalance
                    )
                    let presetLength = MenuBarLayout.statusItemLength(
                        contentWidth: geometry.contentWidth,
                        horizontalPadding: padding
                    )
                    XCTAssertGreaterThanOrEqual(
                        reservedLength,
                        presetLength,
                        "single-line preset must fit reserved width"
                    )
                }
            }

            let plusTen = MenuBarLayout.singleLineStatusItemLength(
                primaryText: primaryText,
                showIcon: true,
                isBalance: isBalance,
                horizontalPadding: padding,
                widthAdjustment: 10
            )
            let plusTwenty = MenuBarLayout.singleLineStatusItemLength(
                primaryText: primaryText,
                showIcon: true,
                isBalance: isBalance,
                horizontalPadding: padding,
                widthAdjustment: 20
            )
            XCTAssertEqual(plusTen - iconLength, 10, accuracy: 0.001)
            XCTAssertEqual(plusTwenty - plusTen, 10, accuracy: 0.001)
        }
    }

    func testSingleLinePrimaryInkCentersIndependentlyFromSlackAcrossMatrix() {
        let scenarios: [(String, Bool)] = [
            ("48%", false),
            ("USD 123,456.78", true),
            ("$0.10", true)
        ]

        for (primaryText, isBalance) in scenarios {
            for showIcon in [false, true] {
                let length = MenuBarLayout.singleLineStatusItemLength(
                    primaryText: primaryText,
                    showIcon: showIcon,
                    isBalance: isBalance,
                    horizontalPadding: 10
                )
                let backgroundBounds = NSRect(
                    x: 0,
                    y: 0,
                    width: length,
                    height: 24
                )
                let targetX = MenuBarLayout.singleLinePrimaryAnchorX(
                    backgroundBounds: backgroundBounds,
                    primaryText: primaryText,
                    showIcon: showIcon,
                    isBalance: isBalance
                )
                var correctedBounds: [(MenuBarFontSizePreset, NSRect)] = []

                for preset in MenuBarFontSizePreset.allCases {
                    let label = NSTextField(labelWithString: primaryText)
                    label.font = MenuBarLayout.primaryFont(
                        size: CGFloat(preset.primarySize)
                    )
                    let geometry = MenuBarLayout.geometry(
                        primarySize: label.intrinsicContentSize,
                        secondarySize: .zero,
                        showIcon: showIcon,
                        showAmount: true,
                        hasSecondary: false,
                        isBalance: isBalance
                    )
                    let frames = MenuBarLayout.frames(
                        buttonSize: backgroundBounds.size,
                        geometry: geometry,
                        iconViewYOffset: showIcon && isBalance
                            ? MenuBarLayout.singleLineIconYOffset
                            : 0,
                        textOffset: NSSize(
                            width: 0,
                            height: isBalance
                                ? 0
                                : MenuBarLayout.officialAmountOnlyTextYOffset
                        )
                    )
                    let primaryInk = try! XCTUnwrap(
                        MenuBarLayout.singleLinePrimaryInkBounds(
                            for: label,
                            frames: frames,
                            geometry: geometry,
                            in: backgroundBounds
                        ),
                        "single-line primary ink must be measurable"
                    )
                    XCTAssertLessThan(
                        primaryInk.width,
                        frames.text.width,
                        "anti-clipping slack must not be counted as glyph ink"
                    )

                    // This is the exact narrow correction applied by the live
                    // single-line path: horizontal translation follows the
                    // stable widest-preset primary anchor; vertical
                    // translation follows primary ink alone and leaves the
                    // icon frame untouched.
                    let automaticYOffset = MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                        fontSize: CGFloat(preset.primarySize)
                    )
                    let corrected = primaryInk.offsetBy(
                        dx: targetX - primaryInk.midX,
                        dy: backgroundBounds.midY - automaticYOffset - primaryInk.midY
                    )
                    XCTAssertEqual(corrected.midX, targetX, accuracy: 0.001)
                    XCTAssertEqual(
                        corrected.midY,
                        backgroundBounds.midY - automaticYOffset,
                        accuracy: 0.001
                    )
                    correctedBounds.append((preset, corrected))

                    let iconFrame = frames.icon.offsetBy(
                        dx: frames.content.minX,
                        dy: frames.content.minY
                    )
                    let iconCenterBefore = iconFrame.midY
                    let iconCenterAfter = iconFrame.midY
                    XCTAssertEqual(
                        iconCenterAfter,
                        iconCenterBefore,
                        accuracy: 0.001,
                        "primary correction must not move the icon"
                    )
                }

                let centers = correctedBounds.map { $0.1.midX }
                XCTAssertLessThanOrEqual(
                    (centers.max() ?? 0) - (centers.min() ?? 0),
                    0.5,
                    "single-line primary ink X drifted"
                )
                let verticalCenters = correctedBounds.map { $0.1.midY }
                let expectedAutomaticYOffsets = MenuBarFontSizePreset.allCases.map {
                    MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                        fontSize: CGFloat($0.primarySize)
                    )
                }
                XCTAssertEqual(
                    (verticalCenters.max() ?? 0) - (verticalCenters.min() ?? 0),
                    (expectedAutomaticYOffsets.max() ?? 0)
                        - (expectedAutomaticYOffsets.min() ?? 0),
                    accuracy: 0.001,
                    "single-line primary ink must follow the explicit per-preset optical calibration"
                )

                let large = try! XCTUnwrap(
                    correctedBounds.first { $0.0 == .large }?.1
                )
                let small = try! XCTUnwrap(
                    correctedBounds.first { $0.0 == .small }?.1
                )
                XCTAssertGreaterThanOrEqual(
                    large.width,
                    small.width,
                    "smaller glyphs must contract around the anchor"
                )
                XCTAssertGreaterThan(
                    abs(large.maxX - targetX),
                    abs(small.maxX - targetX) - 0.5,
                    "small preset kept a fixed right edge instead of shrinking around center"
                )

                let visualCardBounds = backgroundBounds.insetBy(
                    dx: -MenuBarLayout.menuBarStatusItemVisualOverhangX,
                    dy: 0
                )
                for (_, bounds) in correctedBounds {
                    XCTAssertGreaterThanOrEqual(
                        bounds.minX,
                        visualCardBounds.minX - 0.001,
                        "single-line primary ink clipped left"
                    )
                    XCTAssertLessThanOrEqual(
                        bounds.maxX,
                        visualCardBounds.maxX + 0.001,
                        "single-line primary ink clipped right"
                    )
                }
            }
        }
    }

    func testSingleLinePrimaryInkMeasurementSupportsLightAndDarkAppearance() throws {
        let backgroundBounds = NSRect(x: 0, y: 0, width: 180, height: 24)
        let appearances: [(String, NSAppearance?)] = [
            ("light", NSAppearance(named: .aqua)),
            ("dark", NSAppearance(named: .darkAqua))
        ]

        for (name, appearance) in appearances {
            let label = NSTextField(labelWithString: "USD 123,456.78")
            label.appearance = appearance
            label.font = MenuBarLayout.primaryFont(
                size: CGFloat(MenuBarFontSizePreset.large.primarySize)
            )
            let geometry = MenuBarLayout.geometry(
                primarySize: label.intrinsicContentSize,
                secondarySize: .zero,
                showIcon: true,
                showAmount: true,
                hasSecondary: false,
                isBalance: true
            )
            let frames = MenuBarLayout.frames(
                buttonSize: backgroundBounds.size,
                geometry: geometry,
                iconViewYOffset: MenuBarLayout.singleLineIconYOffset
            )
            let ink = try XCTUnwrap(
                MenuBarLayout.singleLinePrimaryInkBounds(
                    for: label,
                    frames: frames,
                    geometry: geometry,
                    in: backgroundBounds
                ),
                "primary ink should be measurable in \(name) appearance"
            )
            XCTAssertLessThan(ink.width, frames.text.width)
            XCTAssertGreaterThan(
                ink.width,
                frames.text.width / 2,
                "raster scale must preserve the logical glyph width"
            )
            XCTAssertGreaterThan(ink.height, 0)
            XCTAssertGreaterThan(
                ink.height,
                5,
                "raster scale must preserve the logical glyph height"
            )
        }
    }

    func testOfficialTwoLineGeometryDoesNotUseSingleLinePrimaryAnchor() {
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
        let backgroundBounds = NSRect(x: 0, y: 0, width: 120, height: 24)
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
            centerVisibleUnionOnBackground: true
        )
        let centered = MenuBarLayoutFrames(
            content: frames.content.offsetBy(dx: compensation, dy: 0),
            iconSlot: frames.iconSlot,
            icon: frames.icon,
            text: frames.text
        )
        let visible = try! XCTUnwrap(
            MenuBarLayout.visibleContentBounds(
                for: centered,
                in: backgroundBounds
            )
        )

        XCTAssertGreaterThan(geometry.secondaryHeight, 0)
        XCTAssertEqual(visible.midX, backgroundBounds.midX + MenuBarLayout.menuBarOpticalCenterNudgeX, accuracy: 0.001)
        XCTAssertNil(
            MenuBarLayout.singleLinePrimaryInkBounds(
                for: primary,
                frames: frames,
                geometry: geometry,
                in: backgroundBounds
            ),
            "protected two-line layout must not be measured as a single-line primary"
        )
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

    func testAnimationFramesDoNotUseSemanticImageChangeCallback() {
        let imageView = RotatingTemplateImageView()
        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        let animationFrame = NSImage(size: NSSize(width: 16, height: 16))
        var semanticImageChangeCount = 0

        imageView.onImageChanged = { _ in
            semanticImageChangeCount += 1
        }

        imageView.setSourceImage(sourceImage)
        for _ in 0..<36 {
            imageView.displayImage(animationFrame)
        }

        XCTAssertEqual(semanticImageChangeCount, 1)

        imageView.setSourceImage(sourceImage)
        XCTAssertEqual(semanticImageChangeCount, 2)
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
