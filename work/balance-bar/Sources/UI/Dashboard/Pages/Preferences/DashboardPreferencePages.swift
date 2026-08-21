import AppKit

struct DashboardPreferencePageActions {
    let onToggle: (String, Bool) -> Void
    let onInterval: (String, TimeInterval) -> Void
    let onOffsetAdjust: (String, Int) -> Void
    let onOffsetReset: (String) -> Void
    let onLanguage: (AppLanguage) -> Void
    let onOpenCCSwitch: () -> Void
    let onManualRefresh: () -> Void
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
        relay.onOffsetReset = actions.onOffsetReset
        relay.onLanguage = actions.onLanguage
        relay.onOpenCCSwitch = actions.onOpenCCSwitch
        relay.onManualRefresh = actions.onManualRefresh
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
        iconImage: NSImage?,
        currentOpenCodexResolution: OpenCodexDashboardResolution?,
        runtimeCandidate: OpenCodexEndpointCandidate?
    ) -> NSView {
        switch section {
        case .general:
            return DashboardGeneralPage.make(.init(
                preferences: preferences,
                currentProviderName: currentProviderName,
                relay: relay
            ))
        case .menuBar:
            return menuBarPage.make(.init(
                preferences: preferences,
                snapshot: snapshot,
                menuBarSnapshot: menuBarSnapshot,
                iconImage: iconImage,
                relay: relay
            ))
        case .menu:
            return menuPage.make(.init(
                preferences: preferences,
                relay: relay,
                makeStatusLinksEditor: actions.makeStatusLinksEditor
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
        iconImage: NSImage?
    ) {
        menuBarPage.refresh(
            snapshot: snapshot,
            preferences: preferences,
            menuBarSnapshot: menuBarSnapshot,
            iconImage: iconImage
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
        menuPage.teardown()
    }
}
