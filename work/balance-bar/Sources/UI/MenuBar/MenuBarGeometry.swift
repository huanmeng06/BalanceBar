import AppKit

struct MenuBarGeometry {
    let iconWidth: CGFloat
    let gap: CGFloat
    /// The widest measured text row before the anti-clipping slack is added.
    /// This is the horizontal metric used when the official two-line text
    /// block itself is centered; `textWidth` remains the actual label frame.
    let measuredTextWidth: CGFloat
    let textWidth: CGFloat
    let primaryHeight: CGFloat
    let secondaryHeight: CGFloat
    let textHeight: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat

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
        iconViewYOffset: CGFloat
    ) -> CGFloat {
        let contentY = floor((buttonHeight - contentHeight) / 2)
        let slotYFromTop = floor(max(0, (contentHeight - iconWidth) / 2))
        // The status button and content stack are flipped while the icon slot
        // is not. Positive local icon Y therefore decreases button-space Y.
        return contentY + slotYFromTop - iconViewYOffset + (iconWidth / 2)
    }

    func iconViewYOffset(
        alignedTo reference: MenuBarGeometry,
        buttonHeight: CGFloat,
        referenceIconViewYOffset: CGFloat
    ) -> CGFloat {
        iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: 0
        ) - reference.iconCenterYInFlippedButton(
            buttonHeight: buttonHeight,
            iconViewYOffset: referenceIconViewYOffset
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

    // Apple Color Emoji's moon glyph is visibly larger than the percentage
    // glyph at the same logical point size. Keep its scale and baseline
    // correction as independent optical controls across all font presets.
    static let primaryMoonScale: CGFloat = 0.68
    static let primaryMoonBaselineOffsetRatio: CGFloat = 0.07

    /// Applies the compact primary amount as an attributed string so the
    /// Reserve marker is rendered with an explicit optical scale and baseline
    /// relative to the percentage. Apple Color Emoji is a fallback glyph
    /// rather than part of the monospaced-digit font, so making that attribute
    /// explicit keeps its metrics stable in both the real status item and the
    /// Dashboard preview.
    static func applyPrimaryText(_ text: String, to label: NSTextField) {
        let font = label.font ?? primaryFont
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let moonRange = (text as NSString).range(of: "🌙", options: .backwards)
        if moonRange.location != NSNotFound {
            let moonFont = NSFont.systemFont(
                ofSize: font.pointSize * primaryMoonScale,
                weight: .semibold
            )
            attributed.addAttributes(
                [
                    .font: moonFont,
                    .baselineOffset: font.pointSize * primaryMoonBaselineOffsetRatio
                ],
                range: moonRange
            )
        }
        label.attributedStringValue = attributed
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

    /// The large amount-only preset now needs two half-point AppKit optical
    /// lifts after the primary ink is measured. Keep this correction scoped to
    /// the single-line primary text; medium/small and every two-line path
    /// retain their zero automatic adjustment.
    static func singleLinePrimaryAutomaticYOffset(fontSize: CGFloat) -> CGFloat {
        guard MenuBarFontSizePreset.nearest(to: Double(fontSize)) == .large else {
            return 0
        }
        return officialAmountOnlyTextYOffset * 2
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

    /// Returns the outer footprint for the amount-only modes whose visible
    /// primary text must keep one screen-space anchor while its font changes.
    /// The reserve is deliberately based on the current amount and icon mode:
    /// a hidden icon is never included in an amount-only footprint.
    static func singleLineStatusItemLength(
        primaryText: String,
        showIcon: Bool,
        isBalance: Bool,
        horizontalPadding: CGFloat,
        widthAdjustment: CGFloat = 0
    ) -> CGFloat {
        let widestContentWidth = MenuBarFontSizePreset.allCases
            .map { preset -> CGFloat in
                let label = NSTextField(labelWithString: primaryText)
                label.font = primaryFont(size: CGFloat(preset.primarySize))
                applyPrimaryText(primaryText, to: label)
                let geometry = geometry(
                    primarySize: label.intrinsicContentSize,
                    secondarySize: .zero,
                    showIcon: showIcon,
                    showAmount: true,
                    hasSecondary: false,
                    isBalance: isBalance
                )
                return geometry.contentWidth
            }
            .max() ?? 0
        return statusItemLength(
            contentWidth: widestContentWidth,
            horizontalPadding: horizontalPadding,
            widthAdjustment: widthAdjustment
        )
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
        textOffset: NSSize = .zero
    ) -> MenuBarLayoutFrames {
        let content = NSRect(
            x: floor(max(0, (buttonSize.width - geometry.contentWidth) / 2)),
            y: floor((buttonSize.height - geometry.contentHeight) / 2),
            width: geometry.contentWidth,
            height: geometry.contentHeight
        )
        let iconSlot = NSRect(
            x: 0,
            y: floor(max(0, (geometry.contentHeight - geometry.iconWidth) / 2)),
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
            y: floor(max(0, (geometry.contentHeight - geometry.textHeight) / 2))
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
            y: contentOrigin.y + frames.text.minY,
            width: min(frames.text.width, geometry.measuredTextWidth),
            height: frames.text.height
        )
    }

    /// Measures the actual primary glyph ink without treating the label's
    /// anti-clipping frame slack as visible content. This is intentionally a
    /// narrow AppKit measurement used by amount-only single-line layout; the
    /// existing two-line geometry continues to use its established frame
    /// metrics.
    static func appKitRenderedTextBounds(
        for label: NSTextField,
        frameSize: NSSize,
        range: NSRange? = nil
    ) -> NSRect? {
        guard frameSize.width > 0, frameSize.height > 0,
              let cell = label.cell else {
            return nil
        }

        let rasterScale: CGFloat = 4
        let pixelsWide = max(1, Int(ceil(frameSize.width * rasterScale)))
        let pixelsHigh = max(1, Int(ceil(frameSize.height * rasterScale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap),
        let bitmapData = bitmap.bitmapData else {
            return nil
        }

        let previousFrame = label.frame
        let previousAttributedString = label.attributedStringValue
        label.frame = NSRect(origin: .zero, size: frameSize)
        if let range {
            let masked = NSMutableAttributedString(
                attributedString: previousAttributedString
            )
            if range.location > 0 {
                masked.mutableString.replaceCharacters(
                    in: NSRange(location: 0, length: range.location),
                    with: String(repeating: "\u{200B}", count: range.location)
                )
            }
            let suffixLocation = range.location + range.length
            if suffixLocation < masked.length {
                masked.mutableString.replaceCharacters(
                    in: NSRange(
                        location: suffixLocation,
                        length: masked.length - suffixLocation
                    ),
                    with: String(
                        repeating: "\u{200B}",
                        count: masked.length - suffixLocation
                    )
                )
            }
            label.attributedStringValue = masked
        }
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
            label.frame = previousFrame
            label.attributedStringValue = previousAttributedString
        }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(
            x: 0,
            y: 0,
            width: pixelsWide,
            height: pixelsHigh
        ))
        context.cgContext.saveGState()
        context.cgContext.scaleBy(x: rasterScale, y: rasterScale)
        cell.drawInterior(withFrame: label.bounds, in: label)
        context.cgContext.restoreGState()
        context.flushGraphics()

        var minimumX = pixelsWide
        var minimumY = pixelsHigh
        var maximumX = -1
        var maximumY = -1
        for y in 0..<pixelsHigh {
            let row = y * bitmap.bytesPerRow
            for x in 0..<pixelsWide {
                let alpha = bitmapData[row + x * 4 + 3]
                guard alpha > 12 else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else {
            return nil
        }

        let x = CGFloat(minimumX) / rasterScale
        let width = CGFloat(maximumX - minimumX + 1) / rasterScale
        let height = CGFloat(maximumY - minimumY + 1) / rasterScale
        let y = label.isFlipped
            ? frameSize.height - CGFloat(maximumY + 1) / rasterScale
            : CGFloat(minimumY) / rasterScale
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Maps the measured primary ink into the supplied status-item/card
    /// coordinate space. `frames.text` still includes the anti-clipping slack;
    /// only the returned bounds represent visible glyph ink.
    static func singleLinePrimaryInkBounds(
        for label: NSTextField,
        frames: MenuBarLayoutFrames,
        geometry: MenuBarGeometry,
        in backgroundBounds: NSRect
    ) -> NSRect? {
        guard geometry.secondaryHeight == 0,
              let localBounds = appKitRenderedTextBounds(
            for: label,
            frameSize: NSSize(width: frames.text.width, height: geometry.primaryHeight)
        ) else {
            return nil
        }
        let contentOrigin = NSPoint(
            x: backgroundBounds.minX + frames.content.minX,
            y: backgroundBounds.minY + frames.content.minY
        )
        return localBounds.offsetBy(
            dx: contentOrigin.x + frames.text.minX,
            dy: contentOrigin.y + frames.text.minY
        )
    }

    /// Establishes the primary-ink X anchor from the widest preset while the
    /// current mode's icon visibility and amount remain unchanged. The
    /// existing optical correction is retained as the final translation; no
    /// new single-line-specific screen constant is introduced.
    static func singleLinePrimaryAnchorX(
        backgroundBounds: NSRect,
        primaryText: String,
        showIcon: Bool,
        isBalance: Bool
    ) -> CGFloat {
        let referencePreset = MenuBarFontSizePreset.allCases.max {
            $0.primarySize < $1.primarySize
        } ?? .large
        let referenceLabel = NSTextField(labelWithString: primaryText)
        referenceLabel.font = primaryFont(size: CGFloat(referencePreset.primarySize))
        applyPrimaryText(primaryText, to: referenceLabel)
        let referenceGeometry = geometry(
            primarySize: referenceLabel.intrinsicContentSize,
            secondarySize: .zero,
            showIcon: showIcon,
            showAmount: true,
            hasSecondary: false,
            isBalance: isBalance
        )
        let referenceFrames = frames(
            buttonSize: backgroundBounds.size,
            geometry: referenceGeometry,
            iconViewYOffset: showIcon && isBalance ? singleLineIconYOffset : 0
        )
        guard let referenceInk = singleLinePrimaryInkBounds(
            for: referenceLabel,
            frames: referenceFrames,
            geometry: referenceGeometry,
            in: backgroundBounds
        ) else {
            return backgroundBounds.midX + menuBarOpticalCenterNudgeX
        }
        return referenceInk.midX + menuBarOpticalCenterNudgeX
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
        centerVisibleUnionOnBackground: Bool = false
    ) -> CGFloat {
        guard geometry.iconWidth > 0 || geometry.textWidth > 0 else {
            return 0
        }

        let baseFrames = frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0
        )
        let adjustedFrames = frames(
            buttonSize: backgroundBounds.size,
            geometry: geometry,
            iconViewYOffset: 0,
            iconOffset: NSSize(width: iconOffsetX, height: 0),
            textOffset: NSSize(width: textOffsetX, height: 0)
        )
        let baseBounds = visibleContentBounds(
            for: baseFrames,
            in: backgroundBounds
        )
        let adjustedBounds = visibleContentBounds(
            for: adjustedFrames,
            in: backgroundBounds
        )
        guard let baseBounds, let adjustedBounds else {
            return 0
        }
        let opticalCenterNudgeX = geometry.iconWidth > 0 && geometry.textWidth == 0
            ? menuBarIconOnlyOpticalCenterNudgeX
            : menuBarOpticalCenterNudgeX
        let targetCenter = centerVisibleUnionOnBackground
            ? backgroundBounds.midX
            : baseBounds.midX
        return targetCenter
            + opticalCenterNudgeX
            - adjustedBounds.midX
    }
}
