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
        let egressGuard: ClaudeEgressGuardPageActions

        init(
            relay: DashboardPreferencePageRelay,
            logViewer: NSView?,
            includeLogViewer: Bool = true,
            preferences: AppPreferences = AppPreferences(),
            sourceTimeline: @escaping () -> ClaudeSourceTimelineView.Content = { .empty },
            egressGuard: ClaudeEgressGuardPageActions = ClaudeEgressGuardPageActions()
        ) {
            self.egressGuard = egressGuard
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
    private(set) var egressGuardSection: ClaudeEgressGuardSectionController?

    /// Re-reads the egress guard settings without rebuilding the cached page.
    func refreshEgressGuard(preferences: AppPreferences) {
        egressGuardSection?.refresh(preferences: preferences)
    }

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
        let calibrationMinutes = String(max(1, Int(ceil(calibrationInterval / 60))))
        // Only recommend a value the popup actually offers.
        guard let option = AppPreferences.claudeLocalValidityOptions.sorted().first(where: { $0 >= threshold }) else {
            return tr(.keyDashboardAdvancedPageSourceValidityNoOption, arguments: [calibrationMinutes])
        }
        return tr(.keyDashboardAdvancedPageSourceValidityWarning, arguments: [
            calibrationMinutes, String(Int(option / 60))
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
        let egressGuard = ClaudeEgressGuardSectionController(
            preferences: input.preferences, relay: input.relay, actions: input.egressGuard)
        egressGuardSection = egressGuard
        return DashboardSettingsComponents.makeSettingsPageContent([
            makeSourceValiditySection(input), egressGuard.makeSection(), logs,
        ])
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

/// Callbacks for the Claude egress guard section (Issue #686). The switch itself goes through
/// the shared toggle relay; these cover the allowed-IP list and the detect button.
struct ClaudeEgressGuardPageActions {
    /// Persists the edited allowed-IP list (already validated and de-duplicated).
    var setAllowedIPs: ([String]) -> Void = { _ in }
    /// Probes the current egress IP through the Claude proxy route; completes on any queue.
    var detectEgressIP: (@escaping (Result<String, OfficialQuotaTransportError>) -> Void) -> Void = {
        $0(.failure(.unknown))
    }
}

/// Owns the egress guard section's controls: the switch, the allowed-IP row, the add field and
/// the detect row. Every row is a direct section row, so settings search shows and hides them like
/// any other; a list change only updates the allowed-IP row's text and its remove menu.
final class ClaudeEgressGuardSectionController: NSObject {
    static let addFieldIdentifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.addField")
    static let removeMenuIdentifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.remove")
    static let detectButtonIdentifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.detect")
    static let addDetectedButtonIdentifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.addDetected")

    private let actions: ClaudeEgressGuardPageActions
    private var allowedIPs: [String]
    private let toggle: NSSwitch
    /// Pull-down listing each allowed IP; choosing one removes it.
    let removeMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var listRow: SettingsRowView!
    let addField = NSTextField(string: "")
    private(set) var addRow: SettingsRowView!
    private(set) var detectRow: SettingsRowView!
    let detectButton = NSButton(title: "", target: nil, action: nil)
    let addDetectedButton = NSButton(title: "", target: nil, action: nil)
    private var detectedIP: String?
    private var detectGeneration = 0

    init(preferences: AppPreferences, relay: DashboardPreferencePageRelay, actions: ClaudeEgressGuardPageActions) {
        self.actions = actions
        allowedIPs = preferences.claudeEgressGuardAllowedIPs
        toggle = DashboardSettingsComponents.makeSwitch(
            identifier: AppPreferences.claudeEgressGuardEnabledKey,
            isOn: preferences.claudeEgressGuardEnabled,
            target: relay,
            action: #selector(DashboardPreferencePageRelay.toggle(_:)))
        super.init()
    }

    func makeSection() -> SettingsSectionView {
        let toggleRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageEgressGuardEnabled),
            detail: tr(.keyDashboardAdvancedPageEgressGuardEnabledDetail),
            titleAccessory: DashboardRefreshPage.agentIconStrip(["Claude"]),
            accessoryView: toggle)

        removeMenu.identifier = Self.removeMenuIdentifier
        removeMenu.target = self
        removeMenu.action = #selector(removeSelectedIP(_:))
        listRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageEgressGuardAllowed),
            detail: " ",
            accessoryView: removeMenu)
        rebuildList()

        addField.identifier = Self.addFieldIdentifier
        addField.placeholderString = tr(.keyDashboardAdvancedPageEgressGuardAddPlaceholder)
        addField.isBezeled = true
        addField.bezelStyle = .roundedBezel
        addField.target = self
        addField.action = #selector(addTypedIP)
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let addButton = NSButton(title: tr(.keyDashboardAdvancedPageEgressGuardAdd), target: self, action: #selector(addTypedIP))
        addRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageEgressGuardAddTitle),
            accessoryView: Self.hStack([addField, addButton]))

        detectButton.title = tr(.keyDashboardAdvancedPageEgressGuardDetect)
        detectButton.identifier = Self.detectButtonIdentifier
        detectButton.target = self
        detectButton.action = #selector(detect)
        addDetectedButton.title = tr(.keyDashboardAdvancedPageEgressGuardAddDetected)
        addDetectedButton.identifier = Self.addDetectedButtonIdentifier
        addDetectedButton.target = self
        addDetectedButton.action = #selector(addDetectedIP)
        addDetectedButton.isHidden = true
        detectRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageEgressGuardDetectTitle),
            accessoryView: Self.hStack([addDetectedButton, detectButton]))

        return SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageEgressGuard),
            contentViews: [toggleRow, listRow, addRow, detectRow],
            footnote: tr(.keyDashboardAdvancedPageEgressGuardFootnote))
    }

    /// Re-reads the saved settings (after a change from the other page copy or the app).
    func refresh(preferences: AppPreferences) {
        toggle.state = preferences.claudeEgressGuardEnabled ? .on : .off
        let saved = preferences.claudeEgressGuardAllowedIPs
        guard saved != allowedIPs else { return }
        allowedIPs = saved
        rebuildList()
        updateDetectedRow()
    }

    private func rebuildList() {
        listRow.updateDetail(allowedIPs.isEmpty
            ? tr(.keyDashboardAdvancedPageEgressGuardAllowedEmpty)
            : allowedIPs.joined(separator: ", "))
        removeMenu.removeAllItems()
        // A pull-down shows its first item as the button title.
        removeMenu.addItem(withTitle: tr(.keyDashboardAdvancedPageEgressGuardRemove))
        for ip in allowedIPs {
            removeMenu.addItem(withTitle: ip)
            removeMenu.lastItem?.representedObject = ip
        }
        removeMenu.isHidden = allowedIPs.isEmpty
    }

    private func save(_ ips: [String]) {
        let sanitized = EgressIPAddress.sanitizedList(ips)
        allowedIPs = sanitized
        rebuildList()
        updateDetectedRow()
        actions.setAllowedIPs(sanitized)
    }

    @objc private func addTypedIP() {
        let text = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard EgressIPAddress.isValid(text) else {
            addRow.updateDetail(tr(.keyDashboardAdvancedPageEgressGuardInvalidIp))
            addRow.detailLabel.textColor = .systemOrange
            return
        }
        addRow.updateDetail(nil)
        addField.stringValue = ""
        save(allowedIPs + [text])
    }

    @objc private func removeSelectedIP(_ sender: NSPopUpButton) {
        guard let ip = sender.selectedItem?.representedObject as? String else { return }
        remove(ip)
    }

    private func remove(_ ip: String) {
        save(allowedIPs.filter { $0 != ip })
    }

    @objc private func addDetectedIP() {
        guard let detectedIP else { return }
        save(allowedIPs + [detectedIP])
    }

    @objc private func detect() {
        detectGeneration += 1
        let generation = detectGeneration
        detectedIP = nil
        detectButton.isEnabled = false
        addDetectedButton.isHidden = true
        detectRow.updateDetail(tr(.keyDashboardAdvancedPageEgressGuardDetecting))
        detectRow.detailLabel.textColor = .secondaryLabelColor
        actions.detectEgressIP { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.detectGeneration else { return }
                self.detectButton.isEnabled = true
                switch result {
                case let .success(ip):
                    self.detectedIP = ip
                    self.updateDetectedRow()
                case .failure:
                    self.detectRow.updateDetail(tr(.keyDashboardAdvancedPageEgressGuardDetectFailed))
                    self.detectRow.detailLabel.textColor = .systemOrange
                }
            }
        }
    }

    private func updateDetectedRow() {
        guard let detectedIP else { return }
        let listed = EgressIPAddress.contains(allowedIPs, detectedIP)
        detectRow.updateDetail(tr(
            listed ? .keyDashboardAdvancedPageEgressGuardDetectedListedValue
                : .keyDashboardAdvancedPageEgressGuardDetectedUnlistedValue,
            arguments: [detectedIP]))
        detectRow.detailLabel.textColor = listed ? .secondaryLabelColor : .systemOrange
        addDetectedButton.isHidden = listed
    }

    private static func hStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .vertical)
        return stack
    }

    // MARK: Testing

    func addForTesting(_ text: String) {
        addField.stringValue = text
        addTypedIP()
    }

    func removeForTesting(_ ip: String) {
        guard let index = removeMenu.itemArray.firstIndex(where: { $0.representedObject as? String == ip }) else { return }
        removeMenu.selectItem(at: index)
        removeSelectedIP(removeMenu)
    }

    func detectForTesting() { detect() }
    func addDetectedForTesting() { addDetectedIP() }
    var allowedIPsForTesting: [String] { allowedIPs }
    var addDetailForTesting: String { addRow.detailLabel.stringValue }
    var listDetailForTesting: String { listRow.detailLabel.stringValue }
    var detectDetailForTesting: String { detectRow.detailLabel.stringValue }
}
