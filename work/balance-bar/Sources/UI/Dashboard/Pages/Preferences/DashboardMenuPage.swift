import AppKit

final class DashboardMenuPage: NSObject, NSTextFieldDelegate {
    struct Input {
        let preferences: AppPreferences
        let relay: DashboardPreferencePageRelay
        let makeStatusLinksEditor: () -> StatusLinksEditorHostingView
        let onBalanceDisplayThresholdChanged: (Double) -> Void
    }

    private weak var balanceDisplayThresholdField: NSTextField?
    private var statusSubtitleLabel: NSTextField?
    private var statusLinksEditor: StatusLinksEditorHostingView?
    private weak var statusLinksRowsStack: NSStackView?
    private weak var statusLinksCardHeightConstraint: NSLayoutConstraint?
    private var statusLinksSeparators: [NSView] = []
    private var balanceDisplayThresholdValue = AppPreferences.defaultBalanceDisplayThreshold
    private var onBalanceDisplayThresholdChanged: ((Double) -> Void)?

    func make(_ input: Input) -> NSView {
        balanceDisplayThresholdValue = input.preferences.balanceDisplayThreshold
        onBalanceDisplayThresholdChanged = input.onBalanceDisplayThresholdChanged
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

        let balanceDisplay = DashboardSettingsComponents.makeSettingsSection(
            tr(.keyDashboardMenuPageBalanceDisplay),
            rows: [
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
        DispatchQueue.main.async { [weak editor] in
            editor?.logGeometry(label: "initial")
        }
        return DashboardSettingsComponents.makeSettingsPage([balanceDisplay, items, quickLinks, statusLinks])
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

    func updateStatusVisibility(_ visible: Bool, animated: Bool) {
        statusSubtitleLabel?.stringValue = visible
            ? tr(.keyDashboardMenuPageShowCustomizableServiceStatusLinks2)
            : tr(.keyDashboardMenuPageShowStatusLinksInTheMenuBar2)
        statusLinksEditor?.setVisible(visible, animated: animated)
        statusLinksSeparators.forEach { $0.isHidden = !visible }
        updateStatusLinksLayout()
    }

    func teardown() {
        balanceDisplayThresholdField?.delegate = nil
        balanceDisplayThresholdField = nil
        onBalanceDisplayThresholdChanged = nil
        statusLinksEditor?.teardown()
        statusLinksEditor = nil
        statusSubtitleLabel = nil
        statusLinksRowsStack = nil
        statusLinksCardHeightConstraint = nil
        statusLinksSeparators = []
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
