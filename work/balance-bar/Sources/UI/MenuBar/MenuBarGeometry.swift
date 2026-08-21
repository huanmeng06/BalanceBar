import AppKit

struct MenuBarGeometry {
    let iconWidth: CGFloat
    let gap: CGFloat
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
        textWidth = showAmount
            ? ceil(max(primarySize.width, secondarySize.width)) + textWidthSlack
            : 0
        primaryHeight = showAmount ? ceil(primarySize.height) : 0
        secondaryHeight = hasSecondary ? ceil(secondarySize.height) : 0
        textHeight = primaryHeight + (hasSecondary ? textRowSpacing + secondaryHeight : 0)
        contentWidth = iconWidth + gap + textWidth
        contentHeight = isBalance && showAmount
            ? singleLineHeight
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

enum MenuBarLayout {
    static let primaryFont = NSFont.monospacedDigitSystemFont(
        ofSize: 13,
        weight: .semibold
    )
    static let secondaryFont = NSFont.monospacedDigitSystemFont(
        ofSize: 10,
        weight: .medium
    )
    static let iconSlotWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 6
    static let textRowSpacing: CGFloat = -2
    static let textWidthSlack: CGFloat = 5

    // Fixed API single-line baseline. Keep these independent from the
    // official two-line layout so provider switches cannot alter the result.
    static let singleLineHeight: CGFloat = 18
    static let singleLineTextYOffset: CGFloat = 0.25
    static let singleLineIconYOffset: CGFloat = 0.25

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
            x: iconOffset.width,
            y: iconViewYOffset + iconOffset.height,
            width: iconSlot.width,
            height: iconSlot.height
        )
        let text = NSRect(
            x: geometry.iconWidth + geometry.gap + textOffset.width,
            y: floor(max(0, (geometry.contentHeight - geometry.textHeight) / 2)) - textOffset.height,
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
}
