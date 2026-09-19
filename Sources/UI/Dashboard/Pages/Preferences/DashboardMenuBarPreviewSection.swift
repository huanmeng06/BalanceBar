import AppKit
import QuartzCore

final class DashboardMenuBarPageActionTarget: NSObject {
    var onRevealIconDisplayModeSetting: (() -> Void)?

    @objc func revealIconDisplayModeSetting(_ sender: Any?) {
        onRevealIconDisplayModeSetting?()
    }
}

/// Lets the native settings row place the fixed-size preview below its labels
/// when the Menu Bar page is narrow. The preview itself remains the same
/// custom AppKit surface and keeps its existing 42pt visual height.
private final class MenuBarPreviewAccessoryHost: NSView, DashboardSettingsRowControlLayout {
    let allowsTextDrivenDedicatedRow = true
    let minimumInlineLabelWidth: CGFloat = 320
    let preview: NSView

    init(preview: NSView) {
        self.preview = preview
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var stacksControlsVertically: Bool { false }

    func updateAvailableRowWidth(_ width: CGFloat) {
        _ = width
    }

    var naturalAccessoryWidth: CGFloat {
        let width = preview.fittingSize.width
        return width.isFinite && width > 0 ? width : 190
    }

    override var intrinsicContentSize: NSSize {
        let size = preview.fittingSize
        return NSSize(
            width: naturalAccessoryWidth,
            height: size.height.isFinite && size.height > 0 ? size.height : 42
        )
    }
}

/// Live preview, status-item visibility, and overflow/runtime warnings.
final class DashboardMenuBarPreviewSection {
    private struct WarningRefreshSignature: Equatable {
        let hiddenByMenuBarSpace: Bool
        let hiddenByRuntimePolicy: Bool
        let language: String
    }

    private(set) var warningRefreshCountForTesting = 0
    private(set) var previewCardLayoutCountForTesting = 0
    var animationFrameRate = MenuBarAnimationTiming.defaultFrameRate

    private let previewIcon = PassthroughImageView()
    private let previewIconSlot = NSView()
    private let previewAnimatedIconHost = MenuBarNativeAnimatedIconHostView(frame: .zero)
    private let previewClaudeAnimatedIconHost = MenuBarClaudeAnimatedIconHostView(frame: .zero)
    private let previewText = MenuBarTextView()
    private let previewPrimary = NSTextField(labelWithString: "…")
    private let previewSecondary = NSTextField(labelWithString: "")
    private let previewCapsule = NSView()
    private weak var previewBackground: NSView?
    private weak var overflowWarningLabel: NSTextField?
    private weak var overflowWarningSettingsButton: NSButton?
    private weak var overflowWarningRow: NSView?
    private weak var runtimeOnlyWarningLabel: NSTextField?
    private weak var runtimeOnlyWarningSettingsButton: NSButton?
    private weak var runtimeOnlyWarningRow: NSView?
    private var previewSeparators: [NSView] = []
    private weak var previewSection: SettingsSectionView?
    private var capsuleLeadingConstraint: NSLayoutConstraint?
    private var capsuleTrailingConstraint: NSLayoutConstraint?
    private var previewWidthConstraint: NSLayoutConstraint?
    private var textWidthConstraint: NSLayoutConstraint?
    private var previewIconWidthConstraint: NSLayoutConstraint?
    private var previewIconHeightConstraint: NSLayoutConstraint?
    private var previewIconSlotWidthConstraint: NSLayoutConstraint?
    private var previewIconSlotHeightConstraint: NSLayoutConstraint?
    private weak var iconDisplayModeControl: NSPopUpButton?
    private weak var iconDisplayDelayControl: NSPopUpButton?
    private weak var iconDisplayModeRow: NSView?
    private weak var iconDisplayDelayRow: NSView?
    private var lastWarningRefreshSignature: WarningRefreshSignature?
    private var isBuilt = false
    private var previewAnimationActive = false
    private var previewAnimationKind: MenuBarCompositorAnimationKind = .none
    private var lastPreviewIconImage: NSImage?
    private var lastPreviewSpriteImage: NSImage?
    private let pageActionTarget = DashboardMenuBarPageActionTarget()
    private let chromeInset: CGFloat = 10

    var previewAnimationHostForTesting: MenuBarNativeAnimatedIconHostView {
        previewAnimatedIconHost
    }

    var previewClaudeAnimationHostForTesting: MenuBarClaudeAnimatedIconHostView {
        previewClaudeAnimatedIconHost
    }

    var previewIconBounds: NSRect { previewIcon.bounds }
    var previewIconBackingScale: CGFloat {
        previewIcon.window?.backingScaleFactor ?? 2
    }
    var previewIconAppearanceName: String {
        previewIcon.effectiveAppearance.name.rawValue
    }

    deinit {
        removeIconDisplayModeRevealHighlight()
    }

    func resetWarningSignature() {
        lastWarningRefreshSignature = nil
    }

    func teardown() {
        removeIconDisplayModeRevealHighlight()
        previewAnimationActive = false
        previewAnimationKind = .none
        previewAnimatedIconHost.removeRotationAnimation()
        previewAnimatedIconHost.isHidden = true
        previewAnimatedIconHost.removeFromSuperview()
        previewClaudeAnimatedIconHost.removeThinkingAnimation()
        previewClaudeAnimatedIconHost.isHidden = true
        previewClaudeAnimatedIconHost.removeFromSuperview()
        lastPreviewSpriteImage = nil
        lastWarningRefreshSignature = nil
        pageActionTarget.onRevealIconDisplayModeSetting = nil
    }

    func prepare(input: DashboardMenuBarPage.Input) {
        previewAnimationActive = input.animationKind != .none
        previewAnimationKind = input.animationKind
        lastPreviewIconImage = Self.displayedPreviewIconImage(
            animationKind: input.animationKind,
            iconImage: input.iconImage,
            animationIconImage: input.animationIconImage
        )
        lastPreviewSpriteImage = input.animationSpriteImage
        previewAnimatedIconHost.removeFromSuperview()
        previewAnimatedIconHost.removeRotationAnimation()
        previewAnimatedIconHost.isHidden = true
        previewClaudeAnimatedIconHost.removeFromSuperview()
        previewClaudeAnimatedIconHost.removeThinkingAnimation()
        previewClaudeAnimatedIconHost.isHidden = true
        pageActionTarget.onRevealIconDisplayModeSetting = { [weak self] in
            self?.revealIconDisplayModeSetting()
        }
    }

    func make(input: DashboardMenuBarPage.Input) -> NSView {
        prepare(input: input)
        previewSeparators = []
        previewSection = nil
        lastWarningRefreshSignature = nil

        let previewContent = NSView()
        let preview: NSView
        if let glassPreview = makeDashboardGlassEffectView(contentView: previewContent, cornerRadius: 7) {
            preview = glassPreview
        } else {
            let visualEffectPreview = NSVisualEffectView()
            visualEffectPreview.material = .menu
            visualEffectPreview.state = .active
            visualEffectPreview.wantsLayer = true
            visualEffectPreview.layer?.cornerRadius = 7
            visualEffectPreview.layer?.backgroundColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.64),
                dark: NSColor.black.withAlphaComponent(0.18)
            ).cgColor
            visualEffectPreview.layer?.borderColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.72),
                dark: NSColor.white.withAlphaComponent(0.08)
            ).cgColor
            visualEffectPreview.layer?.borderWidth = 0.5
            previewContent.translatesAutoresizingMaskIntoConstraints = false
            visualEffectPreview.addSubview(previewContent)
            NSLayoutConstraint.activate([
                previewContent.topAnchor.constraint(equalTo: visualEffectPreview.topAnchor),
                previewContent.leadingAnchor.constraint(equalTo: visualEffectPreview.leadingAnchor),
                previewContent.trailingAnchor.constraint(equalTo: visualEffectPreview.trailingAnchor),
                previewContent.bottomAnchor.constraint(equalTo: visualEffectPreview.bottomAnchor)
            ])
            preview = visualEffectPreview
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewWidthConstraint = preview.widthAnchor.constraint(equalToConstant: 190)
        previewWidthConstraint.isActive = true
        self.previewBackground = preview
        self.previewWidthConstraint = previewWidthConstraint
        previewIcon.imageScaling = .scaleProportionallyDown
        previewIcon.translatesAutoresizingMaskIntoConstraints = false
        previewIcon.wantsLayer = true
        previewIcon.identifier = NSUserInterfaceItemIdentifier("menuBarPreviewIcon")
        let initialIconSize = input.preferences.menuBarIconSize
        let previewIconWidth = previewIcon.widthAnchor.constraint(equalToConstant: initialIconSize)
        let previewIconHeight = previewIcon.heightAnchor.constraint(equalToConstant: initialIconSize)
        previewIconWidth.isActive = true
        previewIconHeight.isActive = true
        previewIconWidthConstraint = previewIconWidth
        previewIconHeightConstraint = previewIconHeight
        previewPrimary.font = MenuBarLayout.primaryFont
        previewPrimary.textColor = .labelColor
        previewPrimary.identifier = NSUserInterfaceItemIdentifier(DashboardMenuBarPage.previewPrimaryIdentifier)
        previewSecondary.font = MenuBarLayout.secondaryFont
        previewSecondary.textColor = .labelColor
        previewSecondary.identifier = NSUserInterfaceItemIdentifier(DashboardMenuBarPage.previewSecondaryIdentifier)
        previewText.addSubview(previewPrimary)
        previewText.addSubview(previewSecondary)
        previewText.wantsLayer = true
        previewText.identifier = NSUserInterfaceItemIdentifier("menuBarPreviewText")
        previewText.layer?.setAffineTransform(.identity)
        let previewTextWidth = previewText.widthAnchor.constraint(equalToConstant: 32)
        previewTextWidth.priority = .defaultHigh
        previewTextWidth.isActive = true
        textWidthConstraint = previewTextWidth
        previewIconSlot.translatesAutoresizingMaskIntoConstraints = false
        let previewIconSlotWidth = previewIconSlot.widthAnchor.constraint(equalToConstant: initialIconSize)
        let previewIconSlotHeight = previewIconSlot.heightAnchor.constraint(equalToConstant: initialIconSize)
        previewIconSlotWidth.isActive = true
        previewIconSlotHeight.isActive = true
        previewIconSlotWidthConstraint = previewIconSlotWidth
        previewIconSlotHeightConstraint = previewIconSlotHeight
        previewIconSlot.addSubview(previewIcon)
        NSLayoutConstraint.activate([
            previewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            previewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor)
        ])
        previewAnimatedIconHost.isHidden = true
        previewIconSlot.addSubview(previewAnimatedIconHost)
        previewClaudeAnimatedIconHost.isHidden = true
        previewIconSlot.addSubview(previewClaudeAnimatedIconHost)
        let previewRow = NSStackView(views: [previewIconSlot, previewText])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = MenuBarLayout.iconTextSpacing
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        previewCapsule.wantsLayer = true
        previewCapsule.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.08),
            dark: NSColor.white.withAlphaComponent(0.12)
        ).cgColor
        previewCapsule.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.08)
        ).cgColor
        previewCapsule.layer?.borderWidth = 0.5
        previewCapsule.layer?.cornerRadius = 12
        previewCapsule.layer?.masksToBounds = true
        previewCapsule.isHidden = true
        previewCapsule.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(previewCapsule)
        previewContent.addSubview(previewRow)
        let initialCapsuleInset = Self.previewCapsuleHorizontalInset(
            horizontalPadding: input.preferences.menuBarHorizontalPadding,
            widthAdjustment: input.preferences.menuBarStatusItemWidthAdjustment
                + AppPreferences.menuBarStatusItemWidthBaseline,
            additionalWidth: MenuBarLayout.menuBarStatusItemVisualOverhangX * 2
        )
        let capsuleLeading = previewCapsule.leadingAnchor.constraint(
            equalTo: previewRow.leadingAnchor,
            constant: -initialCapsuleInset
        )
        let capsuleTrailing = previewCapsule.trailingAnchor.constraint(
            equalTo: previewRow.trailingAnchor,
            constant: initialCapsuleInset
        )
        capsuleLeadingConstraint = capsuleLeading
        capsuleTrailingConstraint = capsuleTrailing
        NSLayoutConstraint.activate([
            previewRow.centerXAnchor.constraint(equalTo: previewContent.centerXAnchor),
            previewRow.centerYAnchor.constraint(equalTo: previewContent.centerYAnchor),
            previewRow.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 14),
            previewRow.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -14),
            capsuleLeading,
            capsuleTrailing,
            previewCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 6),
            previewCapsule.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -6),
            previewCapsule.topAnchor.constraint(equalTo: previewRow.topAnchor, constant: -3),
            previewCapsule.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor, constant: 3),
            preview.heightAnchor.constraint(equalToConstant: 42)
        ])
        let iconDisplayModeControl = makeIconDisplayModeControl(
            value: input.preferences.menuBarIconDisplayMode,
            relay: input.relay
        )
        self.iconDisplayModeControl = iconDisplayModeControl
        let iconDisplayDelayControl = makeIconDisplayDelayControl(
            value: input.preferences.menuBarIconDisplayDelay,
            relay: input.relay
        )
        self.iconDisplayDelayControl = iconDisplayDelayControl
        let overflowWarningLabel = NSTextField(
            wrappingLabelWithString: DashboardMenuBarPage.overflowWarningText()
        )
        overflowWarningLabel.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.overflowWarningIdentifier
        )
        overflowWarningLabel.font = .systemFont(ofSize: 12)
        overflowWarningLabel.textColor = .secondaryLabelColor
        overflowWarningLabel.lineBreakMode = .byWordWrapping
        overflowWarningLabel.usesSingleLineMode = false
        overflowWarningLabel.maximumNumberOfLines = 0
        overflowWarningLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let overflowWarningSettingsButton = NSButton(
            title: DashboardMenuBarPage.overflowWarningSettingsButtonText(),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.openSystemMenuBarSettings(_:))
        )
        overflowWarningSettingsButton.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.overflowWarningSettingsButtonIdentifier
        )
        overflowWarningSettingsButton.bezelStyle = .rounded
        overflowWarningSettingsButton.controlSize = .regular
        overflowWarningSettingsButton.toolTip = DashboardMenuBarPage.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton.setAccessibilityLabel(
            DashboardMenuBarPage.overflowWarningSettingsButtonText()
        )
        overflowWarningSettingsButton.setContentHuggingPriority(.required, for: .horizontal)
        overflowWarningSettingsButton.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        let overflowWarningRow = Self.makeOverflowWarningRow(
            label: overflowWarningLabel,
            settingsButton: overflowWarningSettingsButton
        )
        let runtimeOnlyWarningLabel = NSTextField(
            wrappingLabelWithString: DashboardMenuBarPage.runtimeOnlyWarningText()
        )
        runtimeOnlyWarningLabel.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.runtimeOnlyWarningIdentifier
        )
        runtimeOnlyWarningLabel.font = .systemFont(ofSize: 12)
        runtimeOnlyWarningLabel.textColor = .secondaryLabelColor
        runtimeOnlyWarningLabel.lineBreakMode = .byWordWrapping
        runtimeOnlyWarningLabel.usesSingleLineMode = false
        runtimeOnlyWarningLabel.maximumNumberOfLines = 0
        runtimeOnlyWarningLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let runtimeOnlyWarningSettingsButton = NSButton(
            title: DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonText(),
            target: pageActionTarget,
            action: #selector(DashboardMenuBarPageActionTarget.revealIconDisplayModeSetting(_:))
        )
        runtimeOnlyWarningSettingsButton.identifier = NSUserInterfaceItemIdentifier(
            DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonIdentifier
        )
        runtimeOnlyWarningSettingsButton.bezelStyle = .rounded
        runtimeOnlyWarningSettingsButton.controlSize = .regular
        runtimeOnlyWarningSettingsButton.toolTip = DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonText()
        runtimeOnlyWarningSettingsButton.setAccessibilityLabel(
            DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonText()
        )
        runtimeOnlyWarningSettingsButton.setContentHuggingPriority(.required, for: .horizontal)
        runtimeOnlyWarningSettingsButton.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        let runtimeOnlyWarningRow = Self.makeWarningRow(
            label: runtimeOnlyWarningLabel,
            settingsButton: runtimeOnlyWarningSettingsButton,
            identifier: DashboardMenuBarPage.runtimeOnlyWarningRowIdentifier
        )
        overflowWarningRow.isHidden = !input.statusItemVisibility.isHiddenByMenuBarSpace
        runtimeOnlyWarningRow.isHidden = !input.statusItemVisibility.isHiddenByRuntimePolicy
        self.overflowWarningLabel = overflowWarningLabel
        self.overflowWarningSettingsButton = overflowWarningSettingsButton
        self.overflowWarningRow = overflowWarningRow
        self.runtimeOnlyWarningLabel = runtimeOnlyWarningLabel
        self.runtimeOnlyWarningSettingsButton = runtimeOnlyWarningSettingsButton
        self.runtimeOnlyWarningRow = runtimeOnlyWarningRow
        let iconDisplayModeRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageIconDisplayMode),
            detail: tr(.keyDashboardMenuBarPageIconDisplayModeDescription),
            accessoryView: iconDisplayModeControl
        )
        self.iconDisplayModeRow = iconDisplayModeRow
        let iconDisplayDelayRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageIconDisplayDelay),
            detail: tr(.keyDashboardMenuBarPageIconDisplayDelayDescription),
            accessoryView: iconDisplayDelayControl
        )
        iconDisplayDelayRow.isHidden = input.preferences.menuBarIconDisplayMode != .onlyWhileRunning
        self.iconDisplayDelayRow = iconDisplayDelayRow
        let previewAccessory = MenuBarPreviewAccessoryHost(preview: preview)
        let previewSettingsRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageCurrentLayout),
            detail: tr(.keyDashboardMenuBarPageTheMenuBarUpdatesWithProviderDataInRealTime),
            accessoryView: previewAccessory,
            minimumHeight: DashboardMenuBarPage.previewRowHeight,
            verticalPadding: DashboardMenuBarPage.previewRowVerticalPadding
        )
        let previewSection = SettingsSectionView(
            title: tr(.keyDashboardMenuBarPagePreview),
            contentViews: [
                previewSettingsRow,
                iconDisplayModeRow,
                iconDisplayDelayRow,
                overflowWarningRow,
                runtimeOnlyWarningRow
            ]
        )
        self.previewSection = previewSection
        self.previewSeparators = previewSection.separators
        isBuilt = true
        return previewSection
    }

    func updateDelayVisibility(showDelay: Bool) {
        iconDisplayDelayRow?.isHidden = !showDelay
        updatePreviewSeparators()
    }

    func applyIconDisplayControls(
        mode: MenuBarIconDisplayMode,
        delay: MenuBarIconDisplayDelay
    ) {
        if let iconDisplayModeControl,
           let selectedIndex = MenuBarIconDisplayMode.allCases.firstIndex(of: mode) {
            if iconDisplayModeControl.indexOfSelectedItem != selectedIndex {
                iconDisplayModeControl.selectItem(at: selectedIndex)
            }
            iconDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
        if let iconDisplayDelayControl,
           let selectedIndex = MenuBarIconDisplayDelay.allCases.firstIndex(of: delay) {
            if iconDisplayDelayControl.indexOfSelectedItem != selectedIndex {
                iconDisplayDelayControl.selectItem(at: selectedIndex)
            }
            iconDisplayDelayControl.synchronizeTitleAndSelectedItem()
        }
    }

    func applyCapsuleWidth(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        let capsuleInset = Self.previewCapsuleHorizontalInset(
            horizontalPadding: horizontalPadding,
            widthAdjustment: widthAdjustment + AppPreferences.menuBarStatusItemWidthBaseline,
            additionalWidth: MenuBarLayout.menuBarStatusItemVisualOverhangX * 2
        )
        capsuleLeadingConstraint?.constant = -capsuleInset
        capsuleTrailingConstraint?.constant = capsuleInset
    }

    func refreshVisuals(
        preferences: AppPreferences,
        presentation: DashboardMenuBarPage.Presentation,
        iconImage: NSImage?,
        animationIconImage: NSImage?,
        animationKind: MenuBarCompositorAnimationKind,
        animationSpriteImage: NSImage?
    ) {
        previewText.isHidden = !preferences.showMenuBarAmount
        let fontSizePreset = preferences.menuBarFontSizePreset
        let iconSizePreset = preferences.menuBarIconSizePreset
        let iconSize = iconSizePreset.pointSize
        applyPreviewIconSize(iconSize)
        let fontSize = fontSizePreset.primarySize
        let secondaryFontSize = fontSizePreset.secondarySize
        let primaryFont = MenuBarLayout.primaryFont(
            size: CGFloat(fontSize)
        )
        if previewPrimary.font != primaryFont {
            previewPrimary.font = primaryFont
        }
        let secondaryFont = MenuBarLayout.secondaryFont(
            size: CGFloat(secondaryFontSize)
        )
        if previewSecondary.font != secondaryFont {
            previewSecondary.font = secondaryFont
        }
        MenuBarLayout.applyPrimaryText(presentation.primary, to: previewPrimary)
        if previewSecondary.stringValue != presentation.secondary {
            previewSecondary.stringValue = presentation.secondary
        }
        let hasSecondary = presentation.hasSecondary
        let geometry = MenuBarLayout.geometry(
            primarySize: previewPrimary.intrinsicContentSize,
            secondarySize: previewSecondary.intrinsicContentSize,
            showIcon: preferences.showMenuBarIcon,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: presentation.isBalance,
            iconSlotWidth: iconSize
        )
        MenuBarLayout.applyTextLayout(
            container: previewText,
            primary: previewPrimary,
            secondary: previewSecondary,
            geometry: geometry,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary
        )
        if textWidthConstraint?.constant != geometry.textWidth {
            textWidthConstraint?.constant = geometry.textWidth
        }
        let displayedPreviewIcon = Self.displayedPreviewIconImage(
            animationKind: animationKind,
            iconImage: iconImage,
            animationIconImage: animationIconImage
        )
        lastPreviewIconImage = displayedPreviewIcon
        if let animationSpriteImage {
            lastPreviewSpriteImage = animationSpriteImage
        }
        if previewIcon.image !== displayedPreviewIcon {
            previewIcon.image = displayedPreviewIcon
        }
        previewIcon.contentTintColor = .labelColor
        let iconOffsetX = preferences.menuBarIconOffsetX
        let iconOffsetY = preferences.menuBarIconOffsetY
        let amountOffsetX = preferences.menuBarAmountOffsetX
        let amountOffsetY = preferences.menuBarAmountOffsetY
        let iconVisualX = CGFloat(iconOffsetX)
        let iconVisualY = CGFloat(iconOffsetY)
        let amountVisualX = CGFloat(amountOffsetX)
        let amountVisualY = CGFloat(amountOffsetY)
        let officialTextYOffset: CGFloat
        if presentation.isOfficial, preferences.showMenuBarAmount {
            officialTextYOffset = MenuBarLayout.officialTextYOffset(
                hasSecondary: presentation.hasSecondary
            )
        } else {
            officialTextYOffset = 0
        }
        let previewBackgroundBounds = resolvedPreviewBackgroundBounds(
            fallbackWidth: geometry.contentWidth
                + (preferences.menuBarHorizontalPadding + chromeInset) * 2
        )
        let singleLineBackgroundBounds = previewBackgroundBounds.height > 0
            ? previewBackgroundBounds
            : NSRect(
                x: previewBackgroundBounds.minX,
                y: previewBackgroundBounds.minY,
                width: previewBackgroundBounds.width,
                height: 42
            )
        let isSingleLinePrimaryAnchorMode = preferences.showMenuBarAmount
            && !hasSecondary
            && (presentation.isOfficial || presentation.isBalance)
        let horizontalCenteringCompensation = isSingleLinePrimaryAnchorMode
            ? 0
            : MenuBarLayout.horizontalCenteringCompensation(
                backgroundBounds: previewBackgroundBounds,
                geometry: geometry,
                iconOffsetX: iconVisualX,
                textOffsetX: amountVisualX,
                centerVisibleUnionOnBackground: hasSecondary
            )
        previewIcon.layer?.setAffineTransform(.identity)
        previewText.layer?.setAffineTransform(.identity)
        if isSingleLinePrimaryAnchorMode {
            let iconTranslationY: CGFloat
            let textTranslationY: CGFloat
            if presentation.isBalance,
               preferences.showMenuBarIcon,
               preferences.showMenuBarAmount {
                iconTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: iconVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLineIconYOffset,
                    in: .unflippedLayer
                )
                textTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLineTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: DashboardMenuBarPage.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            } else {
                iconTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: iconVisualY,
                    in: .unflippedLayer
                )
                textTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: officialTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: DashboardMenuBarPage.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            }
            let userAmountTranslationY = MenuBarOffsetLayout.yDelta(
                visualY: amountVisualY,
                in: .unflippedLayer
            )
            let zeroUserTextTranslationY = textTranslationY - userAmountTranslationY
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX),
                y: iconTranslationY
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX),
                y: zeroUserTextTranslationY
            ))
            previewBackground?.layoutSubtreeIfNeeded()

            var horizontalCorrection: CGFloat = 0
            var verticalCorrection: CGFloat = 0
            if let previewBackground,
               previewBackground.bounds.width > 0,
               previewBackground.bounds.height > 0,
               let primaryInk = previewPrimaryInkBounds(in: previewBackground) {
                let targetX = MenuBarLayout.singleLinePrimaryAnchorX(
                    backgroundBounds: singleLineBackgroundBounds,
                    primaryText: presentation.primary,
                    showIcon: preferences.showMenuBarIcon,
                    isBalance: presentation.isBalance,
                    iconSlotWidth: iconSize
                )
                horizontalCorrection = targetX - primaryInk.midX
                let automaticAmountTranslationY = MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLinePrimaryAutomaticYOffset(
                        fontSize: CGFloat(fontSize)
                    ),
                    in: .unflippedLayer
                )
                let targetY = singleLineBackgroundBounds.midY
                    + userAmountTranslationY
                    + automaticAmountTranslationY
                verticalCorrection = targetY - primaryInk.midY
            }
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX)
                    + horizontalCorrection,
                y: iconTranslationY
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX)
                    + horizontalCorrection,
                y: zeroUserTextTranslationY + verticalCorrection
            ))
        } else if presentation.isBalance, preferences.showMenuBarIcon, preferences.showMenuBarAmount {
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX)
                    + horizontalCenteringCompensation,
                y: MenuBarOffsetLayout.yDelta(visualY: iconVisualY, in: .unflippedLayer)
                    + MenuBarOffsetLayout.yDelta(
                        visualY: MenuBarLayout.singleLineIconYOffset,
                        in: .unflippedLayer
                    )
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX)
                    + horizontalCenteringCompensation,
                // User Y offsets use unflipped layer semantics (positive = up)
                // to match the real menu bar; the built-in single-line baseline
                // keeps its existing visual unchanged.
                y: MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: MenuBarLayout.singleLineTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: DashboardMenuBarPage.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            ))
        } else {
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: iconVisualX)
                    + horizontalCenteringCompensation,
                y: MenuBarOffsetLayout.yDelta(visualY: iconVisualY, in: .unflippedLayer)
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: MenuBarOffsetLayout.xDelta(visualX: amountVisualX)
                    + horizontalCenteringCompensation,
                y: MenuBarOffsetLayout.yDelta(
                    visualY: amountVisualY,
                    in: .unflippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: officialTextYOffset,
                    in: .flippedLayer
                ) + MenuBarOffsetLayout.yDelta(
                    visualY: DashboardMenuBarPage.previewAmountDefaultYOffset,
                    in: .unflippedLayer
                )
            ))
        }
        updatePreviewAnimation(
            kind: animationKind,
            iconImage: displayedPreviewIcon,
            spriteImage: animationSpriteImage
        )
    }

    func updatePreviewIcon(_ image: NSImage?) {
        guard isBuilt else { return }
        guard previewAnimationKind == .none else { return }
        lastPreviewIconImage = image
        guard previewIcon.image !== image else { return }
        previewIcon.image = image
    }

    /// Mirrors the native status-item compositor state into the already-visible
    /// Dashboard preview. Each animation kind owns a separate in-window host;
    /// no preview frame callback is needed.
    func updatePreviewAnimation(
        kind: MenuBarCompositorAnimationKind,
        iconImage: NSImage?,
        spriteImage: NSImage?
    ) {
        previewAnimationKind = kind
        previewAnimationActive = kind != .none
        if let iconImage {
            lastPreviewIconImage = iconImage
        }
        if let spriteImage {
            lastPreviewSpriteImage = spriteImage
        } else if kind != .claudeThinking, kind != .grokThinking, kind != .grokThinkingBitmap {
            lastPreviewSpriteImage = nil
        }
        guard isBuilt else { return }

        let staticImage = lastPreviewIconImage
        guard kind != .none,
              !previewIconSlot.isHidden,
              let iconImage = iconImage ?? staticImage,
              previewIcon.bounds.width > 0,
              previewIcon.bounds.height > 0 else {
            previewAnimatedIconHost.removeRotationAnimation()
            previewAnimatedIconHost.isHidden = true
            previewClaudeAnimatedIconHost.removeThinkingAnimation()
            previewClaudeAnimatedIconHost.isHidden = true
            if previewIcon.image !== staticImage {
                previewIcon.image = staticImage
            }
            return
        }

        previewIcon.image = nil
        let scale = max(previewIcon.window?.backingScaleFactor ?? 2, 1)
        switch kind {
        case .codexRotation:
            previewClaudeAnimatedIconHost.removeThinkingAnimation()
            previewClaudeAnimatedIconHost.isHidden = true
            previewAnimatedIconHost.updateGeometry(
                frame: previewIcon.frame,
                contentsScale: scale
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewAnimatedIconHost.layer?.setAffineTransform(
                previewIcon.layer?.affineTransform() ?? .identity
            )
            CATransaction.commit()
            guard previewAnimatedIconHost.updateContents(
                sourceImage: iconImage,
                appearance: previewIcon.effectiveAppearance,
                contentsScale: scale
            ) else {
                previewAnimatedIconHost.removeRotationAnimation()
                previewAnimatedIconHost.isHidden = true
                previewIcon.image = staticImage
                return
            }
            previewAnimatedIconHost.isHidden = false
            previewAnimatedIconHost.rotationDuration = MenuBarAnimationTiming.rotationDuration(
                fps: animationFrameRate
            )
            previewAnimatedIconHost.installRotationAnimation()
        case .claudeThinking, .grokThinking, .grokThinkingBitmap:
            previewAnimatedIconHost.removeRotationAnimation()
            previewAnimatedIconHost.isHidden = true
            previewClaudeAnimatedIconHost.timing = kind == .claudeThinking
                ? .claude
                : .grok(frameRate: animationFrameRate)
            guard let spriteImage = spriteImage ?? lastPreviewSpriteImage else {
                previewClaudeAnimatedIconHost.removeThinkingAnimation()
                previewClaudeAnimatedIconHost.isHidden = true
                previewIcon.image = staticImage
                return
            }
            previewClaudeAnimatedIconHost.updateGeometry(
                frame: previewIcon.frame,
                contentsScale: scale
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewClaudeAnimatedIconHost.layer?.setAffineTransform(
                previewIcon.layer?.affineTransform() ?? .identity
            )
            CATransaction.commit()
            let frameSize = NSSize(
                width: spriteImage.size.width,
                height: spriteImage.size.height
                    / CGFloat(previewClaudeAnimatedIconHost.timing.frameCount)
            )
            guard previewClaudeAnimatedIconHost.updateContents(
                spriteImage: spriteImage,
                frameSize: frameSize,
                appearance: previewIcon.effectiveAppearance,
                contentsScale: scale
            ) else {
                previewClaudeAnimatedIconHost.removeThinkingAnimation()
                previewClaudeAnimatedIconHost.isHidden = true
                previewIcon.image = staticImage
                return
            }
            previewClaudeAnimatedIconHost.isHidden = false
            previewClaudeAnimatedIconHost.installThinkingAnimation()
        case .none:
            break
        }
    }

    func updatePreviewAnimation(active: Bool, iconImage: NSImage?) {
        updatePreviewAnimation(
            kind: active ? .codexRotation : .none,
            iconImage: iconImage,
            spriteImage: nil
        )
    }

    /// Idle preview must use the live source icon. A leftover animation cache
    /// can still hold the previous client's bitmap after Grok/Claude thinking
    /// stops (Issue #332).
    private static func displayedPreviewIconImage(
        animationKind: MenuBarCompositorAnimationKind,
        iconImage: NSImage?,
        animationIconImage: NSImage?
    ) -> NSImage? {
        animationKind.isActive ? (animationIconImage ?? iconImage) : iconImage
    }

    private static func makeWarningRow(
        label: NSTextField,
        settingsButton: NSButton,
        identifier: String
    ) -> NSView {
        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier(identifier)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: DashboardMenuBarPage.previewRowHeight).isActive = true
        label.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: settingsButton.leadingAnchor,
                constant: -12
            ),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
            settingsButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            settingsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private static func makeOverflowWarningRow(
        label: NSTextField,
        settingsButton: NSButton
    ) -> NSView {
        makeWarningRow(
            label: label,
            settingsButton: settingsButton,
            identifier: DashboardMenuBarPage.overflowWarningRowIdentifier
        )
    }

    func updateWarnings(_ statusItemVisibility: StatusItemVisibility) {
        guard let overflowWarningLabel,
              let overflowWarningRow,
              let runtimeOnlyWarningLabel,
              let runtimeOnlyWarningRow else { return }
        let signature = WarningRefreshSignature(
            hiddenByMenuBarSpace: statusItemVisibility.isHiddenByMenuBarSpace,
            hiddenByRuntimePolicy: statusItemVisibility.isHiddenByRuntimePolicy,
            language: AppLanguage.resolved.rawValue
        )
        guard signature != lastWarningRefreshSignature else { return }
        lastWarningRefreshSignature = signature
        warningRefreshCountForTesting += 1
        let shouldShowOverflowWarning = statusItemVisibility.isHiddenByMenuBarSpace
        let shouldShowRuntimeOnlyWarning = statusItemVisibility.isHiddenByRuntimePolicy
        overflowWarningLabel.stringValue = DashboardMenuBarPage.overflowWarningText()
        overflowWarningSettingsButton?.title = DashboardMenuBarPage.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton?.toolTip = DashboardMenuBarPage.overflowWarningSettingsButtonText()
        overflowWarningSettingsButton?.setAccessibilityLabel(
            DashboardMenuBarPage.overflowWarningSettingsButtonText()
        )
        runtimeOnlyWarningLabel.stringValue = DashboardMenuBarPage.runtimeOnlyWarningText()
        runtimeOnlyWarningSettingsButton?.title = DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonText()
        runtimeOnlyWarningSettingsButton?.toolTip = DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonText()
        runtimeOnlyWarningSettingsButton?.setAccessibilityLabel(
            DashboardMenuBarPage.runtimeOnlyWarningSettingsButtonText()
        )
        overflowWarningLabel.isHidden = !shouldShowOverflowWarning
        overflowWarningRow.isHidden = !shouldShowOverflowWarning
        runtimeOnlyWarningLabel.isHidden = !shouldShowRuntimeOnlyWarning
        runtimeOnlyWarningRow.isHidden = !shouldShowRuntimeOnlyWarning
        updatePreviewSeparators()
    }

    func updatePreviewSeparators() {
        // Current layout and menu bar display stay visible. Delay follows
        // Only While Running; warnings come last:
        // current layout → menu bar display → delay → overflow → runtime.
        let visibleRows = [
            true,
            true,
            iconDisplayDelayRow?.isHidden == false,
            overflowWarningRow?.isHidden == false,
            runtimeOnlyWarningRow?.isHidden == false
        ]
        for (index, separator) in previewSeparators.enumerated() {
            guard index + 1 < visibleRows.count else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = visibleRows[(index + 1)...].contains(true)
            separator.isHidden = !(visibleRows[index] && hasVisibleRowAfter)
        }
        updatePreviewCardLayout()
    }

    private func updatePreviewCardLayout() {
        guard let previewSection else { return }
        previewCardLayoutCountForTesting += 1
        previewSection.cardView.invalidateHostedSettingsRowHeight()
        previewSection.invalidateIntrinsicContentSize()
        previewSection.needsLayout = true
        previewSection.superview?.invalidateIntrinsicContentSize()
        previewSection.superview?.needsLayout = true
    }

    func revealIconDisplayModeSetting() {
        guard let destination = iconDisplayModeRow else { return }
        destination.window?.layoutIfNeeded()

        // Expand the requested rect by the available viewport margin so that
        // scrollToVisible places the row with comfortable space around it
        // instead of stopping as soon as its bottom edge becomes visible.
        guard let scrollView = destination.enclosingScrollView else {
            destination.scrollToVisible(destination.bounds)
            return
        }
        let viewportHeight = scrollView.contentView.bounds.height
        let verticalMargin = max(0, (viewportHeight - destination.bounds.height) / 2)
        let revealRect = destination.bounds.insetBy(dx: 0, dy: -verticalMargin)
        destination.scrollToVisible(revealRect)
        flashIconDisplayModeRevealDestination(destination)
    }

    private func flashIconDisplayModeRevealDestination(_ destination: NSView) {
        destination.wantsLayer = true
        guard let layer = destination.layer else { return }
        let animationKey = DashboardMenuBarPage.iconDisplayModeRevealHighlightAnimationKey
        layer.removeAnimation(forKey: animationKey)

        let baseColor = layer.backgroundColor ?? NSColor.clear.cgColor
        let highlightColor = NSColor.controlAccentColor
            .withAlphaComponent(0.24)
            .cgColor
        let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
        animation.values = [baseColor, highlightColor, baseColor]
        animation.keyTimes = [0, 0.25, 1]
        animation.duration = DashboardMenuBarPage.iconDisplayModeRevealHighlightDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.backgroundColor = baseColor
        layer.add(animation, forKey: animationKey)
    }

    func removeIconDisplayModeRevealHighlight() {
        let animationKey = DashboardMenuBarPage.iconDisplayModeRevealHighlightAnimationKey
        iconDisplayModeRow?.layer?.removeAnimation(forKey: animationKey)
    }

    private func previewPrimaryInkBounds(in background: NSView) -> NSRect? {
        let frameSize = previewPrimary.bounds.size
        guard frameSize.width > 0, frameSize.height > 0,
              let localBounds = MenuBarLayout.appKitRenderedTextBounds(
                  for: previewPrimary,
                  frameSize: frameSize
              ) else {
            return nil
        }
        let baseBounds = previewPrimary.convert(localBounds, to: background)
        let textTransform = previewText.layer?.affineTransform() ?? .identity
        return baseBounds.offsetBy(dx: textTransform.tx, dy: textTransform.ty)
    }

    func resolvedPreviewBackgroundBounds(fallbackWidth: CGFloat) -> NSRect {
        if let previewBackground, previewBackground.bounds.width > 0 {
            return previewBackground.bounds
        }
        let width = max(
            0,
            previewWidthConstraint?.constant ?? fallbackWidth
        )
        let height = previewBackground?.bounds.height ?? 42
        return NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(0, height)
        )
    }

    private static func previewCapsuleHorizontalInset(
        horizontalPadding: CGFloat,
        widthAdjustment: Double,
        additionalWidth: CGFloat = 0
    ) -> CGFloat {
        horizontalPadding
            + 10
            + (CGFloat(widthAdjustment) / 2)
            + (max(0, additionalWidth) / 2)
    }

    private func applyPreviewIconSize(_ iconSize: CGFloat) {
        if previewIconWidthConstraint?.constant != iconSize {
            previewIconWidthConstraint?.constant = iconSize
        }
        if previewIconHeightConstraint?.constant != iconSize {
            previewIconHeightConstraint?.constant = iconSize
        }
        if previewIconSlotWidthConstraint?.constant != iconSize {
            previewIconSlotWidthConstraint?.constant = iconSize
        }
        if previewIconSlotHeightConstraint?.constant != iconSize {
            previewIconSlotHeightConstraint?.constant = iconSize
        }
    }

    private func makeIconDisplayModeControl(
        value: MenuBarIconDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.iconDisplayModeIdentifier,
            items: MenuBarIconDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.iconDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: MenuBarIconDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarIconDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageIconDisplayModeDescription)
        return control
    }

    private func makeIconDisplayDelayControl(
        value: MenuBarIconDisplayDelay,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.iconDisplayDelayIdentifier,
            items: MenuBarIconDisplayDelay.allCases.map { delay in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.iconDisplayDelayLabel(delay),
                    representedObject: delay.rawValue
                )
            },
            selectedIndex: MenuBarIconDisplayDelay.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarIconDisplayDelay(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageIconDisplayDelayDescription)
        return control
    }

    private static func iconDisplayModeLabel(
        _ mode: MenuBarIconDisplayMode
    ) -> String {
        switch mode {
        case .alwaysVisible:
            return tr(.keyDashboardMenuBarPageIconDisplayModeAlwaysVisible)
        case .onlyWhileRunning:
            return tr(.keyDashboardMenuBarPageIconDisplayModeOnlyWhileRunning)
        }
    }

    private static func iconDisplayDelayLabel(
        _ delay: MenuBarIconDisplayDelay
    ) -> String {
        switch delay {
        case .zeroSeconds:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayZeroSeconds)
        case .tenSeconds:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayTenSeconds)
        case .thirtySeconds:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayThirtySeconds)
        case .oneMinute:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayOneMinute)
        case .twoMinutes:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayTwoMinutes)
        case .threeMinutes:
            return tr(.keyDashboardMenuBarPageIconDisplayDelayThreeMinutes)
        }
    }
}
