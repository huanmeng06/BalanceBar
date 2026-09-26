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
    var onGlobalRuleThreshold: ((String, Bool, Double) -> Void)?
    var onResume: (() -> Void)?
    var onBack: (() -> Void)?
    var onAgent: ((BalanceNotificationAgent) -> Void)?
    var onProvider: ((BalanceNotificationAgent, String) -> Void)?
    var onResource: ((BalanceNotificationResourceKey) -> Void)?

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
    @objc func globalRuleThreshold(_ sender: NSTextField) {
        commitGlobalRuleThreshold(sender)
    }
    @objc func resume(_ sender: NSButton) { onResume?() }
    @objc func back(_ sender: NSButton) { onBack?() }

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

    @objc func resource(_ sender: NSButton) {
        guard let key = resourceKey(from: sender) else { return }
        onResource?(key)
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
        onGlobalRuleThreshold?(resourceID, isSecond, value)
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

/// Native Dashboard pages for the notification hierarchy. Navigation stays
/// inside the content pane so the existing Dashboard sidebar geometry and
/// search behavior remain unchanged.
final class DashboardNotificationPages {
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
    private var pauseTimer: Timer?

    private enum NotificationPagePath: Equatable {
        case root
        case agent(BalanceNotificationAgent)
        case provider(BalanceNotificationAgent, String)
        case resource(BalanceNotificationResourceKey)
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
            coordinator.performAsync { coordinator.setAgentEnabled(enabled, agent: agent) }
        }
        relay.onProviderToggle = { [weak self] agent, providerID, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync { coordinator.setProviderEnabled(enabled, agent: agent, providerID: providerID) }
        }
        relay.onResourceToggle = { [weak self] key, kind, unit, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
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
        relay.onGlobalRuleThreshold = { [weak self] resourceID, isSecond, value in
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
                coordinator.updateGlobalRule(
                    resourceID: resourceID,
                    kind: kind,
                    firstThreshold: first,
                    secondThreshold: second
                )
                DispatchQueue.main.async { [weak self] in self?.refresh() }
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
        relay.onBack = { [weak self] in self?.goBack() }
        relay.onAgent = { [weak self] agent in self?.path = [.agent(agent)]; self?.rebuild() }
        relay.onProvider = { [weak self] agent, providerID in self?.path = [.provider(agent, providerID)]; self?.rebuild() }
        relay.onResource = { [weak self] key in self?.path = [.resource(key)]; self?.rebuild() }
        container.translatesAutoresizingMaskIntoConstraints = false
    }

    deinit {
        pauseTimer?.invalidate()
    }

    func make() -> NSView {
        if currentPage == nil { rebuild() }
        return container
    }

    func refresh() {
        guard currentPage != nil else { return }
        rebuild()
    }

    func showAgent(_ agent: BalanceNotificationAgent) {
        path = [.agent(agent)]
        rebuild()
    }

    private func rebuild() {
        let page: NSView
        switch path.last ?? .root {
        case .root: page = makeRootPage()
        case .agent(let agent): page = makeAgentPage(agent)
        case .provider(let agent, let providerID): page = makeProviderPage(agent, providerID: providerID)
        case .resource(let key): page = makeResourcePage(key)
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
        subtitle.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .vertical)

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
                kind: .quotaPercent
            )
        )
        let sevenDay = SettingsRowView(
            title: tr("notifications.seven_day_reminder"),
            accessoryView: makeGlobalRuleAccessory(
                resourceID: sevenDayKey.resourceID,
                thresholds: settings.globalThresholds(for: sevenDayKey, kind: .quotaPercent),
                kind: .quotaPercent
            )
        )
        let balance = SettingsRowView(
            title: tr("notifications.balance_reminder"),
            accessoryView: makeGlobalRuleAccessory(
                resourceID: balanceKey.resourceID,
                thresholds: settings.globalThresholds(for: balanceKey, kind: .balance),
                kind: .balance
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
        kind: BalanceNotificationResourceKind
    ) -> NSView {
        let first = makeGlobalRuleField(
            resourceID: resourceID,
            isSecond: false,
            value: thresholds.first,
            kind: kind
        )
        let second = makeGlobalRuleField(
            resourceID: resourceID,
            isSecond: true,
            value: thresholds.second,
            kind: kind
        )
        let firstGroup = makeGlobalRuleInputGroup(
            label: tr("notifications.first_reminder"),
            field: first,
            showsPercent: kind == .quotaPercent
        )
        let secondGroup = makeGlobalRuleInputGroup(
            label: tr("notifications.second_reminder"),
            field: second,
            showsPercent: kind == .quotaPercent
        )
        let accessory = NSStackView(views: [firstGroup, secondGroup])
        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 20
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        return accessory
    }

    private func makeGlobalRuleInputGroup(
        label: String,
        field: DashboardSettingsComponents.CompactNumericFieldAccessory,
        showsPercent: Bool
    ) -> NSView {
        var views: [NSView] = [NSTextField(labelWithString: label), field]
        if showsPercent {
            views.append(NSTextField(labelWithString: "%"))
        }
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.setContentHuggingPriority(.required, for: .horizontal)
        group.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in group.arrangedSubviews where view is NSTextField {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return group
    }

    private func makeGlobalRuleField(
        resourceID: String,
        isSecond: Bool,
        value: Double,
        kind: BalanceNotificationResourceKind
    ) -> DashboardSettingsComponents.CompactNumericFieldAccessory {
        let identifier = "global-rule:" + resourceID + ":" + (isSecond ? "second" : "first")
        let field = DashboardSettingsComponents.makeNumericTextField(
            identifier: identifier,
            value: formattedGlobalRuleValue(value, kind: kind),
            placeholder: "0",
            capacityTemplate: kind == .quotaPercent ? "000" : DashboardSettingsComponents.amountCapacityTemplate,
            delegate: relay,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.globalRuleThreshold(_:)),
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
        let cards = NSStackView(views: BalanceNotificationAgent.dashboardCases.map {
            SettingsSectionView(
                title: "",
                contentViews: [makeAgentRow($0, settings: settings)]
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
    ) -> NSView {
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
        let controls = NSStackView(views: [agentSwitch, button])
        controls.orientation = .horizontal
        controls.spacing = 8
        let detail: String
        if !settings.isAgentEnabled(agent) {
            detail = tr("notifications.agent_disabled")
        } else if settings.hasCustomRules(for: agent) {
            detail = tr("notifications.agent_customized")
        } else {
            detail = tr("notifications.agent_follows_global")
        }
        return SettingsRowView(title: agent.title, detail: detail, accessoryView: controls)
    }

    private func makeAgentPage(_ agent: BalanceNotificationAgent) -> NSView {
        let providers = configuration.providerChoices(agent)
        let settings = configuration.coordinator.settings
        var rows: [NSView] = [backButton()]
        if providers.isEmpty {
            rows.append(SettingsRowView(
                title: agent.title,
                detail: tr("notifications.no_providers")
            ))
        } else {
            rows.append(contentsOf: providers.map { provider in
                makeProviderRow(agent: agent, provider: provider, settings: settings)
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
    ) -> NSView {
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
        let controls = NSStackView(views: [toggle, button])
        controls.orientation = .horizontal
        controls.spacing = 8
        let detail = settings.isProviderEnabled(agent, providerID: provider.id)
            ? tr("notifications.agent_enabled")
            : tr("notifications.agent_disabled")
        return SettingsRowView(title: provider.name, detail: detail, accessoryView: controls)
    }

    private func makeProviderPage(_ agent: BalanceNotificationAgent, providerID: String) -> NSView {
        let descriptors = configuration.coordinator.resourceDescriptors(agent: agent, providerID: providerID)
        let settings = configuration.coordinator.settings
        var rows: [NSView] = [backButton()]
        if descriptors.isEmpty {
            rows.append(SettingsRowView(title: tr("notifications.resource_rules"), detail: tr("notifications.no_providers")))
        } else {
            rows.append(contentsOf: descriptors.map { descriptor in
                makeResourceRow(descriptor, settings: settings)
            })
        }
        let providerName = configuration.providerChoices(agent).first { $0.id == providerID }?.name ?? providerID
        return DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "\(agent.title) · \(providerName)", contentViews: rows)
        ])
    }

    private func makeResourcePage(_ key: BalanceNotificationResourceKey) -> NSView {
        let descriptor = configuration.coordinator.resourceDescriptors(
            agent: key.agent,
            providerID: key.providerID
        ).first { $0.key == key }
        guard let descriptor else {
            return DashboardSettingsComponents.makeSettingsPageContent([SettingsSectionView(title: tr("notifications.resource_rules"), contentViews: [backButton()])])
        }
        let settings = configuration.coordinator.settings
        let rule = settings.rule(for: key) ?? settings.defaultRule(for: key, kind: descriptor.kind, unit: descriptor.unit)
        let enabled = DashboardSettingsComponents.makeSwitch(
            identifier: "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)",
            isOn: rule.enabled,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.resourceToggle(_:))
        )
        enabled.toolTip = descriptor.unit ?? ""
        enabled.setAccessibilityValue(descriptor.kind.rawValue)

        let firstField = thresholdField(rule.firstThreshold, key: key, kind: descriptor.kind, unit: descriptor.unit, isSecond: false)
        let firstRow = SettingsRowView(
            title: tr("notifications.first_threshold"),
            detail: thresholdDetail(rule, descriptor: descriptor, second: false),
            accessoryView: firstField
        )
        let secondSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)",
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
        let secondField = thresholdField(rule.secondThreshold, key: key, kind: descriptor.kind, unit: descriptor.unit, isSecond: true)
        let secondThresholdRow = SettingsRowView(
            title: tr("notifications.second_threshold"),
            detail: thresholdDetail(rule, descriptor: descriptor, second: true),
            accessoryView: secondField
        )
        let enableRow = SettingsRowView(
            title: descriptor.title,
            detail: descriptor.unit == "%" ? tr("notifications.quota_value", arguments: [descriptor.title, formatted(descriptor.value ?? 0, kind: .quotaPercent)]) : tr("notifications.balance_value", arguments: [descriptor.title, formatted(descriptor.value ?? 0, kind: .balance)]),
            accessoryView: enabled
        )
        return DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: "\(tr("notifications.resource_rules")) · \(descriptor.title)", contentViews: [backButton(), enableRow, firstRow, secondRow, secondThresholdRow])
        ])
    }

    private func makeResourceRow(
        _ descriptor: BalanceNotificationResourceDescriptor,
        settings: BalanceNotificationSettings
    ) -> NSView {
        let rule = settings.rule(for: descriptor.key) ?? settings.defaultRule(for: descriptor.key, kind: descriptor.kind, unit: descriptor.unit)
        let button = NSButton(
            title: tr("notifications.advanced_settings"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.resource(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("resource:\(descriptor.key.agent.rawValue):\(descriptor.key.providerID):\(descriptor.key.resourceID)")
        let toggle = DashboardSettingsComponents.makeSwitch(
            identifier: button.identifier!.rawValue,
            isOn: rule.enabled,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.resourceToggle(_:))
        )
        toggle.toolTip = descriptor.unit ?? ""
        toggle.setAccessibilityValue(descriptor.kind.rawValue)
        let controls = NSStackView(views: [toggle, button])
        controls.orientation = .horizontal
        controls.spacing = 8
        return SettingsRowView(title: descriptor.title, detail: thresholdDetail(rule, descriptor: descriptor, second: false), accessoryView: controls)
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

    private func backButton() -> NSButton {
        NSButton(title: tr("notifications.back"), target: relay, action: #selector(DashboardNotificationPageRelay.back(_:)))
    }

    private func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
        rebuild()
    }
}
