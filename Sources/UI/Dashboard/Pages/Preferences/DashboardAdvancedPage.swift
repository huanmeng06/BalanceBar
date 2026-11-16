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

/// Owns the egress guard section: the switch, the detect row, then the allowed-IP list. The list is
/// a native bordered table with +/− controls, the same pattern as the status links editor. Every
/// row is a direct section row, so settings search shows and hides them like any other.
final class ClaudeEgressGuardSectionController: NSObject {
    static let detectButtonIdentifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.detect")
    static let addDetectedButtonIdentifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.addDetected")

    private let actions: ClaudeEgressGuardPageActions
    private var allowedIPs: [String]
    private let toggle: NSSwitch
    private(set) var listEditor: EgressIPListEditorView!
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

        detectButton.title = tr(.keyDashboardAdvancedPageEgressGuardDetect)
        detectButton.bezelStyle = .push
        detectButton.identifier = Self.detectButtonIdentifier
        detectButton.target = self
        detectButton.action = #selector(detect)
        addDetectedButton.title = tr(.keyDashboardAdvancedPageEgressGuardAddDetected)
        addDetectedButton.bezelStyle = .push
        addDetectedButton.identifier = Self.addDetectedButtonIdentifier
        addDetectedButton.target = self
        addDetectedButton.action = #selector(addDetectedIP)
        addDetectedButton.isHidden = true
        detectRow = SettingsRowView(
            title: tr(.keyDashboardAdvancedPageEgressGuardDetectTitle),
            accessoryView: Self.hStack([addDetectedButton, detectButton]))

        listEditor = EgressIPListEditorView(ips: allowedIPs) { [weak self] ips in
            self?.save(ips)
        }

        return SettingsSectionView(
            title: tr(.keyDashboardAdvancedPageEgressGuard),
            contentViews: [toggleRow, detectRow, listEditor],
            footnote: tr(.keyDashboardAdvancedPageEgressGuardFootnote))
    }

    /// Re-reads the saved settings (after a change from the other page copy or the app).
    func refresh(preferences: AppPreferences) {
        toggle.state = preferences.claudeEgressGuardEnabled ? .on : .off
        let saved = preferences.claudeEgressGuardAllowedIPs
        guard saved != allowedIPs else { return }
        allowedIPs = saved
        listEditor?.updateSavedIPs(saved)
        updateDetectedRow()
    }

    private func save(_ ips: [String]) {
        let sanitized = EgressIPAddress.sanitizedList(ips)
        guard sanitized != allowedIPs else { return }
        allowedIPs = sanitized
        updateDetectedRow()
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

    func detectForTesting() { detect() }
    func addDetectedForTesting() { addDetectedIP() }
    var allowedIPsForTesting: [String] { allowedIPs }
    var detectDetailForTesting: String { detectRow.detailLabel.stringValue }
}

/// Native editor for the allowed egress IPs: a bordered, single-column `NSTableView` whose rows are
/// edited in place, with a +/− `NSSegmentedControl` below it (the status links editor's pattern).
/// Rows that are not valid addresses stay in the table, tinted orange, and are never saved.
final class EgressIPListEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let tableViewportHeight: CGFloat = 112
    static let rowHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 12
    static let fixedHeight: CGFloat = 12 + tableViewportHeight + 8 + 24 + 12

    private let onSave: ([String]) -> Void
    /// What the table shows: saved addresses plus any invalid text still being fixed.
    private(set) var rows: [String]

    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let tableContainer = NSBox()
    let actionsControl = NSSegmentedControl()
    let messageLabel = NSTextField(labelWithString: "")
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("egressGuard.ip.column"))

    init(ips: [String], onSave: @escaping ([String]) -> Void) {
        rows = ips
        self.onSave = onSave
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("dashboard.advanced.egressGuard.list")
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureTable()
        configureScrollView()
        configureContainer()
        configureActions()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(tableContainer)
        addSubview(actionsControl)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            tableContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            tableContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            tableContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tableContainer.heightAnchor.constraint(equalToConstant: Self.tableViewportHeight),

            actionsControl.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            actionsControl.topAnchor.constraint(equalTo: tableContainer.bottomAnchor, constant: 8),
            actionsControl.heightAnchor.constraint(equalToConstant: 24),

            messageLabel.leadingAnchor.constraint(equalTo: actionsControl.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableContainer.trailingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: actionsControl.centerYAnchor),

            heightAnchor.constraint(equalToConstant: Self.fixedHeight),
        ])
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.fixedHeight)
    }

    /// The saved list changed elsewhere (the other page copy); keep invalid rows the user is still
    /// fixing only when the saved list already matches what the table holds.
    func updateSavedIPs(_ saved: [String]) {
        guard EgressIPAddress.sanitizedList(rows) != saved else { return }
        finishEditing()
        rows = saved
        tableView.reloadData()
        updateState()
    }

    /// Appends an address (from "Add to list") and saves it.
    func append(_ ip: String) {
        finishEditing()
        guard !EgressIPAddress.contains(rows, ip) else { return }
        rows.append(ip)
        tableView.reloadData()
        applySelection(rows.count - 1)
        save()
        updateState()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cellIdentifier = NSUserInterfaceItemIdentifier("egressGuard.ip.cell")
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: cellIdentifier)
        guard let field = cell.textField else { return cell }
        field.identifier = NSUserInterfaceItemIdentifier("egressGuard.ip.\(row)")
        field.stringValue = rows[row]
        field.textColor = isInvalid(rows[row]) ? .systemOrange : .labelColor
        field.setAccessibilityLabel("\(tr(.keyDashboardAdvancedPageEgressGuardAllowed)) \(row + 1)")
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
        switch segment {
        case 0:
            finishEditing()
            // Reuse a blank row left at the end instead of stacking another one.
            if rows.last?.isEmpty != true {
                rows.append("")
                tableView.insertRows(at: IndexSet(integer: rows.count - 1), withAnimation: [])
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
            tableView.removeRows(at: IndexSet(integer: row), withAnimation: .effectFade)
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
            tableView.removeRows(at: IndexSet(integer: row), withAnimation: [])
            if let duplicate { applySelection(duplicate < row ? duplicate : duplicate - 1) }
        } else {
            rows[row] = value
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
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

    private func updateState() {
        actionsControl.setEnabled(rows.indices.contains(tableView.selectedRow), forSegment: 1)
        if rows.contains(where: isInvalid) {
            messageLabel.stringValue = tr(.keyDashboardAdvancedPageEgressGuardInvalidIp)
            messageLabel.textColor = .systemOrange
        } else if rows.isEmpty {
            messageLabel.stringValue = tr(.keyDashboardAdvancedPageEgressGuardAllowedEmpty)
            messageLabel.textColor = .secondaryLabelColor
        } else {
            messageLabel.stringValue = ""
        }
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

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = tr(.keyDashboardAdvancedPageEgressGuardAddPlaceholder)
        field.delegate = self
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configureTable() {
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.identifier = NSUserInterfaceItemIdentifier("egressGuard.ip.table")
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowSizeStyle = .medium
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
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = Self.cornerRadius
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true
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
}
