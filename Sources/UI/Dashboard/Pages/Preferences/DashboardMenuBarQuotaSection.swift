import AppKit

/// Quota, reset-time, and Luna Reserve display settings for the Menu Bar page.
final class DashboardMenuBarQuotaSection {
    private(set) var quotaCardLayoutCountForTesting = 0

    private weak var amountSwitch: NSSwitch?
    private weak var amountDisplayRow: SettingsRowView?
    private weak var resetCountdownRow: SettingsRowView?
    private weak var quotaValueModeControl: NSPopUpButton?
    private weak var autoSwitchLunaReserveRow: SettingsRowView?
    private weak var lunaReserveResetTimeRow: SettingsRowView?
    private weak var quotaResetDisplayModeRow: SettingsRowView?
    private weak var quotaWindowPreferenceControl: NSPopUpButton?
    private weak var autoSwitchLunaReserveSwitch: NSSwitch?
    private weak var lunaReserveResetTimeModeControl: NSPopUpButton?
    private weak var quotaResetDisplayModeControl: NSPopUpButton?
    private var lastQuotaVisibilitySignature: [Bool]?

    func resetRefreshSignatures() {
        lastQuotaVisibilitySignature = nil
    }

    func restoreAmountToggle() {
        amountSwitch?.state = .on
    }

    func setAmountSwitchEnabled(_ isEnabled: Bool) {
        amountDisplayRow?.setDependencyEnabled(isEnabled)
    }

    func make(input: DashboardMenuBarPage.Input) -> [NSView] {
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
        let quotaValueModeControl = makeQuotaValueModeControl(
            value: input.preferences.menuBarQuotaValueMode,
            relay: input.relay
        )
        self.quotaValueModeControl = quotaValueModeControl
        let quotaValueModeRow = SettingsRowView(
            title: tr(.keyDashboardMenuBarPageQuotaValueMode),
            detail: tr(.keyDashboardMenuBarPageQuotaValueModeDescription),
            accessoryView: quotaValueModeControl
        )
        autoSwitchLunaReserveRow = nil
        lunaReserveResetTimeRow = nil
        let autoSwitchLunaReserveRow: SettingsRowView?
        let lunaReserveResetTimeRow: SettingsRowView?
        if let autoSwitchLunaReserve, let lunaReserveResetTimeModeControl {
            let autoSwitchRow = SettingsRowView(
                title: DashboardSettingsFormattedCopy.autoSwitchLunaReserveTitle(),
                detail: DashboardSettingsFormattedCopy.autoSwitchLunaReserveDescription(),
                accessoryView: autoSwitchLunaReserve
            )
            let resetTimeRow = SettingsRowView(
                title: DashboardSettingsFormattedCopy.lunaReserveResetTimeTitle(),
                detail: DashboardSettingsFormattedCopy.lunaReserveResetTimeDescription(),
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
            detail: DashboardMenuBarPage.requiredDisplayDetail(.keyDashboardMenuBarPageShowsAPercentageOrApiBalance),
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
                amountDisplayRow, quotaValueModeRow, quotaWindowPreferenceRow
            ]
        )
        let resetSection = SettingsSectionView(
            title: "",
            contentViews: [
                resetCountdownRow,
                quotaResetDisplayModeRow,
                autoSwitchLunaReserveRow,
                lunaReserveResetTimeRow
            ].compactMap { $0 }
        )
        updateVisibility(
            showAmount: input.preferences.showMenuBarAmount,
            showReset: input.preferences.showMenuBarReset,
            autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && input.preferences.menuBarAutoSwitchLunaReserve
        )
        return [quotaSection, resetSection]
    }

    func refresh(preferences: AppPreferences) {
        updateVisibility(
            showAmount: preferences.showMenuBarAmount,
            showReset: preferences.showMenuBarReset,
            autoSwitchLunaReserve: LunaReserveUserFacing.isCurrentlyEnabled
                && preferences.menuBarAutoSwitchLunaReserve
        )
        if let quotaValueModeControl,
           let selectedIndex = MenuBarQuotaValueMode.allCases.firstIndex(of: preferences.menuBarQuotaValueMode) {
            if quotaValueModeControl.indexOfSelectedItem != selectedIndex {
                quotaValueModeControl.selectItem(at: selectedIndex)
            }
            quotaValueModeControl.synchronizeTitleAndSelectedItem()
        }
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
        resetCountdownRow?.setDependencyEnabled(showAmount)
        quotaResetDisplayModeRow?.setDependencyEnabled(showAmount && showReset)
        autoSwitchLunaReserveRow?.setDependencyEnabled(showAmount)
        lunaReserveResetTimeRow?.setDependencyEnabled(showAmount && autoSwitchLunaReserve)
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

    private func makeQuotaValueModeControl(
        value: MenuBarQuotaValueMode,
        relay: DashboardPreferencePageRelay
    ) -> NSPopUpButton {
        let control = DashboardSettingsComponents.makePopUpButton(
            identifier: DashboardMenuBarPage.quotaValueModeIdentifier,
            items: MenuBarQuotaValueMode.allCases.map { mode in
                DashboardSettingsComponents.PopUpItem(
                    title: tr(mode == .remaining
                        ? .keyDashboardMenuBarPageQuotaValueRemaining
                        : .keyDashboardMenuBarPageQuotaValueUsed),
                    representedObject: mode.rawValue
                )
            },
            selectedIndex: MenuBarQuotaValueMode.allCases.firstIndex(of: value),
            target: relay,
            action: #selector(DashboardPreferencePageRelay.menuBarQuotaValueMode(_:))
        )
        control.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(108, ceil(control.fittingSize.width))
        ).isActive = true
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
        control.toolTip = DashboardSettingsFormattedCopy.lunaReserveResetTimeDescription()
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
        DashboardSettingsFormattedCopy.lunaReserveResetTimeModeTitle(mode)
    }
}
