import AppKit

struct DashboardNotificationPageConfiguration {
    let coordinator: BalanceNotificationCoordinator
    let providerChoices: (BalanceNotificationAgent) -> [ProviderChoice]
}

private final class DashboardNotificationPageRelay: NSObject, NSTextFieldDelegate {
    var onGlobalToggle: ((Bool) -> Void)?
    var onAgentToggle: ((BalanceNotificationAgent, Bool) -> Void)?
    var onProviderToggle: ((BalanceNotificationAgent, String, Bool) -> Void)?
    var onResourceToggle: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool) -> Void)?
    var onThreshold: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool, Double) -> Void)?
    var onSecondThresholdToggle: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPauseSelection: ((String) -> Void)?
    var onGlobalRuleThreshold: ((String, Bool, Double, NSTextField) -> Void)?
    var onResume: (() -> Void)?
    var onAgent: ((BalanceNotificationAgent) -> Void)?
    var onProvider: ((BalanceNotificationAgent, String) -> Void)?

    @objc func globalToggle(_ sender: NSSwitch) { onGlobalToggle?(sender.state == .on) }

    @objc func agentToggle(_ sender: NSSwitch) {
        guard let agent = agent(from: sender) else { return }
        onAgentToggle?(agent, sender.state == .on)
    }

    @objc func providerToggle(_ sender: NSSwitch) {
        guard let (agent, providerID) = provider(from: sender) else { return }
        onProviderToggle?(agent, providerID, sender.state == .on)
    }

    @objc func resourceToggle(_ sender: NSSwitch) {
        guard let key = resourceKey(from: sender),
              let kind = kind(from: sender),
              let unit = sender.toolTip else { return }
        onResourceToggle?(key, kind, unit == "" ? nil : unit, sender.state == .on)
    }

    @objc func thresholdChanged(_ sender: NSTextField) {
        guard let key = resourceKey(from: sender),
              let kind = kind(from: sender),
              let value = Double(sender.stringValue) else { return }
        let isSecond = sender.identifier?.rawValue.hasSuffix("|second") == true
        onThreshold?(key, kind, sender.toolTip, isSecond, value)
    }

    @objc func secondThresholdToggle(_ sender: NSSwitch) {
        guard let key = resourceKey(from: sender),
              let kind = kind(from: sender),
              let unit = sender.toolTip else { return }
        onSecondThresholdToggle?(key, kind, unit == "" ? nil : unit, sender.state == .on)
    }

    @objc func openSettings(_ sender: NSButton) { onOpenSettings?() }
    @objc func pauseSelection(_ sender: NSPopUpButton) {
        guard let selection = sender.selectedItem?.representedObject as? String else { return }
        onPauseSelection?(selection)
    }
    @objc func resume(_ sender: NSButton) { onResume?() }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commitGlobalRuleThreshold(field)
    }

    @objc func agent(_ sender: NSButton) {
        guard let raw = metadata(from: sender, prefix: "agent"),
              let agent = BalanceNotificationAgent(rawValue: raw) else { return }
        onAgent?(agent)
    }

    @objc func provider(_ sender: NSButton) {
        guard let (agent, providerID) = provider(from: sender) else { return }
        onProvider?(agent, providerID)
    }


    private func metadata(from sender: NSView, prefix: String) -> String? {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix(prefix + ":") else { return nil }
        return String(raw.dropFirst(prefix.count + 1))
    }

    private func commitGlobalRuleThreshold(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("global-rule:"),
              let separator = raw.lastIndex(of: ":"),
              let value = Double(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        let resourceID = String(raw[raw.index(raw.startIndex, offsetBy: "global-rule:".count)..<separator])
        let isSecond = String(raw[raw.index(after: separator)...]) == "second"
        onGlobalRuleThreshold?(resourceID, isSecond, value, sender)
    }

    private func agent(from sender: NSView) -> BalanceNotificationAgent? {
        metadata(from: sender, prefix: "agent").flatMap(BalanceNotificationAgent.init(rawValue:))
    }

    private func provider(from sender: NSView) -> (BalanceNotificationAgent, String)? {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("provider:"),
              let separator = raw.dropFirst("provider:".count).firstIndex(of: ":") else { return nil }
        let agentRaw = String(raw.dropFirst("provider:".count).prefix(upTo: separator))
        let providerID = String(raw[raw.index(after: separator)...])
        guard let agent = BalanceNotificationAgent(rawValue: agentRaw) else { return nil }
        return (agent, providerID)
    }

    private func resourceKey(from sender: NSView) -> BalanceNotificationResourceKey? {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("resource:"),
              let first = raw.dropFirst("resource:".count).firstIndex(of: ":"),
              let second = raw[raw.index(after: first)...].firstIndex(of: ":") else { return nil }
        let agentRaw = String(raw.dropFirst("resource:".count).prefix(upTo: first))
        let providerID = String(raw[raw.index(after: first)..<second])
        let resourceID = String(raw[raw.index(after: second)...])
        let cleanResourceID = resourceID.split(separator: "|", maxSplits: 1).first.map(String.init) ?? resourceID
        guard let agent = BalanceNotificationAgent(rawValue: agentRaw) else { return nil }
        return BalanceNotificationResourceKey(agent: agent, providerID: providerID, resourceID: cleanResourceID)
    }

    private func kind(from sender: NSView) -> BalanceNotificationResourceKind? {
        guard let value = sender.accessibilityValue() as? String else { return nil }
        return BalanceNotificationResourceKind(rawValue: value)
    }
}

/// The reminder editor has two equal groups and therefore needs a deterministic
/// natural width. It uses the same native AppKit stack behavior as the shared
/// Dashboard controls, but does not remeasure different inner view trees for
/// each row.
private final class ReminderRuleAccessoryView: NSStackView, SettingsRowAccessoryLayout {
    let groupWidth: CGFloat
    let groupSpacing: CGFloat
    var allowsTextDrivenDedicatedRow = false
    var minimumInlineLabelWidth: CGFloat = 0

    private var availableRowWidth = CGFloat.greatestFiniteMagnitude
    private(set) var stacksControlsVertically = false

    init(views: [NSView], groupWidth: CGFloat, groupSpacing: CGFloat) {
        self.groupWidth = groupWidth
        self.groupSpacing = groupSpacing
        super.init(frame: .zero)
        views.forEach(addArrangedSubview)
        orientation = .horizontal
        alignment = .centerY
        spacing = groupSpacing
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var naturalAccessoryWidth: CGFloat {
        stacksControlsVertically ? groupWidth : groupWidth * 2 + groupSpacing
    }

    func updateAvailableRowWidth(_ width: CGFloat) {
        availableRowWidth = max(0, width)
        updateOrientationIfNeeded()
    }

    override func layout() {
        updateOrientationIfNeeded()
        super.layout()
    }

    override var intrinsicContentSize: NSSize {
        let visible = arrangedSubviews.filter { !$0.isHidden }
        let heights = visible.map { $0.fittingSize.height }
        let height: CGFloat
        if stacksControlsVertically {
            height = heights.reduce(0, +) + max(0, CGFloat(heights.count - 1)) * spacing
        } else {
            height = heights.max() ?? 0
        }
        return NSSize(width: naturalAccessoryWidth, height: height)
    }

    private func updateOrientationIfNeeded() {
        let horizontalWidth = groupWidth * 2 + groupSpacing
        let wantsVertical = availableRowWidth > 0 && availableRowWidth + 0.5 < horizontalWidth
        guard wantsVertical != stacksControlsVertically else { return }
        stacksControlsVertically = wantsVertical
        orientation = wantsVertical ? .vertical : .horizontal
        alignment = wantsVertical ? .trailing : .centerY
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        superview?.superview?.needsLayout = true
    }
}

/// Native Dashboard pages for the notification hierarchy. Navigation stays
/// inside the content pane so the existing Dashboard sidebar geometry and
/// search behavior remain unchanged.
final class DashboardNotificationPages {
    var onNavigateRoute: ((String) -> Void)?

    private let configuration: DashboardNotificationPageConfiguration
    private let relay = DashboardNotificationPageRelay()
    private let container = NSView()
    private var currentPage: NSView?
    private var path: [NotificationPagePath] = []
    private weak var pauseDetailLabel: NSTextField?
    private weak var pauseMenu: NSPopUpButton?
    private weak var pauseRow: NSView?
    private weak var notificationSection: SettingsSectionView?
    private weak var reminderRulesView: NSView?
    private weak var agentSettingsView: NSView?
    private weak var detailsStack: NSStackView?
    private var agentRows: [BalanceNotificationAgent: SettingsRowView] = [:]
    private var agentAdvancedButtons: [BalanceNotificationAgent: NSButton] = [:]
    private var providerRows: [String: SettingsRowView] = [:]
    private var providerAdvancedButtons: [String: NSButton] = [:]
    private var resourceRuleRows: [BalanceNotificationResourceKey: ResourceRuleRows] = [:]
    private var pauseTimer: Timer?

    private enum NotificationPagePath: Equatable {
        case root
        case agent(BalanceNotificationAgent)
        case provider(BalanceNotificationAgent, String)
    }

    private struct GlobalRuleColumnMetrics {
        let labelWidth: CGFloat
        let percentFieldWidth: CGFloat
        let unitWidth: CGFloat
        let valueSpacing: CGFloat = 7
        let groupSpacing: CGFloat = 12

        var valueAreaWidth: CGFloat {
            percentFieldWidth + valueSpacing + unitWidth
        }

        var groupWidth: CGFloat {
            labelWidth + valueSpacing + valueAreaWidth
        }
    }

    private final class ResourceRuleRows {
        let enableRow: SettingsRowView
        let firstThresholdRow: SettingsRowView
        let secondToggleRow: SettingsRowView
        let secondThresholdRow: SettingsRowView
        weak var section: SettingsSectionView?
        private(set) var resourceEnabled = false
        private(set) var secondEnabled = false

        init(
            enableRow: SettingsRowView,
            firstThresholdRow: SettingsRowView,
            secondToggleRow: SettingsRowView,
            secondThresholdRow: SettingsRowView
        ) {
            self.enableRow = enableRow
            self.firstThresholdRow = firstThresholdRow
            self.secondToggleRow = secondToggleRow
            self.secondThresholdRow = secondThresholdRow
        }

        func updateVisibility(resourceEnabled: Bool, secondEnabled: Bool) {
            self.resourceEnabled = resourceEnabled
            self.secondEnabled = secondEnabled
            enableRow.isHidden = false
            firstThresholdRow.isHidden = !resourceEnabled
            secondToggleRow.isHidden = !resourceEnabled
            secondThresholdRow.isHidden = !resourceEnabled || !secondEnabled
            section?.reconcileSeparators()
        }
    }

    init(configuration: DashboardNotificationPageConfiguration) {
        self.configuration = configuration
        relay.onGlobalToggle = { [weak self] enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                coordinator.setGlobalEnabled(enabled)
                if !enabled { coordinator.resume() }
                DispatchQueue.main.async { [weak self] in self?.updateGlobalVisibility() }
            }
        }
        relay.onAgentToggle = { [weak self] agent, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            self.updateAgentDetail(agent, enabled: enabled)
            let providerIDs = self.configuration.providerChoices(agent).map(\.id)
            coordinator.performAsync {
                coordinator.setAgentEnabled(enabled, agent: agent)
                providerIDs.forEach { providerID in
                    coordinator.setProviderEnabled(enabled, agent: agent, providerID: providerID)
                }
            }
        }
        relay.onProviderToggle = { [weak self] agent, providerID, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            self.updateProviderDetail(agent, providerID: providerID, enabled: enabled)
            coordinator.performAsync { coordinator.setProviderEnabled(enabled, agent: agent, providerID: providerID) }
        }
        relay.onResourceToggle = { [weak self] key, kind, unit, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            self.updateResourceVisibility(key: key, resourceEnabled: enabled)
            coordinator.performAsync {
                coordinator.setResourceEnabled(enabled, key: key, kind: kind, unit: unit)
            }
        }
        relay.onThreshold = { [weak self] key, kind, unit, isSecond, value in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                coordinator.updateRule(key: key, kind: kind, unit: unit) { rule in
                    if isSecond { rule.secondThreshold = BalanceNotificationResourceRule.normalizedSecondThreshold(value, firstThreshold: rule.firstThreshold, kind: kind) }
                    else { rule.firstThreshold = BalanceNotificationResourceRule.normalizedFirstThreshold(value, kind: kind) }
                }
            }
        }
        relay.onSecondThresholdToggle = { [weak self] key, kind, unit, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            self.updateSecondThresholdVisibility(key: key, enabled: enabled)
            coordinator.performAsync {
                coordinator.updateRule(key: key, kind: kind, unit: unit) { $0.secondEnabled = enabled }
            }
        }
        relay.onOpenSettings = { [weak self] in self?.configuration.coordinator.openSystemSettings() }
        relay.onPauseSelection = { [weak self] selection in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                switch selection {
                case "none":
                    coordinator.resume()
                case "today":
                    let calendar = Calendar.autoupdatingCurrent
                    let start = calendar.startOfDay(for: Date())
                    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
                    coordinator.pause(for: max(0, end.timeIntervalSinceNow))
                default:
                    coordinator.pause(for: 3_600)
                }
                DispatchQueue.main.async { [weak self] in self?.updatePausePresentation() }
            }
        }
        relay.onGlobalRuleThreshold = { [weak self] resourceID, isSecond, value, field in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            let kind: BalanceNotificationResourceKind = resourceID == "balance" ? .balance : .quotaPercent
            coordinator.performAsync {
                let key = BalanceNotificationResourceKey(
                    agent: .gpt,
                    providerID: "global",
                    resourceID: resourceID
                )
                let current = coordinator.settings.globalThresholds(for: key, kind: kind)
                let first = isSecond ? current.first : value
                let second = isSecond ? value : current.second
                let normalizedFirst = BalanceNotificationResourceRule.normalizedFirstThreshold(first, kind: kind)
                let normalizedSecond = BalanceNotificationResourceRule.normalizedSecondThreshold(
                    second,
                    firstThreshold: normalizedFirst,
                    kind: kind
                )
                coordinator.updateGlobalRule(
                    resourceID: resourceID,
                    kind: kind,
                    firstThreshold: normalizedFirst,
                    secondThreshold: normalizedSecond
                )
                DispatchQueue.main.async { [weak field] in
                    let displayed = isSecond ? normalizedSecond : normalizedFirst
                    field?.stringValue = kind == .quotaPercent
                        ? String(format: "%.0f", displayed)
                        : String(format: "%.2f", displayed)
                }
            }
        }
        relay.onResume = { [weak self] in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                coordinator.resume()
                DispatchQueue.main.async { [weak self] in self?.updatePausePresentation() }
            }
        }
        relay.onAgent = { [weak self] agent in
            guard let self else { return }
            if let onNavigateRoute {
                onNavigateRoute(Self.agentRoute(for: agent))
                return
            }
            self.path = [.agent(agent)]
            self.rebuild()
        }
        relay.onProvider = { [weak self] agent, providerID in
            guard let self else { return }
            if let onNavigateRoute {
                onNavigateRoute(Self.providerRoute(for: agent, providerID: providerID))
                return
            }
            self.path = self.path.filter {
                if case .agent = $0 { return true }
                return false
            }
            self.path.append(.provider(agent, providerID))
            self.rebuild()
        }
        container.translatesAutoresizingMaskIntoConstraints = false
    }

    deinit {
        pauseTimer?.invalidate()
    }

    func make() -> NSView {
        if currentPage == nil { rebuild() }
        return container
    }

    func showRoot() {
        path = []
        rebuild()
    }

    func refresh() {
        guard currentPage != nil else { return }
        rebuild()
    }

    func showAgent(_ agent: BalanceNotificationAgent) {
        path = [.agent(agent)]
        rebuild()
    }

    @discardableResult
    func showNavigationRoute(_ route: String) -> Bool {
        let components = route.split(separator: "/").map(String.init)
        guard components.first == "notifications",
              components.count >= 2 else { return false }
        if components[1] == "root" {
            showRoot()
            return true
        }
        guard components.count >= 3 else { return false }
        switch components[1] {
        case "agent":
            guard let agent = BalanceNotificationAgent(rawValue: components[2]) else { return false }
            path = [.agent(agent)]
        case "provider":
            guard components.count >= 4,
                  let agent = BalanceNotificationAgent(rawValue: components[2]) else { return false }
            path = [.agent(agent), .provider(agent, components[3])]
        default:
            return false
        }
        rebuild()
        return true
    }

    private static func agentRoute(for agent: BalanceNotificationAgent) -> String {
        "notifications/agent/\(agent.rawValue)"
    }

    private static func providerRoute(
        for agent: BalanceNotificationAgent,
        providerID: String
    ) -> String {
        "notifications/provider/\(agent.rawValue)/\(providerID)"
    }

    private func rebuild() {
        let page: NSView
        switch path.last ?? .root {
        case .root: page = makeRootPage()
        case .agent(let agent): page = makeAgentPage(agent)
        case .provider(let agent, let providerID): page = makeProviderPage(agent, providerID: providerID)
        }
        currentPage?.removeFromSuperview()
        currentPage = page
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func makeRootPage() -> NSView {
        let settings = configuration.coordinator.settings
        let permission = configuration.coordinator.permissionState
        let globalSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "notification-global",
            isOn: settings.globalEnabled,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.globalToggle(_:))
        )
        var globalControls: [NSView] = []
        if permission == .denied {
            let systemSettings = NSButton(
                title: tr("notifications.system_settings"),
                target: relay,
                action: #selector(DashboardNotificationPageRelay.openSettings(_:))
            )
            globalControls.append(systemSettings)
        }
        if permission != .denied {
            globalControls.append(globalSwitch)
        }
        let globalAccessory = NSStackView(views: globalControls)
        globalAccessory.orientation = .horizontal
        globalAccessory.spacing = 8
        let global = SettingsRowView(
            title: tr("notifications.quota_reminders"),
            detail: permission == .denied
                ? tr("notifications.permission_disabled")
                : tr("notifications.global_description"),
            accessoryView: globalAccessory
        )

        let pauseMenu = NSPopUpButton()
        pauseMenu.addItem(withTitle: tr("notifications.pause_none"))
        pauseMenu.item(at: 0)?.representedObject = "none"
        pauseMenu.addItem(withTitle: tr("notifications.pause_one_hour"))
        pauseMenu.item(at: 1)?.representedObject = "oneHour"
        pauseMenu.addItem(withTitle: tr("notifications.pause_today"))
        pauseMenu.item(at: 2)?.representedObject = "today"
        pauseMenu.target = relay
        pauseMenu.action = #selector(DashboardNotificationPageRelay.pauseSelection(_:))
        self.pauseMenu = pauseMenu
        let pauseRow = SettingsRowView(
            title: tr("notifications.pause_notifications"),
            detail: tr("notifications.pause_duration"),
            accessoryView: pauseMenu
        )
        pauseDetailLabel = pauseRow.detailLabel
        self.pauseRow = pauseRow
        let notificationSection = SettingsSectionView(
            title: tr("notifications.page.title"),
            contentViews: [global, pauseRow]
        )
        self.notificationSection = notificationSection
        let reminderRules = makeReminderRulesSection(settings: settings)
        self.reminderRulesView = reminderRules
        let agentSettings = makeAgentSettingsSection(settings: settings)
        self.agentSettingsView = agentSettings
        let details = NSStackView(views: [reminderRules, agentSettings])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = DashboardSettingsComponents.settingsSectionSpacing
        details.detachesHiddenViews = true
        details.translatesAutoresizingMaskIntoConstraints = false
        agentSettings.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        detailsStack = details
        updateGlobalVisibility()
        updatePausePresentation()
        startPauseTimer()
        reminderRules.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        return DashboardSettingsComponents.makeSettingsPageContent([
            notificationSection,
            details
        ])
    }

    private func updateGlobalVisibility() {
        let settings = configuration.coordinator.settings
        let permission = configuration.coordinator.permissionState
        let active = settings.globalEnabled && permission != .denied
        pauseRow?.isHidden = !active
        notificationSection?.reconcileSeparators()
        reminderRulesView?.isHidden = !active
        agentSettingsView?.isHidden = !active
        detailsStack?.isHidden = !active
        updatePausePresentation()
    }

    private func startPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updatePausePresentation()
        }
        if let pauseTimer {
            RunLoop.main.add(pauseTimer, forMode: .common)
        }
    }

    private func updatePausePresentation() {
        guard let pauseDetailLabel else {
            pauseTimer?.invalidate()
            pauseTimer = nil
            return
        }
        guard let pauseUntil = configuration.coordinator.settings.pauseUntil,
              pauseUntil > Date() else {
            if configuration.coordinator.settings.pauseUntil != nil {
                configuration.coordinator.resume()
            }
            pauseDetailLabel.stringValue = tr("notifications.pause_duration")
            selectPauseOption("none")
            return
        }
        pauseDetailLabel.stringValue = tr(
            "notifications.pause_status",
            arguments: [Self.pauseDateFormatter.string(from: pauseUntil), remainingText(until: pauseUntil)]
        )
        selectPauseOption(pauseSelection(for: pauseUntil))
    }

    private func selectPauseOption(_ value: String) {
        guard let item = pauseMenu?.itemArray.first(where: {
            ($0.representedObject as? String) == value
        }) else { return }
        pauseMenu?.select(item)
    }

    private func pauseSelection(for pauseUntil: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let endOfToday = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: Date())
        ) ?? Date()
        return pauseUntil.timeIntervalSince(endOfToday) > -1 ? "today" : "oneHour"
    }

    private func remainingText(until date: Date) -> String {
        let minutes = max(1, Int(ceil(max(0, date.timeIntervalSinceNow) / 60)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private static let pauseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private func makeReminderRulesSection(settings: BalanceNotificationSettings) -> NSView {
        let heading = NSTextField(labelWithString: tr("notifications.reminder_rules"))
        heading.font = SettingsSectionView.headingFont
        heading.setContentHuggingPriority(.required, for: .vertical)
        let subtitle = NSTextField(labelWithString: tr("notifications.global_rules_hint"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .vertical)
        let columnMetrics = makeGlobalRuleColumnMetrics()

        let fiveHourKey = BalanceNotificationResourceKey(
            agent: .gpt,
            providerID: "global",
            resourceID: "five-hour"
        )
        let sevenDayKey = BalanceNotificationResourceKey(
            agent: .gpt,
            providerID: "global",
            resourceID: "weekly"
        )
        let balanceKey = BalanceNotificationResourceKey(
            agent: .gpt,
            providerID: "global",
            resourceID: "balance"
        )
        let fiveHour = SettingsRowView(
            title: tr("notifications.five_hour_reminder"),
            accessoryView: makeGlobalRuleAccessory(
                resourceID: fiveHourKey.resourceID,
                thresholds: settings.globalThresholds(for: fiveHourKey, kind: .quotaPercent),
                kind: .quotaPercent,
                columnMetrics: columnMetrics
            )
        )
        let sevenDay = SettingsRowView(
            title: tr("notifications.seven_day_reminder"),
            accessoryView: makeGlobalRuleAccessory(
                resourceID: sevenDayKey.resourceID,
                thresholds: settings.globalThresholds(for: sevenDayKey, kind: .quotaPercent),
                kind: .quotaPercent,
                columnMetrics: columnMetrics
            )
        )
        let balance = SettingsRowView(
            title: tr("notifications.balance_reminder"),
            accessoryView: makeGlobalRuleAccessory(
                resourceID: balanceKey.resourceID,
                thresholds: settings.globalThresholds(for: balanceKey, kind: .balance),
                kind: .balance,
                columnMetrics: columnMetrics
            )
        )
        let card = SettingsSectionView(title: "", contentViews: [fiveHour, sevenDay, balance])
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addView(heading, in: .top)
        stack.addView(subtitle, in: .top)
        stack.addView(card, in: .top)
        stack.setCustomSpacing(4, after: heading)
        stack.setCustomSpacing(SettingsSectionView.headingToCardSpacing, after: subtitle)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeGlobalRuleAccessory(
        resourceID: String,
        thresholds: (first: Double, second: Double),
        kind: BalanceNotificationResourceKind,
        columnMetrics: GlobalRuleColumnMetrics
    ) -> ReminderRuleAccessoryView {
        let firstLabel = makeGlobalRuleLabel(tr("notifications.first_reminder"))
        let secondLabel = makeGlobalRuleLabel(tr("notifications.second_reminder"))
        [firstLabel, secondLabel].forEach {
            $0.widthAnchor.constraint(equalToConstant: columnMetrics.labelWidth).isActive = true
        }
        let second = makeGlobalRuleField(
            resourceID: resourceID,
            isSecond: true,
            value: thresholds.second,
            kind: kind
        )
        let firstWithUnit = makeGlobalRuleField(
            resourceID: resourceID,
            isSecond: false,
            value: thresholds.first,
            kind: kind
        )
        let firstGroup = makeGlobalRuleGroup(
            label: firstLabel,
            field: firstWithUnit,
            unitText: kind == .quotaPercent ? "%" : nil,
            columnMetrics: columnMetrics
        )
        let secondGroup = makeGlobalRuleGroup(
            label: secondLabel,
            field: second,
            unitText: kind == .quotaPercent ? "%" : nil,
            columnMetrics: columnMetrics
        )
        let accessory = ReminderRuleAccessoryView(
            views: [firstGroup, secondGroup],
            groupWidth: columnMetrics.groupWidth,
            groupSpacing: columnMetrics.groupSpacing
        )
        accessory.minimumInlineLabelWidth = SettingsRowView.minimumInlineLabelWidth
        return accessory
    }

    private func makeGlobalRuleColumnMetrics() -> GlobalRuleColumnMetrics {
        let firstLabel = makeGlobalRuleLabel(tr("notifications.first_reminder"))
        let secondLabel = makeGlobalRuleLabel(tr("notifications.second_reminder"))
        let quotaField = makeGlobalRuleField(
            resourceID: "column-metrics-quota",
            isSecond: false,
            value: 0,
            kind: .quotaPercent
        )
        let unit = makeGlobalRuleUnitSlot(nil)
        let quotaNaturalWidth = ceil(quotaField.fittingSize.width)
        let unitWidth = unit.fittingSize.width
        return GlobalRuleColumnMetrics(
            labelWidth: ceil(max(firstLabel.fittingSize.width, secondLabel.fittingSize.width)),
            percentFieldWidth: quotaNaturalWidth,
            unitWidth: unitWidth
        )
    }

    private func makeGlobalRuleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func makeGlobalRuleGroup(
        label: NSTextField,
        field: DashboardSettingsComponents.CompactNumericFieldAccessory,
        unitText: String?,
        columnMetrics: GlobalRuleColumnMetrics
    ) -> NSStackView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        let valueWidth = unitText == nil ? columnMetrics.valueAreaWidth : columnMetrics.percentFieldWidth
        field.setFieldWidth(valueWidth)
        let fieldColumn = NSView()
        fieldColumn.translatesAutoresizingMaskIntoConstraints = false
        fieldColumn.addSubview(field)
        fieldColumn.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: fieldColumn.trailingAnchor),
            field.topAnchor.constraint(equalTo: fieldColumn.topAnchor),
            field.bottomAnchor.constraint(equalTo: fieldColumn.bottomAnchor)
        ])
        var views: [NSView] = [label, fieldColumn]
        if let unitText {
            views.append(makeGlobalRuleUnitSlot(unitText, width: columnMetrics.unitWidth))
        }
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = columnMetrics.valueSpacing
        group.widthAnchor.constraint(equalToConstant: columnMetrics.groupWidth).isActive = true
        group.setContentHuggingPriority(.required, for: .horizontal)
        group.setContentCompressionResistancePriority(.required, for: .horizontal)
        return group
    }

    private func makeGlobalRuleUnitSlot(_ text: String?, width: CGFloat? = nil) -> NSTextField {
        let unit = NSTextField(labelWithString: text ?? "")
        unit.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        let percentWidth = ceil(("%" as NSString).size(withAttributes: [.font: unit.font as Any]).width)
        unit.widthAnchor.constraint(equalToConstant: width ?? percentWidth).isActive = true
        unit.setContentHuggingPriority(.required, for: .horizontal)
        unit.setContentCompressionResistancePriority(.required, for: .horizontal)
        return unit
    }

    private func makeGlobalRuleField(
        resourceID: String,
        isSecond: Bool,
        value: Double,
        kind: BalanceNotificationResourceKind,
        trailingViews: [NSView] = []
    ) -> DashboardSettingsComponents.CompactNumericFieldAccessory {
        let identifier = "global-rule:" + resourceID + ":" + (isSecond ? "second" : "first")
        let field = DashboardSettingsComponents.makeNumericTextField(
            identifier: identifier,
            value: formattedGlobalRuleValue(value, kind: kind),
            placeholder: "0",
            capacityTemplate: kind == .quotaPercent ? "000" : DashboardSettingsComponents.amountCapacityTemplate,
            trailingViews: trailingViews,
            delegate: relay,
            toolTip: tr("notifications.global_rules_hint")
        )
        return field
    }

    private func formattedGlobalRuleValue(
        _ value: Double,
        kind: BalanceNotificationResourceKind
    ) -> String {
        kind == .quotaPercent ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func makeAgentSettingsSection(settings: BalanceNotificationSettings) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: tr("notifications.agent_settings"))
        heading.font = SettingsSectionView.headingFont
        heading.translatesAutoresizingMaskIntoConstraints = false
        agentRows.removeAll(keepingCapacity: true)
        agentAdvancedButtons.removeAll(keepingCapacity: true)
        let cards = NSStackView(views: BalanceNotificationAgent.dashboardCases.map {
            let row = makeAgentRow($0, settings: settings)
            agentRows[$0] = row
            return SettingsSectionView(
                title: "",
                contentViews: [row]
            )
        })
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 12
        cards.detachesHiddenViews = true
        cards.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(heading)
        container.addSubview(cards)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cards.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: SettingsSectionView.headingToCardSpacing),
            cards.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cards.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        for card in cards.arrangedSubviews {
            card.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }
        return container
    }

    private func makeAgentRow(
        _ agent: BalanceNotificationAgent,
        settings: BalanceNotificationSettings
    ) -> SettingsRowView {
        let agentSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "agent:\(agent.rawValue)",
            isOn: settings.isAgentEnabled(agent),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.agentToggle(_:))
        )
        let button = NSButton(
            title: tr("notifications.advanced_settings"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.agent(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("agent:\(agent.rawValue)")
        button.isHidden = !settings.isAgentEnabled(agent)
        agentAdvancedButtons[agent] = button
        let controls = NSStackView(views: [button, agentSwitch])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.detachesHiddenViews = true
        let detail = agentDetail(agent, enabled: settings.isAgentEnabled(agent), settings: settings)
        return SettingsRowView(title: agent.title, detail: detail, accessoryView: controls)
    }

    private func agentDetail(
        _ agent: BalanceNotificationAgent,
        enabled: Bool,
        settings: BalanceNotificationSettings
    ) -> String {
        if !enabled {
            return tr("notifications.agent_disabled")
        }
        if settings.hasCustomRules(for: agent) {
            return tr("notifications.agent_customized")
        }
        return tr("notifications.agent_follows_global")
    }

    private func updateAgentDetail(_ agent: BalanceNotificationAgent, enabled: Bool) {
        guard let row = agentRows[agent] else { return }
        let settings = configuration.coordinator.settings
        agentAdvancedButtons[agent]?.isHidden = !enabled
        agentAdvancedButtons[agent]?.superview?.needsLayout = true
        row.updateDetail(agentDetail(agent, enabled: enabled, settings: settings))
    }

    private func makeAgentPage(_ agent: BalanceNotificationAgent) -> NSView {
        let providers = configuration.providerChoices(agent)
        let settings = configuration.coordinator.settings
        providerRows.removeAll(keepingCapacity: true)
        providerAdvancedButtons.removeAll(keepingCapacity: true)
        var rows: [NSView] = []
        if providers.isEmpty {
            rows.append(SettingsRowView(
                title: agent.title,
                detail: tr("notifications.no_providers")
            ))
        } else {
            rows.append(contentsOf: providers.map { provider in
                let row = makeProviderRow(agent: agent, provider: provider, settings: settings)
                providerRows[providerRowKey(agent, providerID: provider.id)] = row
                return row
            })
        }
        return DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "\(agent.title) · \(tr("notifications.advanced_settings"))", contentViews: rows)
        ])
    }

    private func makeProviderRow(
        agent: BalanceNotificationAgent,
        provider: ProviderChoice,
        settings: BalanceNotificationSettings
    ) -> SettingsRowView {
        let toggle = DashboardSettingsComponents.makeSwitch(
            identifier: "provider:\(agent.rawValue):\(provider.id)",
            isOn: settings.isProviderEnabled(agent, providerID: provider.id),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.providerToggle(_:))
        )
        let button = NSButton(
            title: tr("notifications.advanced_settings"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.provider(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("provider:\(agent.rawValue):\(provider.id)")
        button.isHidden = !settings.isProviderEnabled(agent, providerID: provider.id)
        providerAdvancedButtons[providerRowKey(agent, providerID: provider.id)] = button
        let controls = NSStackView(views: [button, toggle])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.detachesHiddenViews = true
        let detail = settings.isProviderEnabled(agent, providerID: provider.id)
            ? tr("notifications.agent_enabled")
            : tr("notifications.agent_disabled")
        return SettingsRowView(title: provider.name, detail: detail, accessoryView: controls)
    }

    private func providerRowKey(_ agent: BalanceNotificationAgent, providerID: String) -> String {
        "\(agent.rawValue):\(providerID)"
    }

    private func updateProviderDetail(
        _ agent: BalanceNotificationAgent,
        providerID: String,
        enabled: Bool
    ) {
        let key = providerRowKey(agent, providerID: providerID)
        guard let row = providerRows[key] else { return }
        providerAdvancedButtons[key]?.isHidden = !enabled
        providerAdvancedButtons[key]?.superview?.needsLayout = true
        row.updateDetail(enabled ? tr("notifications.agent_enabled") : tr("notifications.agent_disabled"))
    }

    private func makeProviderPage(_ agent: BalanceNotificationAgent, providerID: String) -> NSView {
        let descriptors = configuration.coordinator.resourceDescriptors(agent: agent, providerID: providerID)
        let settings = configuration.coordinator.settings
        resourceRuleRows.removeAll(keepingCapacity: true)
        let providerName = configuration.providerChoices(agent).first { $0.id == providerID }?.name ?? providerID
        let pageTitle = "\(agent.title) · \(providerName)"
        var sections: [NSView] = []
        if descriptors.isEmpty {
            sections.append(SettingsSectionView(
                title: pageTitle,
                contentViews: [SettingsRowView(
                    title: tr("notifications.resource_rules"),
                    detail: tr("notifications.no_providers")
                )]
            ))
        } else {
            for (index, descriptor) in descriptors.enumerated() {
                let rows = makeResourceSettingsRows(descriptor, settings: settings)
                let section = SettingsSectionView(
                    title: index == 0 ? pageTitle : "",
                    contentViews: rows
                )
                resourceRuleRows[descriptor.key]?.section = section
                resourceRuleRows[descriptor.key]?.section?.reconcileSeparators()
                sections.append(section)
            }
        }
        return DashboardSettingsComponents.makeSettingsPageContent(sections)
    }

    private func makeResourceSettingsRows(
        _ descriptor: BalanceNotificationResourceDescriptor,
        settings: BalanceNotificationSettings
    ) -> [NSView] {
        let rule = settings.rule(for: descriptor.key)
            ?? settings.defaultRule(for: descriptor.key, kind: descriptor.kind, unit: descriptor.unit)
        let enabled = DashboardSettingsComponents.makeSwitch(
            identifier: "resource:\(descriptor.key.agent.rawValue):\(descriptor.key.providerID):\(descriptor.key.resourceID)",
            isOn: rule.enabled,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.resourceToggle(_:))
        )
        enabled.toolTip = descriptor.unit ?? ""
        enabled.setAccessibilityValue(descriptor.kind.rawValue)
        let enableRow = SettingsRowView(
            title: descriptor.title,
            detail: descriptor.unit == "%"
                ? tr("notifications.quota_value", arguments: [descriptor.title, formatted(descriptor.value ?? 0, kind: .quotaPercent)])
                : tr("notifications.balance_value", arguments: [descriptor.title, formatted(descriptor.value ?? 0, kind: .balance)]),
            accessoryView: enabled
        )
        let firstField = thresholdField(rule.firstThreshold, key: descriptor.key, kind: descriptor.kind, unit: descriptor.unit, isSecond: false)
        let firstRow = SettingsRowView(
            title: tr("notifications.first_threshold"),
            detail: thresholdDetail(rule, descriptor: descriptor, second: false),
            accessoryView: firstField
        )
        let secondSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "resource:\(descriptor.key.agent.rawValue):\(descriptor.key.providerID):\(descriptor.key.resourceID)",
            isOn: rule.secondEnabled,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.secondThresholdToggle(_:))
        )
        secondSwitch.toolTip = descriptor.unit ?? ""
        secondSwitch.setAccessibilityValue(descriptor.kind.rawValue)
        let secondRow = SettingsRowView(
            title: tr("notifications.second_alert"),
            detail: tr("notifications.second_threshold"),
            accessoryView: secondSwitch
        )
        let secondField = thresholdField(rule.secondThreshold, key: descriptor.key, kind: descriptor.kind, unit: descriptor.unit, isSecond: true)
        let secondThresholdRow = SettingsRowView(
            title: tr("notifications.second_threshold"),
            detail: thresholdDetail(rule, descriptor: descriptor, second: true),
            accessoryView: secondField
        )
        let resourceRows = ResourceRuleRows(
            enableRow: enableRow,
            firstThresholdRow: firstRow,
            secondToggleRow: secondRow,
            secondThresholdRow: secondThresholdRow
        )
        resourceRuleRows[descriptor.key] = resourceRows
        resourceRows.updateVisibility(resourceEnabled: rule.enabled, secondEnabled: rule.secondEnabled)
        return [enableRow, firstRow, secondRow, secondThresholdRow]
    }

    private func updateResourceVisibility(
        key: BalanceNotificationResourceKey,
        resourceEnabled: Bool
    ) {
        guard let resourceRows = resourceRuleRows[key] else { return }
        resourceRows.updateVisibility(resourceEnabled: resourceEnabled, secondEnabled: resourceRows.secondEnabled)
    }

    private func updateSecondThresholdVisibility(
        key: BalanceNotificationResourceKey,
        enabled: Bool
    ) {
        guard let resourceRows = resourceRuleRows[key] else { return }
        resourceRows.updateVisibility(resourceEnabled: resourceRows.resourceEnabled, secondEnabled: enabled)
    }

    private func thresholdField(
        _ value: Double,
        key: BalanceNotificationResourceKey,
        kind: BalanceNotificationResourceKind,
        unit: String?,
        isSecond: Bool
    ) -> NSTextField {
        let field = NSTextField(string: formatted(value, kind: kind))
        field.identifier = NSUserInterfaceItemIdentifier("resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)")
        field.toolTip = unit ?? ""
        field.setAccessibilityValue(kind.rawValue)
        field.identifier = NSUserInterfaceItemIdentifier(
            "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)|\(isSecond ? "second" : "first")"
        )
        field.alignment = .right
        field.isEditable = true
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        field.target = relay
        field.action = #selector(DashboardNotificationPageRelay.thresholdChanged(_:))
        return field
    }

    private func thresholdDetail(
        _ rule: BalanceNotificationResourceRule,
        descriptor: BalanceNotificationResourceDescriptor,
        second: Bool
    ) -> String {
        let value = second ? rule.secondThreshold : rule.firstThreshold
        return descriptor.kind == .quotaPercent
            ? "\(formatted(value, kind: .quotaPercent))%"
            : "\(descriptor.unit ?? "")\(formatted(value, kind: .balance))"
    }

    private func formatted(_ value: Double, kind: BalanceNotificationResourceKind) -> String {
        kind == .quotaPercent ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

}
