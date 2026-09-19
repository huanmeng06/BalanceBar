import AppKit

/// Quota, reset-time, and Luna Reserve display settings for the Menu Bar page.
final class DashboardMenuBarQuotaSection {
    private(set) var quotaCardLayoutCountForTesting = 0

    private weak var amountSwitch: NSSwitch?
    private weak var amountDisplayRow: NSView?
    private weak var resetCountdownRow: NSView?
    private weak var quotaWindowPreferenceRow: NSView?
    private weak var autoSwitchLunaReserveRow: NSView?
    private weak var lunaReserveResetTimeRow: NSView?
    private weak var quotaResetDisplayModeRow: NSView?
    private weak var quotaWindowPreferenceControl: NSPopUpButton?
    private weak var autoSwitchLunaReserveSwitch: NSSwitch?
    private weak var lunaReserveResetTimeModeControl: NSPopUpButton?
    private weak var quotaResetDisplayModeControl: NSPopUpButton?
    private var quotaSeparators: [NSView] = []
    private weak var quotaSection: SettingsSectionView?
    private var lastQuotaVisibilitySignature: [Bool]?

    func resetRefreshSignatures() {
        lastQuotaVisibilitySignature = nil
    }

    func restoreAmountToggle() {
        amountSwitch?.state = .on
    }

    func setAmountSwitchEnabled(_ isEnabled: Bool) {
        amountSwitch?.isEnabled = isEnabled
    }

    func make(input: DashboardMenuBarPage.Input) -> NSView {
        quotaSeparators = []
        quotaSection = nil
        lastQuotaVisibilitySignature = nil

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
        amountSwitch = amountToggle
        autoSwitchLunaReserveSwitch = nil
        lunaReserveResetTimeModeControl = nil
        let showLunaReserveSettings = LunaReserveUserFacing.isCurrentlyEnabled
        let autoSwitchLunaReserve = showLunaReserveSettings
            ? DashboardSettingsComponents.makeSwitch(
                identifier: DashboardMenuBarPage.autoSwitchLunaReserveIdentifier,
                isOn: input.preferences.menuBarAutoSwitchLunaReserve,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.toggle(_:))
            )
            : nil
        autoSwitchLunaReserveSwitch = autoSwitchLunaReserve
        let quotaWindowPreferenceControl = makeQuotaWindowPreferenceControl(
            value: input.preferences.menuBarQuotaWindowPreference,
            relay: input.relay
        )
        self.quotaWindowPreferenceControl = quotaWindowPreferenceControl
        let lunaReserveResetTimeModeControl = showLunaReserveSettings
            ? makeLunaReserveResetTimeModeControl(
                value: input.preferences.menuBarLunaReserveResetTimeMode,
                relay: input.relay
            )
            : nil
        self.lunaReserveResetTimeModeControl = lunaReserveResetTimeModeControl
        let quotaResetDisplayModeControl = makeQuotaResetDisplayModeControl(
            value: input.preferences.menuBarQuotaResetDisplayMode,
            relay: input.relay
        )
        self.quotaResetDisplayModeControl = quotaResetDisplayModeControl
        let quotaWindowPreferenceRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageQuotaDisplayPriority),
            detail: tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription),
            accessoryView: quotaWindowPreferenceControl
        )
        self.quotaWindowPreferenceRow = quotaWindowPreferenceRow
        autoSwitchLunaReserveRow = nil
        lunaReserveResetTimeRow = nil
        let autoSwitchLunaReserveRow: NSView?
        let lunaReserveResetTimeRow: NSView?
        if let autoSwitchLunaReserve, let lunaReserveResetTimeModeControl {
            let autoSwitchRow = SettingsRowView(
                title: tr(
                    .keyDashboardMenuBarPageAutoSwitchLunaReserve,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                detail: tr(
                    .keyDashboardMenuBarPageAutoSwitchLunaReserveDescription,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                accessoryView: autoSwitchLunaReserve
            )
            let resetTimeRow = SettingsRowView(
                title: tr(
                    .keyDashboardMenuBarPageLunaReserveResetTime,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                detail: tr(
                    .keyDashboardMenuBarPageLunaReserveResetTimeDescription,
                    arguments: [tr(.keyLunaReserveTitle)]
                ),
                accessoryView: lunaReserveResetTimeModeControl
            )
            self.autoSwitchLunaReserveRow = autoSwitchRow
            self.lunaReserveResetTimeRow = resetTimeRow
            autoSwitchLunaReserveRow = autoSwitchRow
            lunaReserveResetTimeRow = resetTimeRow
        } else {
            autoSwitchLunaReserveRow = nil
            lunaReserveResetTimeRow = nil
        }
        let amountDisplayRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageBalanceAmount),
            detail: tr(.keyDashboardMenuBarPageShowsAPercentageOrApiBalance),
            accessoryView: amountToggle
        )
        self.amountDisplayRow = amountDisplayRow
        let resetCountdownRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageResetCountdown),
            detail: tr(.keyDashboardMenuBarPageOnlyShownWhenOfficialQuotaDataIsAvailable),
            accessoryView: resetToggle
        )
        self.resetCountdownRow = resetCountdownRow
        let quotaResetDisplayModeRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageQuotaResetDisplayMode),
            detail: tr(.keyDashboardMenuBarPageQuotaResetDisplayModeDescription),
            accessoryView: quotaResetDisplayModeControl
        )
        self.quotaResetDisplayModeRow = quotaResetDisplayModeRow
        let quotaSection = SettingsSectionView(
            title: tr(.keyDashboardMenuBarPageQuotaAndReset),
            contentViews: [
                amountDisplayRow,
                resetCountdownRow,
                quotaWindowPreferenceRow,
                quotaResetDisplayModeRow,
                autoSwitchLunaReserveRow,
                lunaReserveResetTimeRow
            ].compactMap { $0 }
        )
        self.quotaSection = quotaSection
        self.quotaSeparators = quotaSection.separators
        updateVisibility(
            showAmount: input.preferences.showMenuBarAmount,
            showReset: input.preferences.showMenuBarReset,
            autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && input.preferences.menuBarAutoSwitchLunaReserve
        )
        return quotaSection
    }

    func refresh(preferences: AppPreferences) {
        updateVisibility(
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && preferences.menuBarAutoSwitchLunaReserve
        )
        if let quotaWindowPreferenceControl,
           let selectedIndex = OfficialQuotaWindowPreference.allCases.firstIndex(
               of: preferences.menuBarQuotaWindowPreference
           ) {
            if quotaWindowPreferenceControl.indexOfSelectedItem != selectedIndex {
                quotaWindowPreferenceControl.selectItem(at: selectedIndex)
            }
            quotaWindowPreferenceControl.synchronizeTitleAndSelectedItem()
        }
        if let quotaResetDisplayModeControl,
           let selectedIndex = OfficialQuotaResetDisplayMode.allCases.firstIndex(
               of: preferences.menuBarQuotaResetDisplayMode
           ) {
            if quotaResetDisplayModeControl.indexOfSelectedItem != selectedIndex {
                quotaResetDisplayModeControl.selectItem(at: selectedIndex)
            }
            quotaResetDisplayModeControl.synchronizeTitleAndSelectedItem()
        }
        autoSwitchLunaReserveSwitch?.state = preferences.menuBarAutoSwitchLunaReserve
            ? .on
            : .off
        if let lunaReserveResetTimeModeControl,
           let selectedIndex = LunaReserveResetTimeMode.allCases.firstIndex(
               of: preferences.menuBarLunaReserveResetTimeMode
           ) {
            if lunaReserveResetTimeModeControl.indexOfSelectedItem != selectedIndex {
                lunaReserveResetTimeModeControl.selectItem(at: selectedIndex)
            }
            lunaReserveResetTimeModeControl.synchronizeTitleAndSelectedItem()
        }
    }

    private func updateVisibility(
        showAmount: Bool,
        showReset: Bool,
        autoSwitchLunaReserve: Bool
    ) {
        let signature = [showAmount, showReset, autoSwitchLunaReserve]
        guard signature != lastQuotaVisibilitySignature else { return }
        lastQuotaVisibilitySignature = signature
        resetCountdownRow?.isHidden = !showAmount
        let showResetDetails = showAmount && showReset
        quotaWindowPreferenceRow?.isHidden = !showResetDetails
        autoSwitchLunaReserveRow?.isHidden = !showAmount
        lunaReserveResetTimeRow?.isHidden = !showAmount || !autoSwitchLunaReserve
        quotaResetDisplayModeRow?.isHidden = !showResetDetails
        autoSwitchLunaReserveSwitch?.isEnabled = showAmount
        lunaReserveResetTimeModeControl?.isEnabled = showAmount && autoSwitchLunaReserve

        // The separators describe visible row boundaries. When the dependent
        // Reserve row is hidden, keep exactly one separator after each visible
        // row that has another visible row later in the ordered list. This
        // collapses hidden rows without producing doubled lines.
        let rows = [
            amountDisplayRow,
            resetCountdownRow,
            quotaWindowPreferenceRow,
            quotaResetDisplayModeRow,
            autoSwitchLunaReserveRow,
            lunaReserveResetTimeRow
        ]
        for (index, separator) in quotaSeparators.enumerated() {
            guard index < rows.count,
                  index + 1 < rows.count else {
                separator.isHidden = true
                continue
            }
            let hasVisibleRowAfter = rows[(index + 1)...].contains { $0?.isHidden == false }
            separator.isHidden = !(rows[index]?.isHidden == false && hasVisibleRowAfter)
        }
        guard let quotaSection else { return }
        quotaCardLayoutCountForTesting += 1
        quotaSection.cardView.invalidateHostedSettingsRowHeight()
        quotaSection.invalidateIntrinsicContentSize()
        quotaSection.needsLayout = true
        quotaSection.superview?.invalidateIntrinsicContentSize()
        quotaSection.superview?.needsLayout = true
    }

    private func makeQuotaWindowPreferenceControl(
        value: OfficialQuotaWindowPreference,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.quotaWindowPreferenceIdentifier,
            items: OfficialQuotaWindowPreference.allCases.map { preference in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.quotaWindowPreferenceLabel(preference),
                    representedObject: preference.rawValue
                )
            },
            selectedIndex: OfficialQuotaWindowPreference.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarQuotaWindowPreference(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageQuotaDisplayPriorityDescription)
        return control
    }

    private func makeQuotaResetDisplayModeControl(
        value: OfficialQuotaResetDisplayMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.quotaResetDisplayModeIdentifier,
            items: OfficialQuotaResetDisplayMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.quotaResetDisplayModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: OfficialQuotaResetDisplayMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarQuotaResetDisplayMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(.keyDashboardMenuBarPageQuotaResetDisplayModeDescription)
        return control
    }

    private func makeLunaReserveResetTimeModeControl(
        value: LunaReserveResetTimeMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.lunaReserveResetTimeModeIdentifier,
            items: LunaReserveResetTimeMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: Self.lunaReserveResetTimeModeLabel(mode),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: LunaReserveResetTimeMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarLunaReserveResetTimeMode(_:))
        )
        let minimumWidth: CGFloat = 108
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(minimumWidth, ceil(control.fittingSize.width))
        ).isActive = true
        control.toolTip = tr(
            .keyDashboardMenuBarPageLunaReserveResetTimeDescription,
            arguments: [tr(.keyLunaReserveTitle)]
        )
        return control
    }

    private static func quotaWindowPreferenceLabel(
        _ preference: OfficialQuotaWindowPreference
    ) -> String {
        switch preference {
        case .fiveHour:
            return tr(.keyDashboardMenuBarPageFiveHourQuota)
        case .sevenDay:
            return tr(.keyDashboardMenuBarPageSevenDayQuota)
        }
    }

    private static func quotaResetDisplayModeLabel(
        _ mode: OfficialQuotaResetDisplayMode
    ) -> String {
        switch mode {
        case .remaining:
            return tr(.keyDashboardMenuBarPageQuotaResetDisplayRemaining)
        case .resetAt:
            return tr(.keyDashboardMenuBarPageQuotaResetDisplayTarget)
        case .both:
            return tr(.keyDashboardMenuBarPageQuotaResetDisplayBoth)
        }
    }

    private static func lunaReserveResetTimeModeLabel(
        _ mode: LunaReserveResetTimeMode
    ) -> String {
        switch mode {
        case .lunaReserve:
            return tr(
                .keyDashboardMenuBarPageLunaReserveResetTimeLunaReserve,
                arguments: [tr(.keyLunaReserveTitle)]
            )
        case .originalQuota:
            return tr(.keyDashboardMenuBarPageLunaReserveResetTimeOriginalQuota)
        }
    }
}
