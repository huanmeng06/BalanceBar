import AppKit

struct DashboardPreferencePageActions {
    let onToggle: (String, Bool) -> Void
    let onInterval: (String, TimeInterval) -> Void
    let onBalanceDisplayThresholdChanged: (Double) -> Void
    let onOffsetAdjust: (String, Int) -> Void
    let onOffsetValue: (String, Double) -> Void
    let onOffsetValueEnded: (String, Double) -> Void
    let onOffsetReset: (String) -> Void
    let onLanguage: (AppLanguage) -> Void
    let onMenuBarFontSizePreset: (MenuBarFontSizePreset) -> Void
    let onMenuBarIconDisplayModeChanged: (MenuBarIconDisplayMode) -> Void
    let onMenuBarIconDisplayDelayChanged: (MenuBarIconDisplayDelay) -> Void
    let onMenuBarQuotaWindowPreferenceChanged: (OfficialQuotaWindowPreference) -> Void
    let onMenuBarQuotaResetDisplayModeChanged: (OfficialQuotaResetDisplayMode) -> Void
    let onUpdateChannelChanged: (UpdateChannel) -> Void
    let onOpenCCSwitch: () -> Void
    let onOpenSystemMenuBarSettings: () -> Void
    let onManualRefresh: () -> Void
    let onCheckForUpdates: () -> Void
    let onInstallUpdate: () -> Void
    let onIgnoreUpdate: () -> Void
    let onOpenUpdateNotes: () -> Void
    let onOpenOpenCodex: () -> Void
    let makeStatusLinksEditor: () -> StatusLinksEditorHostingView
    let onOpenCodexModeChanged: (OpenCodexDashboardMode) -> Void
    let onClamp: () -> Void
}

final class DashboardPreferencePages {
    private let preferences: AppPreferences
    private let devBundleIdentifier: String
    private let actions: DashboardPreferencePageActions
    private let relay = DashboardPreferencePageRelay()
    private let generalPage = DashboardGeneralPage()
    private let menuPage = DashboardMenuPage()
    private let menuBarPage = DashboardMenuBarPage()
    private let advancedPage = DashboardAdvancedPage()
    private let logsPage = DashboardLogsPage()

    init(preferences: AppPreferences, devBundleIdentifier: String, actions: DashboardPreferencePageActions) {
        self.preferences = preferences
        self.devBundleIdentifier = devBundleIdentifier
        self.actions = actions
        relay.onToggle = actions.onToggle
        relay.onInterval = actions.onInterval
        relay.onOffsetAdjust = actions.onOffsetAdjust
        relay.onOffsetValue = actions.onOffsetValue
        relay.onOffsetValueEnded = actions.onOffsetValueEnded
        relay.onOffsetReset = actions.onOffsetReset
        relay.onLanguage = actions.onLanguage
        relay.onMenuBarFontSizePreset = actions.onMenuBarFontSizePreset
        relay.onMenuBarIconDisplayModeChanged = actions.onMenuBarIconDisplayModeChanged
        relay.onMenuBarIconDisplayDelayChanged = actions.onMenuBarIconDisplayDelayChanged
        relay.onMenuBarQuotaWindowPreferenceChanged = actions.onMenuBarQuotaWindowPreferenceChanged
        relay.onMenuBarQuotaResetDisplayModeChanged = actions.onMenuBarQuotaResetDisplayModeChanged
        relay.onUpdateChannelChanged = actions.onUpdateChannelChanged
        relay.onOpenCCSwitch = actions.onOpenCCSwitch
        relay.onOpenSystemMenuBarSettings = actions.onOpenSystemMenuBarSettings
        relay.onManualRefresh = actions.onManualRefresh
        relay.onCheckForUpdates = actions.onCheckForUpdates
        relay.onInstallUpdate = actions.onInstallUpdate
        relay.onIgnoreUpdate = actions.onIgnoreUpdate
        relay.onOpenUpdateNotes = actions.onOpenUpdateNotes
        relay.onOpenOpenCodex = actions.onOpenOpenCodex
        relay.onRevealLog = { [weak self] in self?.logsPage.reveal() }
        relay.onRefreshLog = { [weak self] in self?.logsPage.refresh() }
    }

    func makePage(
        for section: DashboardSection,
        currentProviderName: String,
        providerPollInterval: TimeInterval,
        snapshot: Snapshot,
        menuBarSnapshot: @escaping (Snapshot) -> Snapshot,
        statusItemVisibility: StatusItemVisibility,
        iconImage: NSImage?,
        currentOpenCodexResolution: OpenCodexDashboardResolution?,
        runtimeCandidate: OpenCodexEndpointCandidate?,
        updateState: UpdateCheckState
    ) -> NSView {
        switch section {
        case .general:
            return generalPage.make(.init(
                preferences: preferences,
                currentProviderName: currentProviderName,
                relay: relay,
                updateState: updateState
            ))
        case .menuBar:
            return menuBarPage.make(.init(
                preferences: preferences,
                snapshot: snapshot,
                menuBarSnapshot: menuBarSnapshot,
                iconImage: iconImage,
                relay: relay,
                statusItemVisibility: statusItemVisibility
            ))
        case .menu:
            return menuPage.make(.init(
                preferences: preferences,
                relay: relay,
                makeStatusLinksEditor: actions.makeStatusLinksEditor,
                onBalanceDisplayThresholdChanged: actions.onBalanceDisplayThresholdChanged
            ))
        case .advanced:
            return advancedPage.make(.init(
                preferences: preferences,
                mode: OpenCodexDashboardMode(
                    automaticDetection: preferences.openCodexDashboardAutomaticDetection,
                    manualPort: preferences.openCodexDashboardPortOverride
                ),
                currentResolution: currentOpenCodexResolution,
                runtimeCandidate: runtimeCandidate,
                relay: relay,
                logViewer: logsPage.makeViewer(),
                onModeChanged: actions.onOpenCodexModeChanged,
                onClamp: actions.onClamp
            ))
        case .about:
            return DashboardAboutPage.make(
                devBundleIdentifier: devBundleIdentifier
            )
        }
    }

    func refreshMenuBar(
        snapshot: Snapshot,
        menuBarSnapshot: @escaping (Snapshot) -> Snapshot,
        statusItemVisibility: StatusItemVisibility,
        iconImage: NSImage?
    ) {
        menuBarPage.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: menuBarSnapshot,
            iconImage: iconImage,
            statusItemVisibility: statusItemVisibility
        )
    }

    func updateMenuBarPreviewIcon(_ image: NSImage?) {
        menuBarPage.updatePreviewIcon(image)
    }

    func refreshMenuBarWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        menuBarPage.refreshWidthAdjustment(
            widthAdjustment,
            horizontalPadding: horizontalPadding
        )
    }

    func finishMenuBarWidthAdjustment(
        _ widthAdjustment: Double,
        horizontalPadding: CGFloat
    ) {
        menuBarPage.finishWidthAdjustment(
            widthAdjustment,
            horizontalPadding: horizontalPadding
        )
    }

    func restoreRequiredMenuBarToggle(identifier: String) {
        menuBarPage.restoreRequiredToggle(identifier: identifier)
    }

    func refreshAdvanced(
        currentOpenCodexResolution: OpenCodexDashboardResolution?,
        runtimeCandidate: OpenCodexEndpointCandidate?
    ) {
        advancedPage.refresh(
            currentResolution: currentOpenCodexResolution,
            runtimeCandidate: runtimeCandidate
        )
    }

    func refreshLogs() {
        logsPage.refresh()
    }

    func refreshUpdateState(_ updateState: UpdateCheckState) {
        generalPage.refresh(updateState: updateState)
    }

    func revealLogs() {
        logsPage.reveal()
    }

    func handleAutomaticDetection(_ enabled: Bool) {
        advancedPage.handleAutomaticDetection(enabled)
    }

    func updateMenuStatusVisibility(_ visible: Bool, animated: Bool) {
        menuPage.updateStatusVisibility(visible, animated: animated)
    }

    func teardown() {
        menuBarPage.teardown()
        menuPage.teardown()
    }
}
