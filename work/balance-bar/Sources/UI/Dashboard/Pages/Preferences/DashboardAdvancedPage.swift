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
        let logs = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardAdvancedPageDiagnostics), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardAdvancedPageDebugLog),
                subtitle: tr(.keyDashboardAdvancedPageRecordsRuntimeStatusAndErrors),
                control: logButtons
            ),
            input.logViewer
        ])
        return DashboardSettingsComponents.makeSettingsPage([logs])
    }
}
