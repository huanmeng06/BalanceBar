import AppKit

final class DashboardAdvancedPage {
    struct Input {
        let relay: DashboardPreferencePageRelay
        let logViewer: NSView
    }

    func make(_ input: Input) -> NSView {
        let refreshLog = NSButton(
            title: tr(.keyDashboardAdvancedPageReload),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.refreshLog(_:))
        )
        let revealLog = NSButton(
            title: tr(.keyDashboardAdvancedPageShowInFinder),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.revealLog(_:))
        )
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        let debugLogRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageDebugLog),
            detail: tr(.keyDashboardAdvancedPageRecordsRuntimeStatusAndErrors),
            accessoryView: logButtons
        )
        let logs = SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageDiagnostics),
            contentViews: [debugLogRow, input.logViewer]
        )
        return DashboardSettingsComponents.makeSettingsPageContent([logs])
    }
}
