import AppKit

private final class QuotaColorSelectionStack: NSStackView, DashboardSettingsRowControlLayout {
    private(set) var usesDedicatedRow = false
    let allowsTextDrivenDedicatedRow = true
    func updateAvailableRowWidth(_ width: CGFloat) {
        let shouldStack = width < 300
        guard usesDedicatedRow != shouldStack else { return }
        usesDedicatedRow = shouldStack
        orientation = shouldStack ? .vertical : .horizontal
        alignment = shouldStack ? .leading : .centerY
        needsLayout = true
    }
}

final class DashboardMenuPage: NSObject, NSTextFieldDelegate {
    static let lunaReserveDisplayModeIdentifier = AppPreferences.menuLunaReserveDisplayModeKey
    static let lunaReserveHideExhaustedQuotaIdentifier = AppPreferences.menuLunaReserveHideExhaustedQuotaKey

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
    private weak var lunaReserveHideExhaustedQuotaRow: NSView?
    private weak var lunaReserveHideExhaustedQuotaSwitch: NSSwitch?
    private weak var balanceDisplayRowsStack: NSStackView?
    private weak var balanceDisplayCardHeightConstraint: NSLayoutConstraint?
    private var balanceDisplaySeparators: [NSView] = []
    private var statusSubtitleLabel: NSTextField?
    private var statusLinksEditor: StatusLinksEditorHostingView?
    private weak var statusLinksRowsStack: NSStackView?
    private weak var statusLinksCardHeightConstraint: NSLayoutConstraint?
    private var statusLinksSeparators: [NSView] = []
    private var balanceDisplayThresholdValue = AppPreferences.defaultBalanceDisplayThreshold
    private var onBalanceDisplayThresholdChanged: ((Double) -> Void)?
    private var onQuotaProgressColorConfigurationChanged: ((QuotaProgressColorConfiguration) -> Void)?
    private weak var quotaColorSlider: QuotaColorThresholdSlider?
    private var quotaColorButtons: [QuotaProgressColor: NSButton] = [:]
    private var quotaColorConfiguration: QuotaProgressColorConfiguration = .default

    func make(_ input: Input) -> NSView {
        balanceDisplayThresholdValue = input.preferences.balanceDisplayThreshold
        onBalanceDisplayThresholdChanged = input.onBalanceDisplayThresholdChanged
        onQuotaProgressColorConfigurationChanged = input.onQuotaProgressColorConfigurationChanged
        quotaColorConfiguration = input.preferences.quotaProgressColorConfiguration
        balanceDisplayRowsStack = nil
        balanceDisplayCardHeightConstraint = nil
        balanceDisplaySeparators = []

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

        let lunaReserveDisplayModeRow = DashboardSettingsComponents.makeSettingsRow(
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
        let lunaReserveHideExhaustedQuotaRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuPageHideExhaustedQuota),
            subtitle: tr(
                .keyDashboardMenuPageHideExhaustedQuotaDescription,
                arguments: [tr(.keyLunaReserveTitle)]
            ),
            control: lunaReserveHideExhaustedQuotaSwitch
        )
        self.lunaReserveHideExhaustedQuotaRow = lunaReserveHideExhaustedQuotaRow
        statusLinksRowsStack = nil
        statusLinksCardHeightConstraint = nil
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
        colorControls.orientation = .horizontal; colorControls.spacing = 12
        for color in QuotaProgressColor.allCases {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleQuotaColor(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("quotaProgressColor.\(color.rawValue)")
            button.setAccessibilityLabel(Self.colorLabel(color))
            button.state = quotaColorConfiguration.enabledColors.contains(color) ? .on : .off
            let swatch = NSImageView(image: NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil) ?? NSImage())
            swatch.contentTintColor = color.nsColor
            swatch.setAccessibilityElement(false)
            let item = NSStackView(views: [button, swatch]); item.orientation = .horizontal; item.alignment = .centerY; item.spacing = 4
            let checkboxBounds = NSRect(origin: .zero, size: button.fittingSize)
            let indicatorRect = button.cell?.imageRect(forBounds: checkboxBounds) ?? checkboxBounds
            let side = max(1, min(indicatorRect.width, indicatorRect.height))
            swatch.widthAnchor.constraint(equalToConstant: side).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: side).isActive = true
            colorControls.addArrangedSubview(item); quotaColorButtons[color] = button
        }
        updateQuotaColorButtons()
        let balanceDisplay = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuPageBalanceDisplay),
            rows: [
                lunaReserveDisplayModeRow,
                lunaReserveHideExhaustedQuotaRow
            ],
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.balanceDisplayRowsStack = rowsStack
                self?.balanceDisplayCardHeightConstraint = cardHeightConstraint
                self?.balanceDisplaySeparators = separators
                self?.updateLunaReserveDisplayModeVisibility(
                    input.preferences.menuLunaReserveDisplayMode
                )
            }
        )

        let progressBar = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuPageProgressBar),
            rows: [
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuPageProgressColorRanges),
                    subtitle: tr(.keyDashboardMenuPageProgressColorRangesDescription),
                    headerTrailingAccessory: resetButton,
                    control: slider,
                    minimumHeight: 90,
                    controlWidthConstrainedToRow: true,
                    forceDedicatedControlRow: true
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuPageDisplayedColors),
                    subtitle: tr(.keyDashboardMenuPageDisplayedColorsDescription),
                    control: colorControls,
                    controlWidthConstrainedToRow: true
                ),
                DashboardSettingsComponents.makeSettingsRow(
                    tr(.keyDashboardMenuPageLowBalanceDisplayThreshold),
                    subtitle: tr(.keyDashboardMenuPageAfterARechargeKeepTheProgressBarRedWhileTheBalanceRemainsBelowThisAmount),
                    control: balanceDisplayThreshold
                )
            ]
        )

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
        let openCodex = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.showOpenCodexMenuKey,
            isOn: input.preferences.showOpenCodexMenu,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        let keepOpen = DashboardSettingsComponents.makeSwitch(
            identifier: "keepMenuOpenAfterRefresh",
            isOn: input.preferences.keepMenuOpenAfterRefresh,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )

        let items = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardMenuPageMenuBehavior), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuPageQuickSwitch),
                subtitle: tr(.keyDashboardMenuPageShowTheCcSwitchProviderSubmenu),
                control: quickSwitch
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuPageKeepOpenAfterRefresh),
                subtitle: tr(.keyDashboardMenuPageReopenTheMenuAfterRefreshNow),
                control: keepOpen
            )
        ])

        let openMainWindow = DashboardSettingsComponents.makeSwitch(
            identifier: "showOpenDashboardMenu",
            isOn: true,
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:))
        )
        openMainWindow.isEnabled = false
        openMainWindow.toolTip = tr(.keyDashboardMenuPageTheOpenMainWindowItemIsAlwaysShown)

        let quickLinkRows: [NSView] = [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuPageOpenMainWindow),
                subtitle: tr(.keyDashboardMenuPageShowTheBalancebarMainWindow),
                control: openMainWindow
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuPageOpenChatgpt),
                subtitle: tr(.keyDashboardMenuPageShowChatgpt),
                control: DashboardSettingsComponents.makeSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: input.preferences.showOpenChatGPTMenu,
                    target: input.relay,
                    action: #selector(DashboardPreferencePageRelay.toggle(_:))
                )
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuPageOpenCcSwitch),
                subtitle: tr(.keyDashboardMenuPageShowTheCcSwitchMainWindow),
                control: openCC
            ),
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardMenuPageOpenOpencodex),
                subtitle: tr(.keyDashboardMenuPageShowTheOpencodexDashboard),
                control: openCodex
            )
        ]
        let statusSubtitle = NSTextField(wrappingLabelWithString: "")
        statusSubtitleLabel = statusSubtitle
        let statusVisible = input.preferences.showStatusMenu
        updateStatusVisibility(statusVisible, animated: false)
        let statusRow = DashboardSettingsComponents.makeSettingsRow(
            tr(.keyDashboardMenuPageViewStatus),
            subtitle: statusVisible
                ? tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks)
                : tr(.keyDashboardMenuPageShowStatusLinksInTheMenuBar),
            subtitleLabel: statusSubtitle,
            control: DashboardSettingsComponents.makeSwitch(
                identifier: "showStatusMenu",
                isOn: statusVisible,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
        )

        // Keep one editor instance in the page for both states so toggling
        // animates its height in place instead of rebuilding the whole page.
        let editor = input.makeStatusLinksEditor()
        statusLinksEditor = editor
        editor.setVisible(statusVisible, animated: false)
        let quickLinks = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuPageOpenProject),
            rows: quickLinkRows
        )
        let statusLinks = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuPageStatusLinks),
            rows: [statusRow, editor],
            separatorIndices: [0],
            rowHeight: { row in
                (row as? StatusLinksEditorHostingView)?.currentHeight
            },
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                self?.statusLinksRowsStack = rowsStack
                self?.statusLinksCardHeightConstraint = cardHeightConstraint
                self?.statusLinksSeparators = separators
                self?.updateStatusLinksLayout()
            }
        )
        return DashboardSettingsComponents.makeSettingsPage([
            balanceDisplay,
            progressBar,
            items,
            quickLinks,
            statusLinks
        ])
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === balanceDisplayThresholdField else { return }

        guard let normalized = Self.parseBalanceDisplayThreshold(field.stringValue) else {
            field.stringValue = Self.formattedBalanceDisplayThreshold(balanceDisplayThresholdValue)
            DashboardSettingsComponents.invalidateSettingsRowControlMetrics(containing: field)
            return
        }

        field.stringValue = Self.formattedBalanceDisplayThreshold(normalized)
        DashboardSettingsComponents.invalidateSettingsRowControlMetrics(containing: field)
        guard abs(normalized - balanceDisplayThresholdValue) > 0.000001 else { return }
        balanceDisplayThresholdValue = normalized
        onBalanceDisplayThresholdChanged?(normalized)
    }

    func refresh(preferences: AppPreferences) {
        quotaColorConfiguration = preferences.quotaProgressColorConfiguration
        quotaColorSlider?.configuration = quotaColorConfiguration
        updateQuotaColorButtons()
        let statusLinks = preferences.statusLinks
        if statusLinksEditor?.links != statusLinks {
            statusLinksEditor?.updateLinks(statusLinks)
        }
        balanceDisplayThresholdValue = preferences.balanceDisplayThreshold
        balanceDisplayThresholdField?.stringValue = Self.formattedBalanceDisplayThreshold(
            balanceDisplayThresholdValue
        )
        DashboardSettingsComponents.invalidateSettingsRowControlMetrics(containing: balanceDisplayThresholdField)
        if let lunaReserveDisplayModeControl,
           let selectedIndex = LunaReserveDisplayMode.allCases.firstIndex(
               of: preferences.menuLunaReserveDisplayMode
           ) {
            if lunaReserveDisplayModeControl.indexOfSelectedItem != selectedIndex {
                lunaReserveDisplayModeControl.selectItem(at: selectedIndex)
            }
            lunaReserveDisplayModeControl.synchronizeTitleAndSelectedItem()
            DashboardSettingsComponents.invalidateSettingsRowControlMetrics(containing: lunaReserveDisplayModeControl)
        }
        lunaReserveHideExhaustedQuotaSwitch?.state = preferences.menuLunaReserveHideExhaustedQuota
            ? .on
            : .off
        updateLunaReserveDisplayModeVisibility(preferences.menuLunaReserveDisplayMode)
    }

    func updateStatusVisibility(_ visible: Bool, animated: Bool) {
        statusSubtitleLabel?.stringValue = visible
            ? tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks2)
            : tr(.keyDashboardMenuPageShowStatusLinksInTheMenuBar2)
        DashboardSettingsComponents.invalidateSettingsRowContent(containing: statusSubtitleLabel)
        statusLinksEditor?.setVisible(visible, animated: animated)
        statusLinksSeparators.forEach { $0.isHidden = !visible }
        updateStatusLinksLayout()
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
        balanceDisplayRowsStack = nil
        balanceDisplayCardHeightConstraint = nil
        balanceDisplaySeparators = []
        onBalanceDisplayThresholdChanged = nil
        onQuotaProgressColorConfigurationChanged = nil
        quotaColorButtons = [:]
        quotaColorSlider?.teardown()
        quotaColorSlider = nil
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusSubtitleLabel = nil
        statusLinksRowsStack = nil
        statusLinksCardHeightConstraint = nil
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
        button.controlSize = .small
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
        updateBalanceDisplayLayout()
    }

    private func updateBalanceDisplayLayout() {
        guard let balanceDisplayRowsStack,
              let balanceDisplayCardHeightConstraint else { return }
        // Do not force a pre-mount layout here. The page has not received its
        // document width when this callback first runs, and asking an adaptive
        // row to lay out at width zero would permanently select its dedicated
        // (stacked-control) constraint set until the next rebuild.
        balanceDisplayRowsStack.needsLayout = true
        balanceDisplayCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: balanceDisplayRowsStack,
            separators: balanceDisplaySeparators
        )
        balanceDisplayRowsStack.superview?.invalidateIntrinsicContentSize()
        balanceDisplayRowsStack.superview?.needsLayout = true
        balanceDisplayRowsStack.superview?.superview?.needsLayout = true
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

    private func updateStatusLinksLayout() {
        guard let statusLinksRowsStack,
              let statusLinksCardHeightConstraint else { return }
        statusLinksRowsStack.needsLayout = true
        statusLinksRowsStack.layoutSubtreeIfNeeded()
        statusLinksCardHeightConstraint.constant = DashboardSettingsComponents.settingsCardHeight(
            rowsStack: statusLinksRowsStack,
            separators: statusLinksSeparators,
            rowHeight: { row in
                (row as? StatusLinksEditorHostingView)?.currentHeight
            }
        )
        statusLinksRowsStack.superview?.invalidateIntrinsicContentSize()
        statusLinksRowsStack.superview?.needsLayout = true
        statusLinksRowsStack.superview?.superview?.needsLayout = true
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
