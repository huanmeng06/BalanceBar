import AppKit

private final class QuotaColorSelectionStack: NSStackView {
    override func layout() {
        let rowWidth = SettingsRowView.enclosing(self)?.bounds.width ?? bounds.width
        let availableWidth = rowWidth > 1 ? max(0, rowWidth - SettingsRowView.horizontalPadding * 2) : bounds.width
        let shouldStack = availableWidth > 1 && availableWidth < 300
        let nextOrientation: NSUserInterfaceLayoutOrientation = shouldStack ? .vertical : .horizontal
        if orientation != nextOrientation {
            orientation = nextOrientation
            alignment = shouldStack ? .leading : .centerY
        }
        super.layout()
    }
}

/// Dedicated Auto Layout row for a wide custom control that must sit below the
/// title, detail, and trailing action instead of beside them.
private final class MenuDedicatedControlRow: NSView {
    let titleLabel: NSTextField
    let detailLabel: NSTextField
    private let labelsStack = NSStackView()
    private let trailingControl: NSView?
    private let control: NSView

    init(
        title: String,
        detail: String?,
        trailingControl: NSView?,
        control: NSView,
        minimumHeight: CGFloat
    ) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail ?? "")
        self.trailingControl = trailingControl
        self.control = control
        super.init(frame: .zero)
        configure(
            title: title,
            detail: detail,
            minimumHeight: max(SettingsRowView.minimumHeight, minimumHeight)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            applyWrappingWidths()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        applyWrappingWidths()
    }

    private func configure(title: String, detail: String?, minimumHeight: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLabel(
            titleLabel,
            text: title,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor
        )
        let detailText = detail ?? ""
        configureLabel(
            detailLabel,
            text: detailText,
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        detailLabel.isHidden = detailText.isEmpty

        labelsStack.orientation = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = SettingsRowView.labelSpacing
        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.setHuggingPriority(.required, for: .vertical)
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelsStack.setContentHuggingPriority(.required, for: .vertical)
        labelsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        labelsStack.addArrangedSubview(titleLabel)
        if !detailLabel.isHidden {
            labelsStack.addArrangedSubview(detailLabel)
        }

        addSubview(labelsStack)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            labelsStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsRowView.horizontalPadding
            ),
            labelsStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsRowView.verticalPadding
            ),
            control.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsRowView.horizontalPadding
            ),
            control.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsRowView.horizontalPadding
            ),
            control.topAnchor.constraint(
                greaterThanOrEqualTo: labelsStack.bottomAnchor,
                constant: DashboardSettingsComponents.settingsRowContentControlSpacing
            ),
            control.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SettingsRowView.verticalPadding
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
        ]

        if let trailingControl {
            trailingControl.translatesAutoresizingMaskIntoConstraints = false
            trailingControl.setContentHuggingPriority(.required, for: .horizontal)
            trailingControl.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(trailingControl)
            constraints.append(contentsOf: [
                labelsStack.trailingAnchor.constraint(
                    equalTo: trailingControl.leadingAnchor,
                    constant: -SettingsRowView.contentSpacing
                ),
                trailingControl.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -SettingsRowView.horizontalPadding
                ),
                trailingControl.centerYAnchor.constraint(equalTo: labelsStack.centerYAnchor),
                trailingControl.topAnchor.constraint(
                    greaterThanOrEqualTo: topAnchor,
                    constant: SettingsRowView.verticalPadding
                ),
                control.topAnchor.constraint(
                    greaterThanOrEqualTo: trailingControl.bottomAnchor,
                    constant: DashboardSettingsComponents.settingsRowContentControlSpacing
                )
            ])
        } else {
            constraints.append(
                labelsStack.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -SettingsRowView.horizontalPadding
                )
            )
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func configureLabel(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor
    ) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.usesSingleLineMode = false
        label.lineBreakMode = DashboardSettingsComponents.settingsSubtitleLineBreakMode(for: text)
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
    }

    private func applyWrappingWidths() {
        var reserved = SettingsRowView.horizontalPadding * 2
        if let trailingControl, !trailingControl.isHidden {
            let accessoryWidth = trailingControl.bounds.width > 1
                ? trailingControl.bounds.width
                : trailingControl.fittingSize.width
            reserved += accessoryWidth + SettingsRowView.contentSpacing
        }
        let wrappingWidth = bounds.width > 1 ? max(0, bounds.width - reserved) : 0
        guard wrappingWidth > 1 else { return }

        var wrappingChanged = false
        if abs(titleLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            titleLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        if !detailLabel.isHidden,
           abs(detailLabel.preferredMaxLayoutWidth - wrappingWidth) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = wrappingWidth
            wrappingChanged = true
        }
        guard wrappingChanged else { return }
        invalidateIntrinsicContentSize()
        SettingsSectionView.enclosing(self)?.cardView.invalidateHostedSettingsRowHeight()
    }
}

/// Pins the Status Links editor to its explicit height so the native section
/// card follows Auto Layout instead of the editor's unconstrained table fitting size.
private final class MenuStatusLinksEditorHost: NSView {
    let editor: StatusLinksEditorHostingView
    private var heightConstraint: NSLayoutConstraint!

    init(editor: StatusLinksEditorHostingView) {
        self.editor = editor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        let heightConstraint = heightAnchor.constraint(equalToConstant: editor.currentHeight)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint
        ])
        syncHeight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    func syncHeight() {
        let height = max(0, editor.currentHeight)
        heightConstraint.constant = height
        isHidden = height <= 0.5
        invalidateIntrinsicContentSize()
        needsLayout = true
        SettingsSectionView.enclosing(self)?.cardView.invalidateHostedSettingsRowHeight()
    }
}

final class DashboardMenuPage: NSObject, NSTextFieldDelegate {
    static let lunaReserveDisplayModeIdentifier = AppPreferences.menuLunaReserveDisplayModeKey
    static let lunaReserveHideExhaustedQuotaIdentifier = AppPreferences.menuLunaReserveHideExhaustedQuotaKey
    static let bankedResetDisplayModeIdentifier = AppPreferences.menuBankedResetDisplayModeKey

    struct Input {
        let preferences: AppPreferences
        let relay: DashboardPreferencePageRelay
        let makeStatusLinksEditor: () -> StatusLinksEditorHostingView
        let onBalanceDisplayThresholdChanged: (Double) -> Void
        let onQuotaProgressColorConfigurationChanged: (QuotaProgressColorConfiguration) -> Void

        init(
            preferences: AppPreferences,
            relay: DashboardPreferencePageRelay,
            makeStatusLinksEditor: @escaping () -> StatusLinksEditorHostingView,
            onBalanceDisplayThresholdChanged: @escaping (Double) -> Void,
            onQuotaProgressColorConfigurationChanged: @escaping (QuotaProgressColorConfiguration) -> Void = { _ in }
        ) {
            self.preferences = preferences
            self.relay = relay
            self.makeStatusLinksEditor = makeStatusLinksEditor
            self.onBalanceDisplayThresholdChanged = onBalanceDisplayThresholdChanged
            self.onQuotaProgressColorConfigurationChanged = onQuotaProgressColorConfigurationChanged
        }
    }

    private weak var balanceDisplayThresholdField: NSTextField?
    private weak var lunaReserveDisplayModeControl: NSPopUpButton?
    private weak var bankedResetDisplayModeControl: NSPopUpButton?
    private weak var lunaReserveHideExhaustedQuotaRow: NSView?
    private weak var lunaReserveHideExhaustedQuotaSwitch: NSSwitch?
    private var balanceDisplaySeparators: [NSView] = []
    private var statusSubtitleLabel: NSTextField?
    private var statusLinksEditor: StatusLinksEditorHostingView?
    private var statusLinksEditorHost: MenuStatusLinksEditorHost?
    private var statusLinksSeparators: [NSView] = []
    private var balanceDisplayThresholdValue = AppPreferences.defaultBalanceDisplayThreshold
    private var onBalanceDisplayThresholdChanged: ((Double) -> Void)?
    private var onQuotaProgressColorConfigurationChanged: ((QuotaProgressColorConfiguration) -> Void)?
    private weak var quotaColorSlider: QuotaColorThresholdSlider?
    private var quotaColorButtons: [QuotaProgressColor: NSButton] = [:]
    private var quotaColorConfiguration: QuotaProgressColorConfiguration = .default
    private weak var showQuotaProgressBarSwitch: NSSwitch?
    private var progressBarDetailRows: [NSView] = []
    private var progressBarSeparators: [NSView] = []
    private weak var showBankedResetSwitch: NSSwitch?
    private var bankedResetDetailRows: [NSView] = []
    private var bankedResetSeparators: [NSView] = []

    func make(_ input: Input) -> NSView {
        balanceDisplayThresholdValue = input.preferences.balanceDisplayThreshold
        onBalanceDisplayThresholdChanged = input.onBalanceDisplayThresholdChanged
        onQuotaProgressColorConfigurationChanged = input.onQuotaProgressColorConfigurationChanged
        quotaColorConfiguration = input.preferences.quotaProgressColorConfiguration
        balanceDisplaySeparators = []
        lunaReserveDisplayModeControl = nil
        lunaReserveHideExhaustedQuotaRow = nil
        lunaReserveHideExhaustedQuotaSwitch = nil
        bankedResetDisplayModeControl = nil
        showQuotaProgressBarSwitch = nil
        progressBarDetailRows = []
        progressBarSeparators = []
        showBankedResetSwitch = nil
        bankedResetDetailRows = []
        bankedResetSeparators = []

        let lunaReserveRows: [NSView]
        if LunaReserveUserFacing.isCurrentlyEnabled {
            let lunaReserveDisplayModeControl = makeLunaReserveDisplayModeControl(
                value: input.preferences.menuLunaReserveDisplayMode,
                relay: input.relay
            )
            self.lunaReserveDisplayModeControl = lunaReserveDisplayModeControl

            let lunaReserveHideExhaustedQuotaSwitch = DashboardSettingsComponents.makeSwitch(
                identifier: Self.lunaReserveHideExhaustedQuotaIdentifier,
                isOn: input.preferences.menuLunaReserveHideExhaustedQuota,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
            self.lunaReserveHideExhaustedQuotaSwitch = lunaReserveHideExhaustedQuotaSwitch

            let lunaReserveDisplayModeRow = makeRow(
                tr(
                    .keyDashboardMenuPageLunaReserveDisplayMode,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                subtitle: tr(
                    .keyDashboardMenuPageLunaReserveDisplayModeDescription,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                control: lunaReserveDisplayModeControl
            )
            let lunaReserveHideExhaustedQuotaRow = makeRow(
                tr(.keyDashboardMenuPageHideExhaustedQuota),
                subtitle: tr(
                    .keyDashboardMenuPageHideExhaustedQuotaDescription,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                control: lunaReserveHideExhaustedQuotaSwitch
            )
            self.lunaReserveHideExhaustedQuotaRow = lunaReserveHideExhaustedQuotaRow
            lunaReserveRows = [
                lunaReserveDisplayModeRow,
                lunaReserveHideExhaustedQuotaRow
            ]
        } else {
            lunaReserveRows = []
        }
        statusLinksSeparators = []

        let balanceDisplayThreshold = NSTextField()
        balanceDisplayThreshold.identifier = NSUserInterfaceItemIdentifier(
            AppPreferences.balanceDisplayThresholdKey
        )
        balanceDisplayThreshold.stringValue = Self.formattedBalanceDisplayThreshold(
            balanceDisplayThresholdValue
        )
        balanceDisplayThreshold.placeholderString = Self.formattedBalanceDisplayThreshold(
            AppPreferences.defaultBalanceDisplayThreshold
        )
        balanceDisplayThreshold.alignment = .right
        balanceDisplayThreshold.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        balanceDisplayThreshold.isEditable = true
        balanceDisplayThreshold.isSelectable = true
        balanceDisplayThreshold.usesSingleLineMode = true
        balanceDisplayThreshold.delegate = self
        balanceDisplayThreshold.toolTip = tr(.keyDashboardMenuPageEnterAnAmountOfAtLeast001WithUpToTwoDecimalPlaces)
        balanceDisplayThreshold.widthAnchor.constraint(equalToConstant: 92).isActive = true
        balanceDisplayThreshold.setContentHuggingPriority(.required, for: .horizontal)
        balanceDisplayThreshold.setContentCompressionResistancePriority(.required, for: .horizontal)
        balanceDisplayThresholdField = balanceDisplayThreshold

        let slider = QuotaColorThresholdSlider(configuration: quotaColorConfiguration)
        slider.onChange = { [weak self] configuration in
            guard let self else { return }
            let normalized = configuration.normalized()
            self.quotaColorConfiguration = normalized
            self.updateQuotaColorButtons()
            self.onQuotaProgressColorConfigurationChanged?(normalized)
        }
        quotaColorSlider = slider
        let resetButton = NSButton(title: tr(.keyCommonRestoreDefaults), target: self, action: #selector(resetQuotaProgressColors(_:)))
        Self.configureQuotaColorResetButton(resetButton)
        let colorControls = QuotaColorSelectionStack()
        colorControls.orientation = .horizontal
        colorControls.spacing = 12
        for color in QuotaProgressColor.allCases {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleQuotaColor(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("quotaProgressColor.\(color.rawValue)")
            button.setAccessibilityLabel(Self.colorLabel(color))
            button.state = quotaColorConfiguration.enabledColors.contains(color) ? .on : .off
            let swatch = NSImageView(image: NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil) ?? NSImage())
            swatch.contentTintColor = color.nsColor
            swatch.setAccessibilityElement(false)
            let item = NSStackView(views: [button, swatch])
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 4
            let checkboxBounds = NSRect(origin: .zero, size: button.fittingSize)
            let indicatorRect = button.cell?.imageRect(forBounds: checkboxBounds) ?? checkboxBounds
            let side = max(1, min(indicatorRect.width, indicatorRect.height))
            swatch.widthAnchor.constraint(equalToConstant: side).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: side).isActive = true
            colorControls.addArrangedSubview(item)
            quotaColorButtons[color] = button
        }
        updateQuotaColorButtons()
        let balanceDisplay: SettingsSectionView? = lunaReserveRows.isEmpty
            ? nil
            : SettingsSectionView(
                title: tr(.keyDashboardMenuPageBalanceDisplay),
                contentViews: lunaReserveRows
            )
        if let balanceDisplay {
            balanceDisplaySeparators = balanceDisplay.separators
            updateLunaReserveDisplayModeVisibility(
                input.preferences.menuLunaReserveDisplayMode
            )
        }

        let showBankedResetSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showBankedResetKey,
            isOn: input.preferences.showBankedReset,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.showBankedResetSwitch = showBankedResetSwitch
        let showBankedResetRow = makeRow(
            tr(.keyDashboardMenuPageShowBankedReset),
            subtitle: tr(.keyDashboardMenuPageShowBankedResetDescription),
            control: showBankedResetSwitch
        )
        let bankedResetDisplayModeControl = makeBankedResetDisplayModeControl(
            value: input.preferences.menuBankedResetDisplayMode,
            relay: input.relay
        )
        self.bankedResetDisplayModeControl = bankedResetDisplayModeControl
        let bankedResetDisplayModeRow = makeRow(
            tr(.keyDashboardMenuPageBankedResetDisplayMode),
            subtitle: tr(.keyDashboardMenuPageBankedResetDisplayModeDescription),
            control: bankedResetDisplayModeControl
        )
        bankedResetDetailRows = [bankedResetDisplayModeRow]
        let bankedReset = SettingsSectionView(
            title: tr(.keyCodexBankedResetTitle),
            contentViews: [
                showBankedResetRow,
                bankedResetDisplayModeRow
            ]
        )
        bankedResetSeparators = bankedReset.separators
        updateBankedResetSettingsVisibility(input.preferences.showBankedReset)

        let showQuotaProgressBarSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showQuotaProgressBarKey,
            isOn: input.preferences.showQuotaProgressBar,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        self.showQuotaProgressBarSwitch = showQuotaProgressBarSwitch
        let showQuotaProgressBarRow = makeRow(
            tr(.keyDashboardMenuPageShowQuotaProgressBar),
            subtitle: tr(.keyDashboardMenuPageShowQuotaProgressBarDescription),
            control: showQuotaProgressBarSwitch
        )
        let colorRangesRow = MenuDedicatedControlRow(
            title: tr(.keyDashboardMenuPageProgressColorRanges),
            detail: tr(.keyDashboardMenuPageProgressColorRangesDescription),
            trailingControl: resetButton,
            control: slider,
            minimumHeight: 90
        )
        let displayedColorsRow = makeRow(
            tr(.keyDashboardMenuPageDisplayedColors),
            subtitle: tr(.keyDashboardMenuPageDisplayedColorsDescription),
            control: colorControls
        )
        let thresholdRow = makeRow(
            tr(.keyDashboardMenuPageLowBalanceDisplayThreshold),
            subtitle: tr(.keyDashboardMenuPageAfterARechargeKeepTheProgressBarRedWhileTheBalanceRemainsBelowThisAmount),
            control: balanceDisplayThreshold
        )
        progressBarDetailRows = [colorRangesRow, displayedColorsRow, thresholdRow]
        let progressBar = SettingsSectionView(
            title: tr(.keyDashboardMenuPageProgressBar),
            contentViews: [
                showQuotaProgressBarRow,
                colorRangesRow,
                displayedColorsRow,
                thresholdRow
            ]
        )
        progressBarSeparators = progressBar.separators
        updateProgressBarSettingsVisibility(input.preferences.showQuotaProgressBar)

        let quickSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "showQuickSwitchMenu",
            isOn: input.preferences.showQuickSwitchMenu,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let openCC = DashboardSettingsComponents.makeSwitch(
            identifier: "showOpenCCSwitchMenu",
            isOn: input.preferences.showOpenCCSwitchMenu,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let keepOpen = DashboardSettingsComponents.makeSwitch(
            identifier: "keepMenuOpenAfterRefresh",
            isOn: input.preferences.keepMenuOpenAfterRefresh,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )

        let items = SettingsSectionView(
            title: tr(.keyDashboardMenuPageMenuBehavior),
            contentViews: [
                makeRow(
                    tr(.keyDashboardMenuPageQuickSwitch),
                    subtitle: tr(.keyDashboardMenuPageShowTheCcSwitchProviderSubmenu),
                    control: quickSwitch
                ),
                makeRow(
                    tr(.keyDashboardMenuPageKeepOpenAfterRefresh),
                    subtitle: tr(.keyDashboardMenuPageReopenTheMenuAfterRefreshNow),
                    control: keepOpen
                )
            ]
        )

        let openMainWindow = DashboardSettingsComponents.makeSwitch(
            identifier: "showOpenDashboardMenu",
            isOn: true,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        openMainWindow.isEnabled = false
        openMainWindow.toolTip = tr(.keyDashboardMenuPageTheOpenMainWindowItemIsAlwaysShown)

        let quickLinkRows: [NSView] = [
            makeRow(
                tr(.keyDashboardMenuPageOpenMainWindow),
                subtitle: tr(.keyDashboardMenuPageShowTheBalancebarMainWindow),
                control: openMainWindow
            ),
            makeRow(
                tr(.keyDashboardMenuPageOpenChatgpt),
                subtitle: tr(.keyDashboardMenuPageShowChatgpt),
                control: DashboardSettingsComponents.makeSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: input.preferences.showOpenChatGPTMenu,
                    target: input.relay,
                    action: #selector(DashboardPreferencePageRelay.toggle(_:))
                )
            ),
            makeRow(
                tr(.keyDashboardMenuPageOpenCcSwitch),
                subtitle: tr(.keyDashboardMenuPageShowTheCcSwitchMainWindow),
                control: openCC
            )
        ]
        let statusVisible = input.preferences.showStatusMenu
        let statusRow = makeRow(
            tr(.keyDashboardMenuPageViewStatus),
            subtitle: statusVisible
                ? tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks)
                : tr(.keyDashboardMenuPageShowStatusLinksInTheMenuBar),
            control: DashboardSettingsComponents.makeSwitch(
                identifier: "showStatusMenu",
                isOn: statusVisible,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
        )
        statusSubtitleLabel = statusRow.detailLabel

        // Keep one editor instance in the page for both states so toggling
        // animates its height in place instead of rebuilding the whole page.
        let editor = input.makeStatusLinksEditor()
        statusLinksEditor = editor
        let editorHost = MenuStatusLinksEditorHost(editor: editor)
        statusLinksEditorHost = editorHost
        editor.setVisible(statusVisible, animated: false)
        editorHost.syncHeight()
        let quickLinks = SettingsSectionView(
            title: tr(.keyDashboardMenuPageOpenProject),
            contentViews: quickLinkRows
        )
        let statusLinks = SettingsSectionView(
            title: tr(.keyDashboardMenuPageStatusLinks),
            contentViews: [statusRow, editorHost],
            separatorIndices: [0]
        )
        statusLinksSeparators = statusLinks.separators
        statusLinksSeparators.forEach { $0.isHidden = !statusVisible }
        var sections: [NSView] = [progressBar, bankedReset, items, quickLinks, statusLinks]
        if let balanceDisplay {
            sections.insert(balanceDisplay, at: 0)
        }
        // Return the sections stack only. Production wrapping in
        // `DashboardScrollablePageViewController` owns the unique page scroller;
        // a nested `makeSettingsPage` scroll would pin the outer document to
        // the clip height and leave the Status Links editor unreachable.
        return DashboardSettingsComponents.makeSettingsPageContent(sections)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === balanceDisplayThresholdField else { return }

        guard let normalized = Self.parseBalanceDisplayThreshold(field.stringValue) else {
            field.stringValue = Self.formattedBalanceDisplayThreshold(balanceDisplayThresholdValue)
            return
        }

        field.stringValue = Self.formattedBalanceDisplayThreshold(normalized)
        guard abs(normalized - balanceDisplayThresholdValue) > 0.000001 else { return }
        balanceDisplayThresholdValue = normalized
        onBalanceDisplayThresholdChanged?(normalized)
    }

    func refresh(preferences: AppPreferences) {
        quotaColorConfiguration = preferences.quotaProgressColorConfiguration
        quotaColorSlider?.configuration = quotaColorConfiguration
        updateQuotaColorButtons()
        showQuotaProgressBarSwitch?.state = preferences.showQuotaProgressBar ? .on : .off
        updateProgressBarSettingsVisibility(preferences.showQuotaProgressBar)
        showBankedResetSwitch?.state = preferences.showBankedReset ? .on : .off
        updateBankedResetSettingsVisibility(preferences.showBankedReset)
        let statusLinks = preferences.statusLinks
        if statusLinksEditor?.links != statusLinks {
            statusLinksEditor?.updateLinks(statusLinks)
        }
        balanceDisplayThresholdValue = preferences.balanceDisplayThreshold
        balanceDisplayThresholdField?.stringValue = Self.formattedBalanceDisplayThreshold(
            balanceDisplayThresholdValue
        )
        if let lunaReserveDisplayModeControl,
           let selectedIndex = LunaReserveDisplayMode.allCases.firstIndex(
               of: preferences.menuLunaReserveDisplayMode
           ) {
            if lunaReserveDisplayModeControl.indexOfSelectedItem != selectedIndex {
                lunaReserveDisplayModeControl.selectItem(at: selectedIndex)
            }
            lunaReserveDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
        lunaReserveHideExhaustedQuotaSwitch?.state = preferences.menuLunaReserveHideExhaustedQuota
            ? .on
            : .off
        updateLunaReserveDisplayModeVisibility(preferences.menuLunaReserveDisplayMode)
        if let bankedResetDisplayModeControl,
           let selectedIndex = CodexBankedResetDisplayMode.allCases.firstIndex(
               of: preferences.menuBankedResetDisplayMode
           ) {
            if bankedResetDisplayModeControl.indexOfSelectedItem != selectedIndex {
                bankedResetDisplayModeControl.selectItem(at: selectedIndex)
            }
            bankedResetDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
    }

    func updateStatusVisibility(_ visible: Bool, animated: Bool) {
        statusSubtitleLabel?.stringValue = visible
            ? tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks2)
            : tr(.keyDashboardMenuPageShowStatusLinksInTheMenuBar2)
        statusLinksEditor?.setVisible(visible, animated: animated)
        statusLinksEditorHost?.syncHeight()
        statusLinksSeparators.forEach { $0.isHidden = !visible }
        invalidateHostedSection(for: statusLinksEditorHost ?? statusLinksEditor)
    }

    func updateStatusLinks(
        _ links: [StatusLink],
        mutation: StatusLinksMutation = .reload,
        selectLastRow: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let statusLinksEditor else {
            completion?()
            return
        }
        statusLinksEditor.updateLinks(
            links,
            mutation: mutation,
            selectLastRow: selectLastRow,
            completion: completion
        )
    }

    func teardown() {
        balanceDisplayThresholdField?.delegate = nil
        balanceDisplayThresholdField = nil
        lunaReserveDisplayModeControl = nil
        lunaReserveHideExhaustedQuotaRow = nil
        lunaReserveHideExhaustedQuotaSwitch = nil
        bankedResetDisplayModeControl = nil
        showBankedResetSwitch = nil
        bankedResetDetailRows = []
        bankedResetSeparators = []
        balanceDisplaySeparators = []
        onBalanceDisplayThresholdChanged = nil
        onQuotaProgressColorConfigurationChanged = nil
        quotaColorButtons = [:]
        quotaColorSlider?.teardown()
        quotaColorSlider = nil
        showQuotaProgressBarSwitch = nil
        progressBarDetailRows = []
        progressBarSeparators = []
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusLinksEditorHost = nil
        statusSubtitleLabel = nil
        statusLinksSeparators = []
    }

    @objc private func toggleQuotaColor(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
              let color = QuotaProgressColor(rawValue: String(raw)) else { return }
        applyQuotaColorConfiguration(quotaColorConfiguration.settingEnabled(color, to: sender.state == .on))
    }

    @objc private func resetQuotaProgressColors(_ sender: NSButton) {
        applyQuotaColorConfiguration(.default)
    }

    private func applyQuotaColorConfiguration(_ configuration: QuotaProgressColorConfiguration) {
        quotaColorConfiguration = configuration.normalized()
        quotaColorSlider?.configuration = quotaColorConfiguration
        updateQuotaColorButtons()
        onQuotaProgressColorConfigurationChanged?(quotaColorConfiguration)
    }

    private func updateQuotaColorButtons() {
        for (color, button) in quotaColorButtons {
            button.state = quotaColorConfiguration.enabledColors.contains(color) ? .on : .off
            button.isEnabled = button.state == .off || quotaColorConfiguration.enabledColors.count > 2
        }
    }

    static func configureQuotaColorResetButton(_ button: NSButton) {
        button.controlSize = .regular
        button.bezelStyle = .rounded
        // Resetting an already-default configuration is a harmless no-op; keep
        // the action visually consistent with the other settings buttons.
        button.isEnabled = true
    }

    private static func colorLabel(_ color: QuotaProgressColor) -> String {
        switch color { case .red: tr(.keyDashboardMenuPageColorRed); case .orange: tr(.keyDashboardMenuPageColorOrange); case .yellow: tr(.keyDashboardMenuPageColorYellow); case .green: tr(.keyDashboardMenuPageColorGreen) }
    }

    private func updateLunaReserveDisplayModeVisibility(_ mode: LunaReserveDisplayMode) {
        let shouldShowHideOption = mode != .disabled
        lunaReserveHideExhaustedQuotaRow?.isHidden = !shouldShowHideOption
        lunaReserveHideExhaustedQuotaSwitch?.isEnabled = shouldShowHideOption
        if let separator = balanceDisplaySeparators.first {
            // When the dependent switch is hidden, collapse the separator
            // between the two remaining balance-display rows.
            separator.isHidden = !shouldShowHideOption
        }
        invalidateHostedSection(for: lunaReserveHideExhaustedQuotaRow)
    }

    private func updateProgressBarSettingsVisibility(_ visible: Bool) {
        progressBarDetailRows.forEach { $0.isHidden = !visible }
        updateSeparatorVisibility(
            separators: progressBarSeparators,
            visibleRows: [true] + progressBarDetailRows.map { _ in visible }
        )
        invalidateHostedSection(for: showQuotaProgressBarSwitch)
    }

    private func updateBankedResetSettingsVisibility(_ visible: Bool) {
        bankedResetDetailRows.forEach { $0.isHidden = !visible }
        updateSeparatorVisibility(
            separators: bankedResetSeparators,
            visibleRows: [true] + bankedResetDetailRows.map { _ in visible }
        )
        invalidateHostedSection(for: showBankedResetSwitch)
    }

    private func updateSeparatorVisibility(separators: [NSView], visibleRows: [Bool]) {
        for (index, separator) in separators.enumerated() {
            guard index < visibleRows.count - 1 else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = visibleRows[(index + 1)...].contains(true)
            separator.isHidden = !(visibleRows[index] && hasVisibleRowAfter)
        }
    }

    private func invalidateHostedSection(for view: NSView?) {
        guard let view else { return }
        view.invalidateIntrinsicContentSize()
        guard let section = SettingsSectionView.enclosing(view) else { return }
        section.cardView.invalidateHostedSettingsRowHeight()
        section.invalidateIntrinsicContentSize()
        section.needsLayout = true
        section.superview?.needsLayout = true
        section.superview?.invalidateIntrinsicContentSize()
        section.layoutSubtreeIfNeeded()
    }

    private func makeRow(
        _ title: String,
        subtitle: String? = nil,
        control: NSView? = nil
    ) -> SettingsRowView {
        SettingsRowView(title: title, detail: subtitle, accessoryView: control)
    }

    private func makeLunaReserveDisplayModeControl(
        value: LunaReserveDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.lunaReserveDisplayModeIdentifier,
            items: LunaReserveDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.lunaReserveDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: LunaReserveDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.lunaReserveDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(
            .keyDashboardMenuPageLunaReserveDisplayMode,
            arguments: [tr(.keyLunaReserveTitle)]
        )
        return control
    }

    private func makeBankedResetDisplayModeControl(
        value: CodexBankedResetDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: Self.bankedResetDisplayModeIdentifier,
            items: CodexBankedResetDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.bankedResetDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: CodexBankedResetDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.bankedResetDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 88
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuPageBankedResetDisplayModeDescription)
        return control
    }

    private static func bankedResetDisplayModeLabel(_ mode: CodexBankedResetDisplayMode) -> String {
        switch mode {
        case .compact:
            return tr(.keyDashboardMenuPageBankedResetDisplayModeCompact)
        case .detailed:
            return tr(.keyDashboardMenuPageBankedResetDisplayModeDetailed)
        }
    }

    private static func lunaReserveDisplayModeLabel(_ mode: LunaReserveDisplayMode) -> String {
        switch mode {
        case .disabled:
            return tr(.keyDashboardMenuPageLunaReserveDisplayModeDisabled)
        case .whenQuotaExhausted:
            return tr(.keyDashboardMenuPageLunaReserveDisplayModeWhenQuotaExhausted)
        case .always:
            return tr(.keyDashboardMenuPageLunaReserveDisplayModeAlways)
        }
    }

    private static func parseBalanceDisplayThreshold(_ text: String) -> Double? {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalizedText), value.isFinite,
              value >= AppPreferences.minimumBalanceDisplayThreshold,
              value <= Double(Int.max) / 100 else { return nil }
        let normalized = AppPreferences.normalizedBalanceDisplayThreshold(value)
        return normalized >= AppPreferences.minimumBalanceDisplayThreshold ? normalized : nil
    }

    private static func formattedBalanceDisplayThreshold(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
