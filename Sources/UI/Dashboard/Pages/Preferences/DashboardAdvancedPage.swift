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
    /// Persists the edited allowlist (already validated and de-duplicated).
    var setAllowedIPs: ([String]) -> Void = { _ in }
    /// Probes the current egress IP through the Claude proxy route; completes on any queue.
    var detectEgressIP: (@escaping (Result<String, OfficialQuotaTransportError>) -> Void) -> Void = {
        $0(.failure(.unknown))
    }
    /// Country code already known for an allowlisted IP, without any network request.
    var cachedCountry: (String) -> String? = { _ in nil }
    /// Looks the country up on ipinfo.io (once per address); completes on any queue.
    var lookupCountry: (String, @escaping (String?) -> Void) -> Void = { $1(nil) }
}

/// Owns the IP allowlist section: the switch, then the allowlist table whose bottom bar carries
/// the current-egress check. Both are direct section rows, so settings search shows and hides them
/// like any other. With the switch off the table stays visible but dimmed, like System Settings.
final class ClaudeEgressGuardSectionController: NSObject {
    private let actions: ClaudeEgressGuardPageActions
    private var allowedIPs: [String]
    private let toggle: NSSwitch
    private(set) var listEditor: EgressIPListEditorView!
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

        let editor = EgressIPListEditorView(
            ips: allowedIPs,
            cachedCountry: actions.cachedCountry,
            lookupCountry: actions.lookupCountry,
            onSave: { [weak self] ips in self?.save(ips) })
        editor.detectButton.target = self
        editor.detectButton.action = #selector(detect)
        editor.addDetectedButton.target = self
        editor.addDetectedButton.action = #selector(addDetectedIP)
        editor.setEnabled(toggle.state == .on)
        listEditor = editor

        return SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageEgressGuard),
            contentViews: [toggleRow, editor],
            footnote: tr(.keyDashboardAdvancedPageEgressGuardFootnote))
    }

    /// Re-reads the saved settings (after a change from the other page copy or the app).
    func refresh(preferences: AppPreferences) {
        toggle.state = preferences.claudeEgressGuardEnabled ? .on : .off
        listEditor?.setEnabled(preferences.claudeEgressGuardEnabled)
        let saved = preferences.claudeEgressGuardAllowedIPs
        guard saved != allowedIPs else { return }
        allowedIPs = saved
        listEditor?.updateSavedIPs(saved)
        updateDetectedStatus()
    }

    private func save(_ ips: [String]) {
        let sanitized = EgressIPAddress.sanitizedList(ips)
        guard sanitized != allowedIPs else { return }
        allowedIPs = sanitized
        updateDetectedStatus()
        actions.setAllowedIPs(sanitized)
    }

    @objc private func addDetectedIP() {
        guard let detectedIP else { return }
        listEditor.append(detectedIP)
    }

    @objc private func detect() {
        detectGeneration += 1
        let generation = detectGeneration
        detectedIP = nil
        listEditor.detectButton.isEnabled = false
        listEditor.addDetectedButton.isHidden = true
        listEditor.showStatus(.detecting)
        actions.detectEgressIP { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.detectGeneration else { return }
                self.listEditor.detectButton.isEnabled = self.listEditor.isEnabled
                switch result {
                case let .success(ip):
                    self.detectedIP = ip
                    self.updateDetectedStatus()
                case .failure:
                    self.listEditor.showStatus(.failed)
                }
            }
        }
    }

    private func updateDetectedStatus() {
        guard let detectedIP else { return }
        let listed = EgressIPAddress.contains(allowedIPs, detectedIP)
        listEditor.showStatus(listed ? .listed(detectedIP) : .unlisted(detectedIP))
        listEditor.addDetectedButton.isHidden = listed
    }

    // MARK: Testing

    func detectForTesting() { detect() }
    func addDetectedForTesting() { addDetectedIP() }
    var allowedIPsForTesting: [String] { allowedIPs }
    var detectButton: NSButton { listEditor.detectButton }
    var addDetectedButton: NSButton { listEditor.addDetectedButton }
    var detectDetailForTesting: String { listEditor.statusLabel.stringValue }
}

/// Native editor for the IP allowlist, following the status links editor: a title, a bordered
/// two-column `NSTableView` (IP address, country/region) whose addresses are edited in place, and a
/// bottom bar with +/− and the current-egress check. The table grows with its rows (2…6, then
/// scrolls). Text that is not a valid address stays in the table, tinted orange, and is never saved.
final class EgressIPListEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Status: Equatable {
        case none
        case detecting
        case listed(String)
        case unlisted(String)
        case failed
    }

    static let rowHeight: CGFloat = 24
    static let minimumVisibleRows = 2
    static let maximumVisibleRows = 6
    static let cornerRadius: CGFloat = 10
    static let titleTopInset: CGFloat = 12
    static let tableTopSpacing: CGFloat = 8
    static let barTopSpacing: CGFloat = 8
    static let barHeight: CGFloat = 24
    static let bottomInset: CGFloat = 14

    private let cachedCountry: (String) -> String?
    private let lookupCountry: (String, @escaping (String?) -> Void) -> Void
    private let onSave: ([String]) -> Void
    /// What the table shows: saved addresses plus any invalid text still being fixed.
    private(set) var rows: [String]
    private(set) var isEnabled = true
    private var requestedCountries: Set<String> = []
    private var status: Status = .none

    let titleLabel = NSTextField(labelWithString: tr(.keyDashboardAdvancedPageEgressGuardAllowed))
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let tableContainer = NSBox()
    let emptyLabel = NSTextField(labelWithString: tr(.keyDashboardAdvancedPageEgressGuardAllowedEmpty))
    let actionsControl = NSSegmentedControl()
    let statusIcon = NSImageView()
    let statusLabel = NSTextField(labelWithString: "")
    let addDetectedButton = NSButton(title: tr(.keyDashboardAdvancedPageEgressGuardAddDetected), target: nil, action: nil)
    let detectButton = NSButton(title: tr(.keyDashboardAdvancedPageEgressGuardDetect), target: nil, action: nil)
    private let ipColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("egressGuard.ip.column"))
    private let countryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("egressGuard.country.column"))
    private var tableHeightConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    init(
        ips: [String],
        cachedCountry: @escaping (String) -> String? = { _ in nil },
        lookupCountry: @escaping (String, @escaping (String?) -> Void) -> Void = { $1(nil) },
        onSave: @escaping ([String]) -> Void
    ) {
        rows = ips
        self.cachedCountry = cachedCountry
        self.lookupCountry = lookupCountry
        self.onSave = onSave
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.list")
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        configureTable()
        configureScrollView()
        configureContainer()
        configureEmptyLabel()
        configureActions()
        configureBar()

        let bar = NSStackView(views: [actionsControl, statusIcon, statusLabel, addDetectedButton, detectButton])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 6
        bar.setCustomSpacing(12, after: actionsControl)
        bar.setCustomSpacing(12, after: statusLabel)
        bar.setCustomSpacing(8, after: addDetectedButton)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(titleLabel)
        addSubview(tableContainer)
        addSubview(bar)
        tableHeightConstraint = tableContainer.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.titleTopInset),

            tableContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            tableContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            tableContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Self.tableTopSpacing),
            tableHeightConstraint,

            bar.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            bar.topAnchor.constraint(equalTo: tableContainer.bottomAnchor, constant: Self.barTopSpacing),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            actionsControl.heightAnchor.constraint(equalToConstant: Self.barHeight),

            heightConstraint,
        ])
        updateHeights()
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }

    var headerHeight: CGFloat { tableView.headerView?.frame.height ?? 0 }

    /// Rows the table is tall enough to show without scrolling.
    var visibleRowCount: Int {
        min(max(rows.count, Self.minimumVisibleRows), Self.maximumVisibleRows)
    }

    // MARK: Public updates

    /// The saved list changed elsewhere (the other page copy); keep invalid rows the user is still
    /// fixing only when the saved list already matches what the table holds.
    func updateSavedIPs(_ saved: [String]) {
        guard EgressIPAddress.sanitizedList(rows) != saved else { return }
        finishEditing()
        rows = saved
        reloadRows()
    }

    /// Appends an address (from the detected egress) and saves it.
    func append(_ ip: String) {
        finishEditing()
        guard !EgressIPAddress.contains(rows.filter { !isInvalid($0) && !$0.isEmpty }, ip) else { return }
        rows.append(ip)
        reloadRows()
        applySelection(rows.count - 1)
        save()
    }

    /// With the switch off everything below it stays visible but dimmed and inert.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if !enabled { finishEditing() }
        isEnabled = enabled
        tableView.isEnabled = enabled
        tableView.reloadData()
        titleLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        detectButton.isEnabled = enabled
        addDetectedButton.isEnabled = enabled
        actionsControl.isEnabled = enabled
        statusLabel.textColor = enabled ? statusColor : .disabledControlTextColor
        statusIcon.alphaValue = enabled ? 1 : 0.4
        emptyLabel.textColor = enabled ? .secondaryLabelColor : .disabledControlTextColor
        updateState()
    }

    func showStatus(_ status: Status) {
        self.status = status
        updateStatusLine()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let isIP = tableColumn.identifier == ipColumn.identifier
        let cellIdentifier = NSUserInterfaceItemIdentifier(isIP ? "egressGuard.ip.cell" : "egressGuard.country.cell")
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: cellIdentifier, editable: isIP)
        guard let field = cell.textField else { return cell }
        let value = rows[row]
        if isIP {
            field.identifier = NSUserInterfaceItemIdentifier("egressGuard.ip.\(row)")
            field.stringValue = value
            field.isEnabled = isEnabled
            field.isEditable = isEnabled
            field.textColor = !isEnabled ? .disabledControlTextColor : isInvalid(value) ? .systemOrange : .labelColor
            field.setAccessibilityLabel("\(tr(.keyDashboardAdvancedPageEgressGuardColumnIp)) \(row + 1)")
        } else {
            field.stringValue = countryTitle(for: value)
            field.textColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateState()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commit(field)
    }

    // MARK: Actions

    @objc private func performAction(_ sender: NSSegmentedControl) {
        let segment = sender.selectedSegment
        sender.selectedSegment = -1
        performAction(segment: segment)
    }

    private func performAction(segment: Int) {
        guard isEnabled else { return }
        switch segment {
        case 0:
            finishEditing()
            // Reuse a blank row left at the end instead of stacking another one.
            if rows.last?.isEmpty != true {
                rows.append("")
                reloadRows()
            }
            let row = rows.count - 1
            applySelection(row)
            tableView.layoutSubtreeIfNeeded()
            tableView.editColumn(0, row: row, with: nil, select: true)
        case 1:
            let row = tableView.selectedRow
            guard rows.indices.contains(row) else { return }
            finishEditing()
            // Ending the edit may already have dropped a blank row.
            guard rows.indices.contains(row) else { break }
            rows.remove(at: row)
            reloadRows()
            applySelection(rows.isEmpty ? nil : min(row, rows.count - 1))
            save()
        default:
            break
        }
        updateState()
    }

    private func commit(_ field: NSTextField) {
        let row = tableView.row(for: field)
        guard rows.indices.contains(row) else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = isInvalid(value) ? nil : rows.indices.first {
            $0 != row && !isInvalid(rows[$0]) && !rows[$0].isEmpty
                && EgressIPAddress.normalize(rows[$0]) == EgressIPAddress.normalize(value)
        }
        if value.isEmpty || duplicate != nil {
            // A blank row or an address that is already listed is dropped.
            rows.remove(at: row)
            reloadRows()
            if let duplicate { applySelection(duplicate < row ? duplicate : duplicate - 1) }
        } else {
            rows[row] = value
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<2))
        }
        save()
        updateState()
    }

    private func save() {
        onSave(rows.filter { !$0.isEmpty && !isInvalid($0) })
    }

    private func isInvalid(_ text: String) -> Bool {
        !text.isEmpty && !EgressIPAddress.isValid(text)
    }

    /// "🇺🇸 United States", or "—" until ipinfo.io answers (asked once per address per page).
    private func countryTitle(for ip: String) -> String {
        guard EgressIPAddress.isValid(ip) else { return "" }
        if let code = cachedCountry(ip) { return IPCountryCode.displayTitle(code) }
        if let key = EgressIPCountryCache.key(for: ip), requestedCountries.insert(key).inserted {
            lookupCountry(ip) { [weak self] code in
                guard code != nil else { return }
                DispatchQueue.main.async { self?.reloadCountry(of: ip) }
            }
        }
        return "—"
    }

    private func reloadCountry(of ip: String) {
        let key = EgressIPCountryCache.key(for: ip)
        let indexes = IndexSet(rows.indices.filter { EgressIPCountryCache.key(for: rows[$0]) == key })
        guard !indexes.isEmpty else { return }
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 1))
    }

    private func reloadRows() {
        tableView.reloadData()
        updateHeights()
        updateState()
    }

    private func updateState() {
        actionsControl.setEnabled(isEnabled, forSegment: 0)
        actionsControl.setEnabled(isEnabled && rows.indices.contains(tableView.selectedRow), forSegment: 1)
        emptyLabel.isHidden = !rows.isEmpty
        updateStatusLine()
    }

    /// The bar line: an invalid entry wins over the detected egress, which wins over nothing.
    private func updateStatusLine() {
        let symbol: String?
        let text: String
        if rows.contains(where: isInvalid) {
            symbol = "exclamationmark.triangle.fill"
            text = tr(.keyDashboardAdvancedPageEgressGuardInvalidIp)
        } else {
            switch status {
            case .none:
                symbol = nil
                text = ""
            case .detecting:
                symbol = nil
                text = tr(.keyDashboardAdvancedPageEgressGuardDetecting)
            case let .listed(ip):
                symbol = "checkmark.circle.fill"
                text = tr(.keyDashboardAdvancedPageEgressGuardDetectedListedValue, arguments: [ip])
            case let .unlisted(ip):
                symbol = "exclamationmark.triangle.fill"
                text = tr(.keyDashboardAdvancedPageEgressGuardDetectedUnlistedValue, arguments: [ip])
            case .failed:
                symbol = "exclamationmark.triangle.fill"
                text = tr(.keyDashboardAdvancedPageEgressGuardDetectFailed)
            }
        }
        statusLabel.stringValue = text
        statusLabel.textColor = isEnabled ? statusColor : .disabledControlTextColor
        statusIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        statusIcon.contentTintColor = symbol == "checkmark.circle.fill" ? .systemGreen : .systemOrange
        statusIcon.isHidden = symbol == nil
    }

    private var statusColor: NSColor {
        if rows.contains(where: isInvalid) { return .systemOrange }
        switch status {
        case .unlisted, .failed: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private func updateHeights() {
        let tableHeight = headerHeight + CGFloat(visibleRowCount) * Self.rowHeight + 2
        let total = Self.titleTopInset + ceil(titleLabel.intrinsicContentSize.height) + Self.tableTopSpacing
            + tableHeight + Self.barTopSpacing + Self.barHeight + Self.bottomInset
        guard abs(tableHeightConstraint.constant - tableHeight) > 0.5 || abs(heightConstraint.constant - total) > 0.5 else {
            return
        }
        tableHeightConstraint.constant = tableHeight
        heightConstraint.constant = total
        scrollView.hasVerticalScroller = rows.count > Self.maximumVisibleRows
        invalidateIntrinsicContentSize()
        needsLayout = true
        SettingsSectionView.enclosing(self)?.cardView.invalidateHostedSettingsRowHeight()
    }

    private func applySelection(_ row: Int?) {
        guard let row, rows.indices.contains(row) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Ends an in-place edit so its text is committed before the list changes.
    private func finishEditing() {
        guard let window, tableView.editedRow >= 0 else { return }
        _ = window.makeFirstResponder(tableView)
    }

    // MARK: Configuration

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, editable: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = editable ? .monospacedDigitSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
        field.isEditable = editable
        field.isSelectable = editable
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        if editable {
            field.placeholderString = tr(.keyDashboardAdvancedPageEgressGuardAddPlaceholder)
            field.delegate = self
        }
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configureTable() {
        ipColumn.title = tr(.keyDashboardAdvancedPageEgressGuardColumnIp)
        ipColumn.minWidth = 160
        ipColumn.resizingMask = .autoresizingMask
        countryColumn.title = tr(.keyDashboardAdvancedPageEgressGuardColumnRegion)
        countryColumn.minWidth = 120
        countryColumn.width = 180
        countryColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(ipColumn)
        tableView.addTableColumn(countryColumn)
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.identifier = NSUserInterfaceItemIdentifier("egressGuard.ip.table")
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.setAccessibilityLabel(tr(.keyDashboardAdvancedPageEgressGuardAllowed))
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
    }

    private func configureContainer() {
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.boxType = .custom
        tableContainer.borderWidth = 0
        tableContainer.fillColor = .clear
        tableContainer.contentViewMargins = .zero
        tableContainer.contentView = scrollView
        tableContainer.wantsLayer = true
        tableContainer.layer?.cornerRadius = Self.cornerRadius
        tableContainer.layer?.cornerCurve = .continuous
        tableContainer.layer?.borderWidth = 1
        tableContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        tableContainer.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor, constant: -1),
        ])
    }

    private func configureEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        tableContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor, constant: headerHeight / 2),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableContainer.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableContainer.trailingAnchor, constant: -12),
        ])
    }

    private func configureActions() {
        actionsControl.translatesAutoresizingMaskIntoConstraints = false
        actionsControl.segmentCount = 2
        actionsControl.trackingMode = .momentary
        actionsControl.segmentStyle = .automatic
        actionsControl.segmentDistribution = .fillEqually
        let segments: [(symbol: String, fallback: String, title: String)] = [
            ("plus", "+", tr(.keyDashboardAdvancedPageEgressGuardAddTitle)),
            ("minus", "−", tr(.keyDashboardAdvancedPageEgressGuardRemove)),
        ]
        for (segment, item) in segments.enumerated() {
            actionsControl.setWidth(28, forSegment: segment)
            if let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title) {
                actionsControl.setImage(image, forSegment: segment)
                actionsControl.setLabel("", forSegment: segment)
            } else {
                actionsControl.setLabel(item.fallback, forSegment: segment)
            }
            actionsControl.setToolTip(item.title, forSegment: segment)
            actionsControl.setAlignment(.center, forSegment: segment)
        }
        actionsControl.target = self
        actionsControl.action = #selector(performAction(_:))
        actionsControl.identifier = NSUserInterfaceItemIdentifier("egressGuard.ip.actions")
        actionsControl.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureBar() {
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        statusIcon.isHidden = true
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [addDetectedButton, detectButton] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        detectButton.identifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.detect")
        addDetectedButton.identifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.addDetected")
        addDetectedButton.isHidden = true
    }

    // MARK: Testing

    func performActionForTesting(segment: Int) { performAction(segment: segment) }

    /// Puts `text` into `row` and ends editing, as the user would.
    func editForTesting(row: Int, text: String) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        field.stringValue = text
        commit(field)
    }

    func selectForTesting(row: Int) {
        applySelection(row)
        updateState()
    }

    func countryTextForTesting(row: Int) -> String? {
        (tableView.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }
}
