import AppKit

final class DashboardMenuBarPage {
    static let iconOffsetsResetIdentifier = "menuBarIconOffsetsReset"
    static let amountOffsetsResetIdentifier = "menuBarAmountOffsetsReset"
    static let iconOffsetSummaryIdentifier = "menuBarIconOffsetSummary"
    static let amountOffsetSummaryIdentifier = "menuBarAmountOffsetSummary"

    struct Presentation: Equatable {
        let primary: String
        let secondary: String
        let hasSecondary: Bool
        let isBalance: Bool
    }

    static func presentation(
        for snapshot: Snapshot,
        showAmount: Bool,
        showReset: Bool,
        resolving snapshotResolver: (Snapshot) -> Snapshot
    ) -> Presentation {
        let effective = snapshotResolver(snapshot)
        let secondary = effective.kind == .official ? effective.menuBarSecondary : ""
        return Presentation(
            primary: showAmount ? effective.menuBarPrimary : "",
            secondary: secondary,
            hasSecondary: showAmount
                && showReset
                && effective.kind == .official
                && !secondary.isEmpty,
            isBalance: effective.kind == .balance
        )
    }

    struct Input {
        let preferences: AppPreferences
        let snapshot: Snapshot
        let menuBarSnapshot: (Snapshot) -> Snapshot
        let iconImage: NSImage?
        let relay: DashboardPreferencePageRelay
    }

    private let previewIcon = PassthroughImageView()
    private let previewIconSlot = NSView()
    private let previewText = MenuBarTextView()
    private let previewPrimary = NSTextField(labelWithString: "…")
    private let previewSecondary = NSTextField(labelWithString: "")
    private let previewCapsule = NSView()
    private weak var iconSwitch: NSSwitch?
    private weak var amountSwitch: NSSwitch?
    private var capsuleLeadingConstraint: NSLayoutConstraint?
    private var capsuleTrailingConstraint: NSLayoutConstraint?
    private var textWidthConstraint: NSLayoutConstraint?
    private var iconOffsetSummaryLabel: NSTextField?
    private var amountOffsetSummaryLabel: NSTextField?
    private var iconOffsetButtons: [NSButton] = []
    private var amountOffsetButtons: [NSButton] = []
    private let chromeInset: CGFloat = 10
    private var isBuilt = false

    func make(_ input: Input) -> NSView {
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
        preview.widthAnchor.constraint(equalToConstant: 190).isActive = true
        previewIcon.imageScaling = .scaleProportionallyDown
        previewIcon.translatesAutoresizingMaskIntoConstraints = false
        previewIcon.wantsLayer = true
        previewIcon.identifier = NSUserInterfaceItemIdentifier("menuBarPreviewIcon")
        previewIcon.widthAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIcon.heightAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewPrimary.font = MenuBarLayout.primaryFont
        previewPrimary.textColor = .labelColor
        previewSecondary.font = MenuBarLayout.secondaryFont
        previewSecondary.textColor = .labelColor
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
        previewIconSlot.widthAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIconSlot.heightAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIconSlot.addSubview(previewIcon)
        NSLayoutConstraint.activate([
            previewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            previewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor)
        ])
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
        let capsuleLeading = previewCapsule.leadingAnchor.constraint(
            equalTo: previewRow.leadingAnchor,
            constant: -(input.preferences.menuBarHorizontalPadding + chromeInset)
        )
        let capsuleTrailing = previewCapsule.trailingAnchor.constraint(
            equalTo: previewRow.trailingAnchor,
            constant: input.preferences.menuBarHorizontalPadding + chromeInset
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
        let iconToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarIcon",
            isOn: input.preferences.showMenuBarIcon,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let amountToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarAmount",
            isOn: input.preferences.showMenuBarAmount,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let resetToggle = DashboardSettingsComponents.makeSwitch(
            identifier: "showMenuBarReset",
            isOn: input.preferences.showMenuBarReset,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        iconSwitch = iconToggle
        amountSwitch = amountToggle
        let previewSection = DashboardSettingsComponents.makeSettingsSection(tr("预览", "Preview"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("当前布局", "Current Layout"),
                subtitle: tr("菜单栏会随供应商数据实时更新", "The menu bar updates with Provider data in real time"),
                control: preview,
                minimumHeight: 66
            )
        ])
        let displaySection = DashboardSettingsComponents.makeSettingsSection(tr("显示项目", "Display Items"), rows: [
            DashboardSettingsComponents.makeSettingsRow(tr("Agent 图标", "Agent Icon"), subtitle: tr("显示当前任务运行状态", "Shows the current task status"), control: iconToggle),
            DashboardSettingsComponents.makeSettingsRow(tr("额度数字", "Balance Amount"), subtitle: tr("显示百分比或 API 余额", "Shows a percentage or API balance"), control: amountToggle),
            DashboardSettingsComponents.makeSettingsRow(tr("重置倒计时", "Reset Countdown"), subtitle: tr("仅在官方额度可用时显示", "Only shown when official quota data is available"), control: resetToggle)
        ])
        let iconOffsetSummary = NSTextField(labelWithString: Self.offsetSummaryText(x: 0, y: 0))
        iconOffsetSummary.identifier = NSUserInterfaceItemIdentifier(Self.iconOffsetSummaryIdentifier)
        let amountOffsetSummary = NSTextField(labelWithString: Self.offsetSummaryText(x: 0, y: 0))
        amountOffsetSummary.identifier = NSUserInterfaceItemIdentifier(Self.amountOffsetSummaryIdentifier)
        let iconOffsetControls = makeOffsetControls(
            keyX: AppPreferences.menuBarIconOffsetXKey,
            keyY: AppPreferences.menuBarIconOffsetYKey,
            resetIdentifier: Self.iconOffsetsResetIdentifier,
            relay: input.relay
        )
        let amountOffsetControls = makeOffsetControls(
            keyX: AppPreferences.menuBarAmountOffsetXKey,
            keyY: AppPreferences.menuBarAmountOffsetYKey,
            resetIdentifier: Self.amountOffsetsResetIdentifier,
            relay: input.relay
        )
        iconOffsetSummaryLabel = iconOffsetSummary
        amountOffsetSummaryLabel = amountOffsetSummary
        iconOffsetButtons = iconOffsetControls
        amountOffsetButtons = amountOffsetControls
        let fineTuneSection = DashboardSettingsComponents.makeSettingsSection(
            tr("细节微调", "Fine Tuning"),
            rows: [
                DashboardSettingsComponents.makeSettingsRow(
                    tr("图标", "Icon"),
                    subtitle: Self.offsetSummaryText(x: 0, y: 0),
                    subtitleLabel: iconOffsetSummary,
                    control: makeOffsetControlStack(buttons: iconOffsetControls),
                    minimumHeight: 66
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr("金额", "Amount"),
                    subtitle: Self.offsetSummaryText(x: 0, y: 0),
                    subtitleLabel: amountOffsetSummary,
                    control: makeOffsetControlStack(buttons: amountOffsetControls),
                    minimumHeight: 66
                )
            ]
        )
        isBuilt = true
        refresh(snapshot: input.snapshot, preferences: input.preferences, menuBarSnapshot: input.menuBarSnapshot, iconImage: input.iconImage)
        return DashboardSettingsComponents.makeSettingsPage([
            previewSection,
            displaySection,
            fineTuneSection
        ])
    }

    func refresh(
        snapshot: Snapshot,
        preferences: AppPreferences,
        menuBarSnapshot: (Snapshot) -> Snapshot,
        iconImage: NSImage?
    ) {
        guard isBuilt else { return }
        previewIconSlot.isHidden = !preferences.showMenuBarIcon
        previewText.isHidden = !preferences.showMenuBarAmount
        iconSwitch?.isEnabled = preferences.showMenuBarAmount
        amountSwitch?.isEnabled = preferences.showMenuBarIcon
        let presentation = Self.presentation(
            for: snapshot,
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            resolving: menuBarSnapshot
        )
        previewPrimary.stringValue = presentation.primary
        previewSecondary.stringValue = presentation.secondary
        let hasSecondary = presentation.hasSecondary
        let geometry = MenuBarLayout.geometry(
            primarySize: previewPrimary.intrinsicContentSize,
            secondarySize: previewSecondary.intrinsicContentSize,
            showIcon: preferences.showMenuBarIcon,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: presentation.isBalance
        )
        MenuBarLayout.applyTextLayout(
            container: previewText,
            primary: previewPrimary,
            secondary: previewSecondary,
            geometry: geometry,
            showAmount: preferences.showMenuBarAmount,
            hasSecondary: hasSecondary
        )
        textWidthConstraint?.constant = geometry.textWidth
        capsuleLeadingConstraint?.constant = -(preferences.menuBarHorizontalPadding + chromeInset)
        capsuleTrailingConstraint?.constant = preferences.menuBarHorizontalPadding + chromeInset
        previewIcon.image = iconImage
        previewIcon.contentTintColor = .labelColor
        let iconOffsetX = preferences.menuBarIconOffsetX
        let iconOffsetY = preferences.menuBarIconOffsetY
        let amountOffsetX = preferences.menuBarAmountOffsetX
        let amountOffsetY = preferences.menuBarAmountOffsetY
        iconOffsetSummaryLabel?.stringValue = Self.offsetSummaryText(x: iconOffsetX, y: iconOffsetY)
        amountOffsetSummaryLabel?.stringValue = Self.offsetSummaryText(x: amountOffsetX, y: amountOffsetY)
        iconOffsetButtons.forEach { $0.isEnabled = preferences.showMenuBarIcon }
        amountOffsetButtons.forEach { $0.isEnabled = preferences.showMenuBarAmount }
        let iconOffset = NSSize(width: CGFloat(iconOffsetX), height: CGFloat(iconOffsetY))
        let amountOffset = NSSize(width: CGFloat(amountOffsetX), height: CGFloat(amountOffsetY))
        previewIcon.layer?.setAffineTransform(.identity)
        previewText.layer?.setAffineTransform(.identity)
        if presentation.isBalance, preferences.showMenuBarIcon, preferences.showMenuBarAmount {
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: iconOffset.width,
                y: iconOffset.height - MenuBarLayout.singleLineIconYOffset
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: amountOffset.width,
                y: -(amountOffset.height + MenuBarLayout.singleLineTextYOffset)
            ))
        } else {
            previewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: iconOffset.width,
                y: iconOffset.height
            ))
            previewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: amountOffset.width,
                y: -amountOffset.height
            ))
        }
    }

    func restoreRequiredToggle(identifier: String) {
        switch identifier {
        case "showMenuBarIcon":
            iconSwitch?.state = .on
        case "showMenuBarAmount":
            amountSwitch?.state = .on
        default:
            break
        }
    }

    private static func offsetSummaryText(x: Double, y: Double) -> String {
        String(format: "X %.1f · Y %.1f", x, y)
    }

    private func makeOffsetControls(
        keyX: String,
        keyY: String,
        resetIdentifier: String,
        relay: DashboardPreferencePageRelay
    ) -> [NSButton] {
        [
            makeOffsetButton(
                title: tr("上", "Up"),
                key: keyY,
                delta: 1,
                relay: relay
            ),
            makeOffsetButton(
                title: tr("下", "Down"),
                key: keyY,
                delta: -1,
                relay: relay
            ),
            makeOffsetButton(
                title: tr("左", "Left"),
                key: keyX,
                delta: -1,
                relay: relay
            ),
            makeOffsetButton(
                title: tr("右", "Right"),
                key: keyX,
                delta: 1,
                relay: relay
            ),
            makeOffsetResetButton(identifier: resetIdentifier, relay: relay)
        ]
    }

    private func makeOffsetButton(
        title: String,
        key: String,
        delta: Int,
        relay: DashboardPreferencePageRelay
    ) -> NSButton {
        let button = NSButton(
            title: title,
            target: relay,
            action: #selector(DashboardPreferencePageRelay.adjustOffset(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.tag = delta
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func makeOffsetResetButton(
        identifier: String,
        relay: DashboardPreferencePageRelay
    ) -> NSButton {
        let button = NSButton(
            title: tr("归零", "Reset"),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.resetOffset(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func makeOffsetControlStack(buttons: [NSButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }
}
