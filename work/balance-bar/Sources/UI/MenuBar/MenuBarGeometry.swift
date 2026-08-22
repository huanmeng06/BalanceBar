import AppKit

enum MenuBarBackingAlignment {
    /// Align a frame origin to a physical display pixel. The fallback keeps
    /// the historical allocation behavior for callers that do not have a
    /// rendered backing scale yet; the live menu bar and Dashboard preview
    /// always provide their actual scale.
    static func aligned(_ value: CGFloat, scale: CGFloat?) -> CGFloat {
        guard let scale, scale.isFinite, scale > 0 else {
            return floor(value)
        }
        return (value * scale).rounded() / scale
    }
}

struct MenuBarGeometry {
    let iconWidth: CGFloat
    let gap: CGFloat
    /// The widest measured text row before the anti-clipping slack is added.
    /// This is the horizontal metric used when the official two-line text
    /// block itself is centered; `textWidth` remains the actual label frame.
    let measuredTextWidth: CGFloat
    /// Raw AppKit layout metrics. These are deliberately kept separate from
    /// the ceil-rounded allocation metrics below so visual centering does not
    /// jump when a font size crosses a fractional-height boundary.
    let measuredPrimaryHeight: CGFloat
    let measuredSecondaryHeight: CGFloat
    let measuredTextHeight: CGFloat
    let textWidth: CGFloat
    let primaryHeight: CGFloat
    let secondaryHeight: CGFloat
    let textHeight: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat

    private static func backingAligned(_ value: CGFloat, scale: CGFloat?) -> CGFloat {
        guard let scale, scale.isFinite, scale > 0 else {
            return floor(value)
        }
        return (value * scale).rounded() / scale
    }

    init(
        primarySize: NSSize,
        secondarySize: NSSize,
        showIcon: Bool,
        showAmount: Bool,
        hasSecondary: Bool,
        isBalance: Bool,
        iconSlotWidth: CGFloat,
        iconTextSpacing: CGFloat,
        textRowSpacing: CGFloat,
        textWidthSlack: CGFloat,
        singleLineHeight: CGFloat
    ) {
        iconWidth = showIcon ? iconSlotWidth : 0
        gap = showIcon && showAmount ? iconTextSpacing : 0
        measuredTextWidth = showAmount
            ? max(0, max(primarySize.width, secondarySize.width))
            : 0
        measuredPrimaryHeight = showAmount ? max(0, primarySize.height) : 0
        measuredSecondaryHeight = hasSecondary ? max(0, secondarySize.height) : 0
        measuredTextHeight = showAmount
            ? measuredPrimaryHeight + (hasSecondary ? textRowSpacing + measuredSecondaryHeight : 0)
            : 0
        textWidth = showAmount
            ? ceil(measuredTextWidth) + textWidthSlack
            : 0
        primaryHeight = showAmount ? ceil(primarySize.height) : 0
        secondaryHeight = hasSecondary ? ceil(secondarySize.height) : 0
        textHeight = primaryHeight + (hasSecondary ? textRowSpacing + secondaryHeight : 0)
        contentWidth = iconWidth + gap + textWidth
        contentHeight = isBalance && showAmount
            ? max(singleLineHeight, textHeight)
            : ceil(max(iconWidth, textHeight))
    }

    func iconCenterYInFlippedButton(
        buttonHeight: CGFloat,
        iconViewYOffset: CGFloat,
        backingScaleFactor: CGFloat? = nil
    ) -> CGFloat {
        let contentY = Self.backingAligned(
            (buttonHeight - contentHeight) / 2,
            scale: backingScaleFactor
        )
        let slotYFromTop = Self.backingAligned(
            max(0, (contentHeight - iconWidth) / 2),
            scale: backingScaleFactor
        )
        // The status button and content stack are flipped while the icon slot
        // is not. Positive local icon Y therefore decreases button-space Y.
        return contentY + slotYFromTop - iconViewYOffset + (iconWidth / 2)
    }

    func iconViewYOffset(
        alignedTo reference: MenuBarGeometry,
        buttonHeight: CGFloat,
        referenceIconViewYOffset: CGFloat,
        backingScaleFactor: CGFloat? = nil
    ) -> CGFloat {
        iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: 0,
            backingScaleFactor: backingScaleFactor
        ) - reference.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: referenceIconViewYOffset,
            backingScaleFactor: backingScaleFactor
        )
    }
}

struct MenuBarLayoutFrames {
    let content: NSRect
    let iconSlot: NSRect
    let icon: NSRect
    let text: NSRect
}

/// Coordinate spaces used by the real status item and the Dashboard preview.
/// The real menu bar positions views with frames (icon slot is unflipped, the
/// text stack lives in a flipped container); the Dashboard preview positions
/// them with layer transforms (the icon layer is unflipped, the text layer is
/// geometry-flipped to match its flipped view).
enum MenuBarOffsetSpace {
    /// Frame coordinates inside an unflipped container: y grows upward.
    case unflippedFrame
    /// Frame coordinates inside a flipped container: y grows downward.
    case flippedFrame
    /// Layer transform coordinates on a non-flipped layer: y grows upward.
    case unflippedLayer
    /// Layer transform coordinates on a geometry-flipped layer: y grows
    /// downward.
    case flippedLayer
}

/// Shared visual→coordinate mapping so the real menu bar and the Dashboard
/// preview interpret the same user offset identically. User offsets are visual
/// values: positive x moves right, positive y moves up.
enum MenuBarOffsetLayout {
    static func xDelta(visualX: CGFloat) -> CGFloat { visualX }

    static func yDelta(visualY: CGFloat, in space: MenuBarOffsetSpace) -> CGFloat {
        switch space {
        case .unflippedFrame, .unflippedLayer:
            return visualY
        case .flippedFrame, .flippedLayer:
            return -visualY
        }
    }

    /// Inverse of `yDelta`: converts a delta already expressed in `space` back
    /// to the visual y offset it represents.
    static func visualY(forYDelta delta: CGFloat, in space: MenuBarOffsetSpace) -> CGFloat {
        switch space {
        case .unflippedFrame, .unflippedLayer:
            return delta
        case .flippedFrame, .flippedLayer:
            return -delta
        }
    }
}

enum MenuBarLayout {
    static let primaryFontPointSize: CGFloat = CGFloat(
        AppPreferences.menuBarFontSizeDefault
    )
    static let secondaryFontPointSize: CGFloat = CGFloat(
        AppPreferences.secondaryMenuBarFontSize(
            for: AppPreferences.menuBarFontSizeDefault
        )
    )

    static var primaryFont: NSFont {
        primaryFont(size: primaryFontPointSize)
    }

    static var secondaryFont: NSFont {
        secondaryFont(size: secondaryFontPointSize)
    }

    static func primaryFont(size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    static func secondaryFont(size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }
    static let iconSlotWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 6
    static let textRowSpacing: CGFloat = -2
    static let textWidthSlack: CGFloat = 5
    static let minimumStatusItemLength: CGFloat = 30

    // Fixed API single-line baseline/minimum. Keep these independent from the
    // official two-line layout while allowing a larger selected font to fit.
    static let singleLineHeight: CGFloat = 18
    static let singleLineTextYOffset: CGFloat = 0.25
    static let singleLineIconYOffset: CGFloat = 0.25

    // Official quota text baseline (visual: positive = up). Percentage-only
    // text sits slightly higher; the two-line layout with reset time sits
    // slightly lower. User fine-tune offsets stack on top of these defaults.
    static let officialAmountOnlyTextYOffset: CGFloat = 0.5
    static let officialSecondaryTextYOffset: CGFloat = -0.1

    // The rendered status-item capsule/shadow is optically centered two points
    // to the right of the nominal status-item bounds. Keep this shared by the
    // real menu bar and Dashboard preview; it is a layout baseline, not a
    // persisted user offset.
    static let menuBarOpticalCenterNudgeX: CGFloat = 2

    // The icon-only card does not have the amount column's visual mass. Its
    // observed optical center is the nominal background center, so it needs
    // two points less nudge than the combined icon+amount card.
    static let menuBarIconOnlyOpticalCenterNudgeX: CGFloat = 0

    // AppKit gives an NSStatusItem's button an 8pt side chrome in the
    // rendered status-item window/card. This is outside `NSStatusItem.length`
    // (the value that controls the gap to adjacent status items), but it is
    // part of the visible capsule/shadow. Keep the measurement explicit so
    // the font-layout reserve does not accidentally become a second width
    // slider.
    static let menuBarStatusItemVisualOverhangX: CGFloat = 8

    static func officialTextYOffset(hasSecondary: Bool) -> CGFloat {
        hasSecondary ? officialSecondaryTextYOffset : officialAmountOnlyTextYOffset
    }

    /// Returns the complete horizontal footprint of the BalanceBar status
    /// item. The adjustment belongs to the outer NSStatusItem length, so it
    /// changes the space allocated beside neighboring status items without
    /// changing the icon/text spacing inside this item. Keep the natural
    /// footprint as a hard lower bound so a narrow setting cannot clip
    /// visible content.
    static func statusItemLength(
        contentWidth: CGFloat,
        horizontalPadding: CGFloat,
        widthAdjustment: CGFloat = 0
    ) -> CGFloat {
        let safeContentWidth = max(0, contentWidth)
        let safePadding = max(0, horizontalPadding)
        // Keep the user-visible 0.1pt step in the actual footprint. The
        // natural content width is already measured in whole points; rounding
        // the complete result here would turn a continuous slider into 1pt
        // jumps.
        let requestedLength = safeContentWidth + (safePadding * 2) + widthAdjustment
        let safeMinimum = max(minimumStatusItemLength, safeContentWidth)
        return max(safeMinimum, requestedLength)
    }

    static func geometry(
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
            iconSlotWidth: iconSlotWidth,
            iconTextSpacing: iconTextSpacing,
            textRowSpacing: textRowSpacing,
            textWidthSlack: textWidthSlack,
            singleLineHeight: singleLineHeight
        )
    }

    static func applyTextLayout(
        container: MenuBarTextView,
        primary: NSTextField,
        secondary: NSTextField,
        geometry: MenuBarGeometry,
        showAmount: Bool,
        hasSecondary: Bool
    ) {
        container.layoutSize = NSSize(
            width: geometry.textWidth,
            height: geometry.textHeight
        )
        primary.isHidden = !showAmount
        primary.frame = NSRect(
            x: 0,
            y: 0,
            width: geometry.textWidth,
            height: geometry.primaryHeight
        )
        secondary.isHidden = !hasSecondary
        secondary.frame = hasSecondary
            ? NSRect(
                x: 0,
                y: geometry.primaryHeight + textRowSpacing,
                width: geometry.textWidth,
                height: geometry.secondaryHeight
            )
            : .zero
    }

    /// Frames are expressed in visual terms: a positive offset x moves the
    /// element right and a positive offset y moves it up. The icon slot is
    /// unflipped while the text stack lives in a flipped container, so the
    /// same semantic y offset maps to opposite frame y signs internally.
    static func frames(
        buttonSize: NSSize,
        geometry: MenuBarGeometry,
        iconViewYOffset: CGFloat,
        iconOffset: NSSize = .zero,
        textOffset: NSSize = .zero,
        backingScaleFactor: CGFloat? = nil
    ) -> MenuBarLayoutFrames {
        let content = NSRect(
            x: MenuBarBackingAlignment.aligned(
                max(0, (buttonSize.width - geometry.contentWidth) / 2),
                scale: backingScaleFactor
            ),
            y: MenuBarBackingAlignment.aligned(
                (buttonSize.height - geometry.contentHeight) / 2,
                scale: backingScaleFactor
            ),
            width: geometry.contentWidth,
            height: geometry.contentHeight
        )
        let iconSlot = NSRect(
            x: 0,
            y: MenuBarBackingAlignment.aligned(
                max(0, (geometry.contentHeight - geometry.iconWidth) / 2),
                scale: backingScaleFactor
            ),
            width: geometry.iconWidth,
            height: geometry.iconWidth
        )
        let icon = NSRect(
            x: MenuBarOffsetLayout.xDelta(visualX: iconOffset.width),
            y: iconViewYOffset + MenuBarOffsetLayout.yDelta(
                visualY: iconOffset.height,
                in: .unflippedFrame
            ),
            width: iconSlot.width,
            height: iconSlot.height
        )
        let text = NSRect(
            x: geometry.iconWidth + geometry.gap + MenuBarOffsetLayout.xDelta(visualX: textOffset.width),
            y: MenuBarBackingAlignment.aligned(
                max(0, (geometry.contentHeight - geometry.textHeight) / 2),
                scale: backingScaleFactor
            )
                + MenuBarOffsetLayout.yDelta(
                    visualY: textOffset.height,
                    in: .flippedFrame
                ),
            width: geometry.textWidth,
            height: geometry.textHeight
        )
        return MenuBarLayoutFrames(
            content: content,
            iconSlot: iconSlot,
            icon: icon,
            text: text
        )
    }

    /// Returns the visible horizontal bounds of the icon and amount frames in
    /// the supplied background coordinate space. The component frames in
    /// `MenuBarLayoutFrames` are relative to `content`, while
    /// `backgroundBounds` is the actual status-item/card geometry.
    static func visibleContentBounds(
        for frames: MenuBarLayoutFrames,
        in backgroundBounds: NSRect
    ) -> NSRect? {
        let contentOrigin = NSPoint(
            x: backgroundBounds.minX + frames.content.minX,
            y: backgroundBounds.minY + frames.content.minY
        )
        var result: NSRect?
        for frame in [frames.icon, frames.text] where frame.width > 0 && frame.height > 0 {
            let absoluteFrame = frame.offsetBy(
                dx: contentOrigin.x,
                dy: contentOrigin.y
            )
            result = result.map { $0.union(absoluteFrame) } ?? absoluteFrame
        }
        return result
    }

    /// Returns the measured horizontal bounds of the amount text block. The
    /// label frame includes `textWidthSlack` to prevent glyph clipping; that
    /// slack is deliberately excluded from this metric so the official two
    /// rows are centered by their actual measured width.
    static func visibleTextBounds(
        for frames: MenuBarLayoutFrames,
        geometry: MenuBarGeometry,
        in backgroundBounds: NSRect
    ) -> NSRect? {
        guard frames.text.height > 0,
              geometry.measuredTextWidth > 0 else {
            return nil
        }
        let contentOrigin = NSPoint(
            x: backgroundBounds.minX + frames.content.minX,
            y: backgroundBounds.minY + frames.content.minY
        )
        return NSRect(
            x: contentOrigin.x + frames.text.minX,
            y: contentOrigin.y
                + frames.text.minY
                + max(0, (frames.text.height - geometry.measuredTextHeight) / 2),
            width: min(frames.text.width, geometry.measuredTextWidth),
            height: min(frames.text.height, geometry.measuredTextHeight)
        )
    }

    /// Returns the visible union using actual measured text bounds rather than
    /// the padded label allocation. The 5pt label slack remains available for
    /// clipping safety, but never contributes to visual centering.
    static func visibleMeasuredContentBounds(
        for frames: MenuBarLayoutFrames,
        geometry: MenuBarGeometry,
        in backgroundBounds: NSRect
    ) -> NSRect? {
        let contentOrigin = NSPoint(
            x: backgroundBounds.minX + frames.content.minX,
            y: backgroundBounds.minY + frames.content.minY
        )
        var result: NSRect?
        if frames.icon.width > 0, frames.icon.height > 0 {
            result = frames.icon.offsetBy(
                dx: contentOrigin.x,
                dy: contentOrigin.y
            )
        }
        if let textBounds = visibleTextBounds(
            for: frames,
            geometry: geometry,
            in: backgroundBounds
        ) {
            result = result.map { $0.union(textBounds) } ?? textBounds
        }
        return result
    }

    /// Equal translation for the outer content container that compensates for
    /// independent icon/amount X offsets. The baseline and adjusted bounds
    /// are both measured using the actual background geometry. The visible
    /// icon/text union is centered, including the existing 2pt optical
    /// correction for the rendered capsule/shadow. Official two-line layouts
    /// can opt into the actual background midpoint so fractional frame
    /// flooring cannot move the union by half a point when the shared font
    /// size changes. A user offset changes only the relative arrangement and
    /// not the selected target center. If only one component is visible, its
    /// configured X offset is compensated so the sole visible component
    /// remains centered; the preference value itself is retained and becomes
    /// visible again when both components are shown.
    ///
    /// This helper deliberately does not allocate width. The caller supplies
    /// the real status-item/card bounds; a width setting therefore changes the
    /// centering reference without being reimplemented here.
    static func horizontalCenteringCompensation(
        backgroundBounds: NSRect,
        geometry: MenuBarGeometry,
        iconOffsetX: CGFloat,
        textOffsetX: CGFloat,
        centerVisibleUnionOnBackground: Bool = false,
        backingScaleFactor: CGFloat? = nil
    ) -> CGFloat {
        guard geometry.iconWidth > 0 || geometry.textWidth > 0 else {
            return 0
        }

        let baseFrames = frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0,
            backingScaleFactor: backingScaleFactor
        )
        let adjustedFrames = frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0,
            iconOffset: NSSize(width: iconOffsetX, height: 0),
            textOffset: NSSize(width: textOffsetX, height: 0),
            backingScaleFactor: backingScaleFactor
        )
        let bounds: (base: NSRect?, adjusted: NSRect?)
        if centerVisibleUnionOnBackground {
            bounds = (
                visibleMeasuredContentBounds(
                    for: baseFrames,
                    geometry: geometry,
                    in: backgroundBounds
                ),
                visibleMeasuredContentBounds(
                    for: adjustedFrames,
                    geometry: geometry,
                    in: backgroundBounds
                )
            )
        } else {
            bounds = (
                visibleContentBounds(for: baseFrames, in: backgroundBounds),
                visibleContentBounds(for: adjustedFrames, in: backgroundBounds)
            )
        }
        let baseBounds = bounds.base
        let adjustedBounds = bounds.adjusted
        guard let baseBounds, let adjustedBounds else {
            return 0
        }
        let opticalCenterNudgeX = geometry.iconWidth > 0 && geometry.textWidth == 0
            ? menuBarIconOnlyOpticalCenterNudgeX
            : menuBarOpticalCenterNudgeX
        let targetCenter = centerVisibleUnionOnBackground
            ? backgroundBounds.midX
            : baseBounds.midX
        let rawCompensation = targetCenter
            + opticalCenterNudgeX
            - adjustedBounds.midX
        guard backingScaleFactor != nil else { return rawCompensation }
        return MenuBarBackingAlignment.aligned(rawCompensation, scale: backingScaleFactor)
    }
}
