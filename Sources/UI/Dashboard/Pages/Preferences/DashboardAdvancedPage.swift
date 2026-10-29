import AppKit

final class DashboardAdvancedPage {
    static let logViewerHeight: CGFloat = 190
    static let logViewerHostIdentifier = NSUserInterfaceItemIdentifier(
        "dashboard.advanced.logViewer"
    )

    struct Input {
        let relay: DashboardPreferencePageRelay
        let logViewer: NSView?
        let includeLogViewer: Bool
        let preferences: AppPreferences
        /// Recent Claude source activity and the card's current status for the timeline.
        let sourceTimeline: () -> ClaudeSourceTimelineView.Content

        init(
            relay: DashboardPreferencePageRelay,
            logViewer: NSView?,
            includeLogViewer: Bool = true,
            preferences: AppPreferences = AppPreferences(),
            sourceTimeline: @escaping () -> ClaudeSourceTimelineView.Content = { .empty }
        ) {
            self.relay = relay
            self.logViewer = logViewer
            self.includeLogViewer = includeLogViewer
            self.preferences = preferences
            self.sourceTimeline = sourceTimeline
        }
    }

    /// The official-validity selector, kept so a calibration-interval change on the Refresh page can
    /// update its choices without rebuilding the cached page.
    private weak var oauthValidityPopup: NSPopUpButton?
    private weak var sourceTimelineView: ClaudeSourceTimelineView?
    private var sourceValidityRows: [String: SettingsRowView] = [:]

    /// Redraws the source timeline after a new reading, failure, status or validity change.
    /// A page that is not on screen skips it; the view reloads itself when it enters a window.
    func refreshSourceTimeline() {
        guard let view = sourceTimelineView, view.window != nil else { return }
        view.reload()
    }

    /// Moves the timeline to the current display time zone; the cached page is not rebuilt.
    func refreshDisplayTimeZone(_ timeZone: TimeZone) {
        sourceTimelineView?.updateTimeZone(timeZone)
    }

    /// Re-lists the official-validity choices (never shorter than the calibration interval) and
    /// selects the effective value.
    func refreshOAuthValidity(preferences: AppPreferences) {
        guard let popup = oauthValidityPopup else { return }
        let choices = preferences.claudeOAuthValidityChoices
        let selected = preferences.claudeOAuthValidity
        popup.removeAllItems()
        for value in choices {
            popup.addItem(withTitle: Self.validityTitle(value))
            popup.lastItem?.representedObject = NSNumber(value: value)
        }
        if let index = choices.firstIndex(where: { abs($0 - selected) < 0.001 }) {
            popup.selectItem(at: index)
        }
        refreshSourceValidityWarnings(preferences: preferences)
    }

    /// Updates the local-source warning without rebuilding the cached Advanced page.
    func refreshSourceValidityWarnings(preferences: AppPreferences) {
        let values: [(String, TimeInterval)] = [
            (AppPreferences.claudeModValidityKey, preferences.claudeModValidity),
        ]
        for (key, value) in values {
            guard let row = sourceValidityRows[key] else { continue }
            let detail: String?
            if preferences.claudeLocalValidityMayGap(value) {
                detail = Self.validityWarning(calibrationInterval: preferences.claudeCalibrationInterval)
            } else {
                detail = nil
            }
            row.updateDetail(detail)
            row.detailLabel.textColor = detail == nil ? .secondaryLabelColor : .systemOrange
        }
    }

    /// Warning copy for a given official calibration interval; shared with the settings search corpus.
    static func validityWarning(calibrationInterval: TimeInterval) -> String {
        let threshold = calibrationInterval
            + AppPreferences.claudeValidityPrefetchLead
            + AppPreferences.claudeValiditySchedulingSlack
        return tr(.keyDashboardAdvancedPageSourceValidityWarning, arguments: [
            String(max(1, Int(ceil(calibrationInterval / 60)))),
            String(max(1, Int(ceil(threshold / 60))))
        ])
    }

    private static func validityTitle(_ seconds: TimeInterval) -> String {
        tr(.keyDashboardAdvancedPageValidityMinutes, arguments: [String(Int(seconds / 60))])
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
        let exportLog = NSButton(
            title: tr(.keyDashboardLogsPageExport),
            target: input.relay,
            action: #selector(DashboardPreferencePageRelay.exportLog(_:))
        )
        let logButtons = NSStackView(views: [refreshLog, revealLog, exportLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        logButtons.setHuggingPriority(.required, for: .horizontal)
        logButtons.setClippingResistancePriority(.required, for: .horizontal)
        logButtons.setContentHuggingPriority(.required, for: .horizontal)
        logButtons.setContentCompressionResistancePriority(.required, for: .horizontal)
        logButtons.setContentHuggingPriority(.required, for: .vertical)
        let debugLogRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageDebugLog),
            detail: tr(.keyDashboardAdvancedPageRecordsRuntimeStatusAndErrors),
            accessoryView: logButtons
        )
        var contentViews: [NSView] = [debugLogRow]
        if input.includeLogViewer, let logViewer = input.logViewer {
            contentViews.append(Self.makePinnedLogViewer(logViewer))
        }
        let logs = SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageDiagnostics),
            contentViews: contentViews
        )
        return DashboardSettingsComponents.makeSettingsPageContent([makeSourceValiditySection(input), logs])
    }

    /// How long a reading from each Claude source counts as valid: it drives the card's status
    /// (live vs "N 分钟前") and whether local readings let BalanceBar skip official requests.
    func makeSourceValiditySection(_ input: Input) -> SettingsSectionView {
        let minutes = Self.validityTitle
        func popup(_ key: String, _ options: [TimeInterval], _ selected: TimeInterval) -> NSPopUpButton {
            DashboardSettingsComponents.makeIntervalPopUpButton(
                values: options.map { ($0, minutes($0)) },
                selected: selected,
                identifier: key,
                target: input.relay,
                action: #selector(DashboardPreferencePageRelay.interval(_:)))
        }
        let validity = input.preferences.claudeSourceValidity
        let popups = [
            popup(AppPreferences.claudeOAuthValidityKey, input.preferences.claudeOAuthValidityChoices, validity.oauth),
            popup(AppPreferences.claudeModValidityKey, AppPreferences.claudeLocalValidityOptions, validity.mod)
        ]
        oauthValidityPopup = popups[0]
        // The two selectors share one right-aligned column of identical width.
        let width = ceil(max(108, popups.map { $0.fittingSize.width }.max() ?? 108))
        let controls = popups.map { popup -> NSStackView in
            popup.translatesAutoresizingMaskIntoConstraints = false
            for constraint in popup.constraints where constraint.firstAttribute == .width {
                constraint.priority = .defaultHigh
            }
            let preferredWidth = popup.widthAnchor.constraint(equalToConstant: width)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
            let stack = NSStackView(views: [popup])
            stack.orientation = .vertical
            stack.alignment = .trailing
            return stack
        }
        // The live timeline replaces the old rules footnote (Issue #619).
        let timeline = ClaudeSourceTimelineView(
            provider: input.sourceTimeline, timeZone: input.preferences.effectiveDisplayTimeZone)
        sourceTimelineView = timeline
        let rows = [
            SettingsRowView(
                title: tr(.keyDashboardAdvancedPageSourceValidityOauth),
                titleAccessory: DashboardRefreshPage.agentIconStrip(["Claude"]),
                accessoryView: controls[0]),
            SettingsRowView(
                title: tr(.keyDashboardAdvancedPageSourceValidityMod),
                titleAccessory: DashboardRefreshPage.agentIconStrip(["Claude"]),
                accessoryView: controls[1]),
        ]
        sourceValidityRows = [
            AppPreferences.claudeModValidityKey: rows[1],
        ]
        refreshSourceValidityWarnings(preferences: input.preferences)
        return SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageSourceValidity),
            contentViews: rows,
            footerView: timeline)
    }

    /// Keeps the Diagnostics log pane at the historical 190pt slot. The real
    /// viewer hosts a vertically resizable `NSTextView` whose intrinsic /
    /// document height is the full log; without a required host height the
    /// native section card grows with that document instead of scrolling.
    static func makePinnedLogViewer(_ viewer: NSView) -> NSView {
        let host = NSView()
        host.identifier = logViewerHostIdentifier
        host.translatesAutoresizingMaskIntoConstraints = false
        host.clipsToBounds = true
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        host.heightAnchor.constraint(equalToConstant: logViewerHeight).isActive = true

        if viewer.superview != nil {
            viewer.removeFromSuperview()
        }
        viewer.translatesAutoresizingMaskIntoConstraints = false
        suppressVerticalIntrinsicGrowth(viewer)
        host.addSubview(viewer)
        NSLayoutConstraint.activate([
            viewer.topAnchor.constraint(equalTo: host.topAnchor),
            viewer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return host
    }

    private static func suppressVerticalIntrinsicGrowth(_ view: NSView) {
        view.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        for subview in view.subviews {
            // Leave the clip view and document frame-based so extra log text
            // can scroll inside the 190pt slot instead of being compressed.
            if subview is NSClipView {
                continue
            }
            suppressVerticalIntrinsicGrowth(subview)
        }
    }
}
