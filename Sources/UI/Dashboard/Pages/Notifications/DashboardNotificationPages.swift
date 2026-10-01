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
    var onRuleSource: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool) -> Void)?
    var onRestoreDefaultRules: ((BalanceNotificationAgent) -> Void)?

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

    @objc func ruleSource(_ sender: NSPopUpButton) {
        guard let key = resourceKey(from: sender, prefixes: ["source"]),
              let kind = kind(from: sender),
              let selected = sender.selectedItem?.representedObject as? NSNumber else { return }
        onRuleSource?(key, kind, sender.toolTip?.isEmpty == true ? nil : sender.toolTip, selected.boolValue)
    }

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

    @objc func restoreDefaultRules(_ sender: NSButton) {
        guard let raw = metadata(from: sender, prefix: "restore-default-rules"),
              let agent = BalanceNotificationAgent(rawValue: raw) else { return }
        onRestoreDefaultRules?(agent)
    }


    private func metadata(from sender: NSView, prefix: String) -> String? {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix(prefix + ":") else { return nil }
        return String(raw.dropFirst(prefix.count + 1))
    }

    private func commitGlobalRuleThreshold(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("global-rule:"),
              let separator = raw.lastIndex(of: ":") else {
            return
        }
        let resourceID = String(raw[raw.index(raw.startIndex, offsetBy: "global-rule:".count)..<separator])
        let isSecond = String(raw[raw.index(after: separator)...]) == "second"
        let kind: BalanceNotificationResourceKind = resourceID == "balance" ? .balance : .quotaPercent
        guard let value = ThresholdFormat.parsedValue(sender.stringValue, kind: kind) else { return }
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
        resourceKey(from: sender, prefixes: ["resource"])
    }

    private func resourceKey(from sender: NSView, prefixes: [String]) -> BalanceNotificationResourceKey? {
        guard let raw = sender.identifier?.rawValue,
              let prefix = prefixes.first(where: { raw.hasPrefix($0 + ":") }),
              let first = raw.dropFirst(prefix.count + 1).firstIndex(of: ":"),
              let second = raw[raw.index(after: first)...].firstIndex(of: ":") else { return nil }
        let agentRaw = String(raw.dropFirst(prefix.count + 1).prefix(upTo: first))
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
    private weak var globalSwitch: NSSwitch?
    private weak var notificationSection: SettingsSectionView?
    private weak var agentSettingsView: NSView?
    private var agentRows: [BalanceNotificationAgent: SettingsRowView] = [:]
    private var agentDetailButtons: [BalanceNotificationAgent: NSButton] = [:]
    private var agentMasterRows: [BalanceNotificationAgent: SettingsRowView] = [:]
    private weak var agentChildStack: NSStackView?
    private weak var providerChildStack: NSStackView?
    private var providerRows: [String: SettingsRowView] = [:]
    private var providerDetailButtons: [String: NSButton] = [:]
    private var providerMasterRows: [String: SettingsRowView] = [:]
    private var resourceCards: [BalanceNotificationResourceKey: ResourceRuleCard] = [:]
    private var pauseTimer: Timer?
    private var applyGlobalRulesAlert: NSAlert?

    var applyGlobalRulesAlertForTesting: NSAlert? {
        applyGlobalRulesAlert
    }

    var agentChildStackHiddenForTesting: Bool? {
        agentChildStack?.isHidden
    }

    var providerChildStackHiddenForTesting: Bool? {
        providerChildStack?.isHidden
    }

    func resourceCardForTesting(_ key: BalanceNotificationResourceKey) -> ResourceRuleCard? {
        resourceCards[key]
    }

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
            self.updateAgentMasterRow(agent, enabled: enabled)
            self.updateAgentChildVisibility(enabled: enabled)
            coordinator.performAsync { coordinator.setAgentEnabled(enabled, agent: agent) }
        }
        relay.onProviderToggle = { [weak self] agent, providerID, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            self.updateProviderDetail(agent, providerID: providerID)
            self.updateProviderMasterRow(agent, providerID: providerID, enabled: enabled)
            self.updateProviderChildVisibility(enabled: enabled)
            coordinator.performAsync { coordinator.setProviderEnabled(enabled, agent: agent, providerID: providerID) }
        }
        relay.onResourceToggle = { [weak self] key, kind, unit, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                coordinator.setResourceEnabled(enabled, key: key, kind: kind, unit: unit)
                DispatchQueue.main.async { [weak self] in self?.applyResourceCard(key: key) }
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
                DispatchQueue.main.async { [weak self] in self?.applyResourceCard(key: key) }
            }
        }
        relay.onSecondThresholdToggle = { [weak self] key, kind, unit, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                coordinator.updateRule(key: key, kind: kind, unit: unit) { $0.secondEnabled = enabled }
                DispatchQueue.main.async { [weak self] in self?.applyResourceCard(key: key) }
            }
        }
        relay.onRuleSource = { [weak self] key, kind, unit, usesDefault in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                coordinator.setRuleUsesGlobalDefaults(
                    usesDefault,
                    key: key,
                    kind: kind,
                    unit: unit
                )
                DispatchQueue.main.async { [weak self] in self?.applyResourceCard(key: key) }
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
                    field?.stringValue = ThresholdFormat.displayString(displayed, kind: kind)
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
        relay.onRestoreDefaultRules = { [weak self] agent in
            self?.presentRestoreDefaultRulesConfirmation(for: agent)
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
        self.globalSwitch = globalSwitch
        let globalControls: [NSView] = [globalSwitch]
        let globalAccessory = NSStackView(views: globalControls)
        globalAccessory.orientation = .horizontal
        globalAccessory.spacing = 8
        let global = SettingsRowView(
            title: tr("notifications.quota_reminders"),
            detail: tr("notifications.global_description"),
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
        var globalRows: [NSView] = [global, pauseRow]
        if permission == .denied {
            let systemSettings = NSButton(
                title: tr("notifications.open_system_settings"),
                target: relay,
                action: #selector(DashboardNotificationPageRelay.openSettings(_:))
            )
            let permissionRow = SettingsRowView(
                title: tr("notifications.permission_state"),
                detail: tr("notifications.permission_disabled"),
                accessoryView: systemSettings
            )
            globalRows.append(permissionRow)
        }
        let notificationSection = SettingsSectionView(
            title: tr("notifications.page.title"),
            contentViews: globalRows
        )
        self.notificationSection = notificationSection
        let reminderRules = makeReminderRulesSection(settings: settings)
        let agentSettings = makeAgentSettingsSection(settings: settings)
        self.agentSettingsView = agentSettings
        let details = NSStackView(views: [reminderRules, agentSettings])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = DashboardSettingsComponents.settingsSectionSpacing
        details.detachesHiddenViews = true
        details.translatesAutoresizingMaskIntoConstraints = false
        agentSettings.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        updatePausePresentation()
        startPauseTimer()
        reminderRules.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        return DashboardSettingsComponents.makeSettingsPageContent([
            notificationSection,
            details
        ])
    }

    private func updateGlobalVisibility() {
        // The app switch and its saved rules remain visible when macOS denies
        // permission or the user pauses reminders. Permission is an independent
        // system state; it must never erase or hide BalanceBar configuration.
        globalSwitch?.state = configuration.coordinator.settings.globalEnabled ? .on : .off
        notificationSection?.reconcileSeparators()
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
        let fiveHourKey = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: "five-hour")
        let sevenDayKey = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: "weekly")
        let balanceKey = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: "balance")
        let columnMetrics = makeGlobalRuleColumnMetrics()
        let rows = [
            SettingsRowView(
                title: tr("notifications.five_hour_reminder"),
                accessoryView: makeGlobalRuleAccessory(
                    resourceID: fiveHourKey.resourceID,
                    thresholds: settings.globalThresholds(for: fiveHourKey, kind: .quotaPercent),
                    kind: .quotaPercent,
                    columnMetrics: columnMetrics
                )
            ),
            SettingsRowView(
                title: tr("notifications.seven_day_reminder"),
                accessoryView: makeGlobalRuleAccessory(
                    resourceID: sevenDayKey.resourceID,
                    thresholds: settings.globalThresholds(for: sevenDayKey, kind: .quotaPercent),
                    kind: .quotaPercent,
                    columnMetrics: columnMetrics
                )
            ),
            SettingsRowView(
                title: tr("notifications.balance_reminder"),
                accessoryView: makeGlobalRuleAccessory(
                    resourceID: balanceKey.resourceID,
                    thresholds: settings.globalThresholds(for: balanceKey, kind: .balance),
                    kind: .balance,
                    columnMetrics: columnMetrics
                )
            )
        ]
        let section = SettingsSectionView(
            title: tr("notifications.reminder_rules"),
            contentViews: rows
        )
        let hint = NSTextField(wrappingLabelWithString: tr("notifications.global_rules_hint"))
        hint.identifier = NSUserInterfaceItemIdentifier("global-rules-hint")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let hintRow = NSStackView(views: [hint])
        hintRow.orientation = .horizontal
        hintRow.alignment = .firstBaseline
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        hintRow.edgeInsets = NSEdgeInsets(
            top: 0,
            left: SettingsLayout.rowHorizontalInset,
            bottom: 0,
            right: SettingsLayout.rowHorizontalInset
        )
        let stack = NSStackView(views: [section, hintRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        hintRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
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
        let first = makeGlobalRuleField(resourceID: resourceID, isSecond: false, value: thresholds.first, kind: kind)
        let second = makeGlobalRuleField(resourceID: resourceID, isSecond: true, value: thresholds.second, kind: kind)
        let unitText = thresholdEditorUnitText(kind: kind, unit: nil)
        let firstGroup = makeGlobalRuleGroup(
            label: firstLabel,
            field: first,
            unitText: unitText,
            columnMetrics: columnMetrics
        )
        let secondGroup = makeGlobalRuleGroup(
            label: secondLabel,
            field: second,
            unitText: unitText,
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
        let balanceField = makeGlobalRuleField(
            resourceID: "column-metrics-balance",
            isSecond: false,
            value: 0,
            kind: .balance
        )
        let percentUnitText = thresholdEditorUnitText(kind: .quotaPercent, unit: nil)
        let balanceUnitText = thresholdEditorUnitText(kind: .balance, unit: nil)
        return GlobalRuleColumnMetrics(
            labelWidth: ceil(max(firstLabel.fittingSize.width, secondLabel.fittingSize.width)),
            percentFieldWidth: ceil(max(quotaField.fittingSize.width, balanceField.fittingSize.width)),
            unitWidth: max(globalRuleUnitTextWidth(percentUnitText), globalRuleUnitTextWidth(balanceUnitText))
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
        unitText: String,
        columnMetrics: GlobalRuleColumnMetrics
    ) -> NSStackView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        let valueWidth = columnMetrics.percentFieldWidth
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
        views.append(makeGlobalRuleUnitSlot(unitText, width: columnMetrics.unitWidth))
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = columnMetrics.valueSpacing
        group.widthAnchor.constraint(equalToConstant: columnMetrics.groupWidth).isActive = true
        group.setContentHuggingPriority(.required, for: .horizontal)
        group.setContentCompressionResistancePriority(.required, for: .horizontal)
        return group
    }

    private func globalRuleUnitTextWidth(_ text: String) -> CGFloat {
        let unit = NSTextField(labelWithString: text)
        unit.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        return ceil(unit.fittingSize.width)
    }

    private func makeGlobalRuleUnitSlot(_ text: String, width: CGFloat) -> NSTextField {
        let unit = NSTextField(labelWithString: text)
        unit.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        unit.lineBreakMode = .byClipping
        unit.usesSingleLineMode = true
        unit.cell?.truncatesLastVisibleLine = false
        unit.widthAnchor.constraint(equalToConstant: width).isActive = true
        unit.setContentHuggingPriority(.required, for: .horizontal)
        unit.setContentCompressionResistancePriority(.required, for: .horizontal)
        return unit
    }

    private func makeGlobalRuleField(
        resourceID: String,
        isSecond: Bool,
        value: Double,
        kind: BalanceNotificationResourceKind
    ) -> DashboardSettingsComponents.CompactNumericFieldAccessory {
        let identifier = "global-rule:\(resourceID):\(isSecond ? "second" : "first")"
        let accessory = DashboardSettingsComponents.makeNumericTextField(
            identifier: identifier,
            value: ThresholdFormat.displayString(value, kind: kind),
            placeholder: ThresholdFormat.placeholder,
            capacityTemplate: kind == .quotaPercent ? "000" : DashboardSettingsComponents.amountCapacityTemplate,
            delegate: relay,
            toolTip: tr("notifications.threshold_input_hint")
        )
        return accessory
    }

    private func makeAgentSettingsSection(settings: BalanceNotificationSettings) -> NSView {
        agentRows.removeAll(keepingCapacity: true)
        agentDetailButtons.removeAll(keepingCapacity: true)
        let rows = BalanceNotificationAgent.dashboardCases.map {
            let row = makeAgentRow($0, settings: settings)
            agentRows[$0] = row
            return row
        }
        return SettingsSectionView(
            title: tr("notifications.agent_settings"),
            contentViews: rows
        )
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
            title: tr("notifications.details"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.agent(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("agent:\(agent.rawValue)")
        agentDetailButtons[agent] = button
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
        if settings.hasCustomRules(for: agent) {
            return tr("notifications.agent_customized")
        }
        return tr("notifications.agent_follows_global")
    }

    private func updateAgentDetail(_ agent: BalanceNotificationAgent, enabled: Bool) {
        guard let row = agentRows[agent] else { return }
        let settings = configuration.coordinator.settings
        row.updateDetail(agentDetail(agent, enabled: enabled, settings: settings))
    }

    private func makeAgentPage(_ agent: BalanceNotificationAgent) -> NSView {
        let providers = configuration.providerChoices(agent)
        let settings = configuration.coordinator.settings
        providerRows.removeAll(keepingCapacity: true)
        providerDetailButtons.removeAll(keepingCapacity: true)
        agentMasterRows.removeAll(keepingCapacity: true)
        let agentSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "agent:\(agent.rawValue)",
            isOn: settings.isAgentEnabled(agent),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.agentToggle(_:))
        )
        let agentMasterRow = SettingsRowView(
            title: "\(agent.title) \(tr("notifications.quota_reminders"))",
            detail: settings.isAgentEnabled(agent)
                ? tr("notifications.agent_enabled")
                : tr("notifications.agent_disabled"),
            accessoryView: agentSwitch
        )
        agentMasterRows[agent] = agentMasterRow
        var providerViews: [NSView] = []
        if providers.isEmpty {
            providerViews.append(SettingsRowView(
                title: agent.title,
                detail: tr("notifications.no_providers")
            ))
        } else {
            providerViews.append(contentsOf: providers.map { provider in
                let row = makeProviderRow(agent: agent, provider: provider, settings: settings)
                providerRows[providerRowKey(agent, providerID: provider.id)] = row
                return row
            })
        }
        let providerSection = SettingsSectionView(
            title: tr("notifications.provider_rules"),
            contentViews: providerViews
        )
        var childViews: [NSView] = [providerSection]
        if settings.hasCustomRules(for: agent) {
            let restoreButton = NSButton(
                title: tr("notifications.restore_default_rules"),
                target: relay,
                action: #selector(DashboardNotificationPageRelay.restoreDefaultRules(_:))
            )
            restoreButton.identifier = NSUserInterfaceItemIdentifier("restore-default-rules:\(agent.rawValue)")
            let restoreRow = SettingsRowView(
                title: tr("notifications.restore_default_rules_title"),
                detail: tr("notifications.restore_default_rules_detail"),
                accessoryView: restoreButton
            )
            restoreRow.titleLabel.textColor = .systemRed
            childViews.append(SettingsSectionView(title: "", contentViews: [restoreRow]))
        }
        let childStack = NSStackView(views: childViews)
        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = DashboardSettingsComponents.settingsSectionSpacing
        childStack.detachesHiddenViews = true
        childStack.translatesAutoresizingMaskIntoConstraints = false
        childViews.forEach { view in
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.widthAnchor.constraint(equalTo: childStack.widthAnchor).isActive = true
        }
        agentChildStack = childStack
        let header = DashboardSettingsComponents.makePageHeader(
            agent.title,
            subtitle: tr("notifications.agent_page_description")
        )
        let page = DashboardSettingsComponents.makeSettingsPageContent([
            header,
            SettingsSectionView(title: tr("notifications.agent_settings"), contentViews: [agentMasterRow]),
            childStack
        ])
        updateAgentChildVisibility(enabled: settings.isAgentEnabled(agent))
        return page
    }

    private func updateAgentChildVisibility(enabled: Bool) {
        agentChildStack?.isHidden = !enabled
    }

    private func updateProviderChildVisibility(enabled: Bool) {
        providerChildStack?.isHidden = !enabled
    }

    private func updateAgentMasterRow(_ agent: BalanceNotificationAgent, enabled: Bool) {
        agentMasterRows[agent]?.updateDetail(
            enabled ? tr("notifications.agent_enabled") : tr("notifications.agent_disabled")
        )
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
            title: tr("notifications.details"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.provider(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier("provider:\(agent.rawValue):\(provider.id)")
        providerDetailButtons[providerRowKey(agent, providerID: provider.id)] = button
        let controls = NSStackView(views: [button, toggle])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.detachesHiddenViews = true
        let detail = providerUsesCustomRules(settings, agent: agent, providerID: provider.id)
            ? tr("notifications.agent_customized")
            : tr("notifications.agent_follows_global")
        return SettingsRowView(title: provider.name, detail: detail, accessoryView: controls)
    }

    private func providerRowKey(_ agent: BalanceNotificationAgent, providerID: String) -> String {
        "\(agent.rawValue):\(providerID)"
    }

    private func updateProviderDetail(
        _ agent: BalanceNotificationAgent,
        providerID: String
    ) {
        let key = providerRowKey(agent, providerID: providerID)
        let settings = configuration.coordinator.settings
        providerRows[key]?.updateDetail(
            providerUsesCustomRules(settings, agent: agent, providerID: providerID)
                ? tr("notifications.agent_customized")
                : tr("notifications.agent_follows_global")
        )
    }

    private func updateProviderMasterRow(
        _ agent: BalanceNotificationAgent,
        providerID: String,
        enabled: Bool
    ) {
        providerMasterRows[providerRowKey(agent, providerID: providerID)]?.updateDetail(
            enabled ? tr("notifications.agent_enabled") : tr("notifications.agent_disabled")
        )
    }

    private func providerUsesCustomRules(
        _ settings: BalanceNotificationSettings,
        agent: BalanceNotificationAgent,
        providerID: String
    ) -> Bool {
        settings.resourceRules.contains {
            $0.key.agent == agent && $0.key.providerID == providerID && !$0.usesGlobalDefaults
        }
    }

    private func presentRestoreDefaultRulesConfirmation(for agent: BalanceNotificationAgent) {
        if applyGlobalRulesAlert?.window.sheetParent != nil { return }
        guard let hostWindow = currentPage?.window ?? container.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("notifications.restore_default_rules_message", arguments: [agent.title])
        alert.informativeText = tr("notifications.restore_default_rules_detail")
        alert.addButton(withTitle: tr("notifications.restore_default_rules_confirm"))
        alert.addButton(withTitle: tr("notifications.restore_default_rules_cancel"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalentModifierMask = []
        applyGlobalRulesAlert = alert
        alert.beginSheetModal(for: hostWindow) { [weak self] response in
            guard let self else { return }
            self.applyGlobalRulesAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            self.configuration.coordinator.performAsync { [weak self] in
                guard let self else { return }
                self.configuration.coordinator.applyGlobalRules(to: agent)
                DispatchQueue.main.async { [weak self] in
                    self?.rebuild()
                }
            }
        }
    }

    private func makeProviderPage(_ agent: BalanceNotificationAgent, providerID: String) -> NSView {
        let descriptors = configuration.coordinator.resourceDescriptors(agent: agent, providerID: providerID)
        let settings = configuration.coordinator.settings
        resourceCards.removeAll(keepingCapacity: true)
        providerMasterRows.removeAll(keepingCapacity: true)
        let providerName = configuration.providerChoices(agent).first { $0.id == providerID }?.name ?? providerID
        let providerSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "provider:\(agent.rawValue):\(providerID)",
            isOn: settings.isProviderEnabled(agent, providerID: providerID),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.providerToggle(_:))
        )
        let providerMasterRow = SettingsRowView(
            title: "\(providerName) \(tr("notifications.quota_reminders"))",
            detail: settings.isProviderEnabled(agent, providerID: providerID)
                ? tr("notifications.agent_enabled")
                : tr("notifications.agent_disabled"),
            accessoryView: providerSwitch
        )
        providerMasterRows[providerRowKey(agent, providerID: providerID)] = providerMasterRow
        var childViews: [NSView] = []
        if descriptors.isEmpty {
            childViews.append(SettingsSectionView(
                title: tr("notifications.resource_rules"),
                contentViews: [SettingsRowView(
                    title: tr("notifications.resource_rules"),
                    detail: tr("notifications.no_providers")
                )]
            ))
        } else {
            for descriptor in descriptors {
                let card = makeResourceCard(descriptor, settings: settings)
                resourceCards[descriptor.key] = card
                childViews.append(card)
            }
        }
        let childStack = NSStackView(views: childViews)
        childStack.orientation = .vertical
        childStack.alignment = .leading
        childStack.spacing = DashboardSettingsComponents.settingsSectionSpacing
        childStack.detachesHiddenViews = true
        childStack.translatesAutoresizingMaskIntoConstraints = false
        childViews.forEach { view in
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.widthAnchor.constraint(equalTo: childStack.widthAnchor).isActive = true
        }
        providerChildStack = childStack
        updateProviderChildVisibility(
            enabled: settings.isProviderEnabled(agent, providerID: providerID)
        )
        let header = DashboardSettingsComponents.makePageHeader(providerName, subtitle: agent.title)
        return DashboardSettingsComponents.makeSettingsPageContent([
            header,
            SettingsSectionView(title: tr("notifications.provider_rules"), contentViews: [providerMasterRow]),
            childStack
        ])
    }

    private func makeResourceCard(
        _ descriptor: BalanceNotificationResourceDescriptor,
        settings: BalanceNotificationSettings
    ) -> ResourceRuleCard {
        let card = ResourceRuleCard(
            title: ResourceRuleCard.localizedTitle(
                resourceID: descriptor.key.resourceID,
                fallback: descriptor.title
            ),
            key: descriptor.key,
            kind: descriptor.kind,
            unit: descriptor.unit,
            initial: resourceState(for: descriptor, settings: settings)
        )
        card.onEvent = { [weak self, weak card] event in
            guard let self, let card else { return }
            self.handleResourceEvent(event, descriptor: descriptor, card: card)
        }
        return card
    }

    private func resourceState(
        for descriptor: BalanceNotificationResourceDescriptor,
        settings: BalanceNotificationSettings
    ) -> ResourceRuleState {
        let storedRule = settings.rule(for: descriptor.key)
        let usesGlobalDefaults = storedRule?.usesGlobalDefaults ?? true
        var rule = usesGlobalDefaults
            ? settings.defaultRule(for: descriptor.key, kind: descriptor.kind, unit: descriptor.unit)
            : (storedRule ?? settings.defaultRule(for: descriptor.key, kind: descriptor.kind, unit: descriptor.unit))
        if let storedRule {
            rule.enabled = storedRule.enabled
        }
        let secondThreshold = rule.secondEnabled ? rule.secondThreshold : 0
        return ResourceRuleState(
            resourceEnabled: rule.enabled,
            usesGlobalDefaults: usesGlobalDefaults,
            currentRemaining: descriptor.value ?? 0,
            firstThreshold: rule.firstThreshold,
            secondThreshold: secondThreshold
        )
    }

    private func handleResourceEvent(
        _ event: ResourceRuleEvent,
        descriptor: BalanceNotificationResourceDescriptor,
        card: ResourceRuleCard
    ) {
        let key = descriptor.key
        let kind = descriptor.kind
        let unit = descriptor.unit
        let coordinator = configuration.coordinator
        var next = card.state
        switch event {
        case .resourceToggled(let enabled):
            next.resourceEnabled = enabled
            card.apply(next)
            coordinator.performAsync {
                coordinator.setResourceEnabled(enabled, key: key, kind: kind, unit: unit)
            }
        case .sourceChanged(let usesGlobalDefaults):
            next.usesGlobalDefaults = usesGlobalDefaults
            card.apply(next)
            coordinator.performAsync {
                coordinator.setRuleUsesGlobalDefaults(
                    usesGlobalDefaults,
                    key: key,
                    kind: kind,
                    unit: unit
                )
                DispatchQueue.main.async { [weak self] in self?.applyResourceCard(key: key) }
            }
        case .thresholdEdited(index: let index, value: let value):
            if index == 0 {
                next.firstThreshold = max(0, value)
                if next.firstThreshold > 0, next.secondThreshold > 0 {
                    let step: Double = kind == .quotaPercent ? 1 : 0.01
                    if next.secondThreshold >= next.firstThreshold {
                        next.secondThreshold = max(0, next.firstThreshold - step)
                    }
                }
            } else {
                next.secondThreshold = max(0, value)
                if next.firstThreshold > 0, next.secondThreshold > 0,
                   next.secondThreshold >= next.firstThreshold {
                    let step: Double = kind == .quotaPercent ? 1 : 0.01
                    next.secondThreshold = max(0, next.firstThreshold - step)
                }
            }
            card.apply(next)
            let first = next.firstThreshold
            let second = next.secondThreshold
            coordinator.performAsync {
                coordinator.updateRule(key: key, kind: kind, unit: unit) { rule in
                    rule.firstThreshold = first
                    rule.secondThreshold = second
                    rule.secondEnabled = second > 0
                }
                DispatchQueue.main.async { [weak self] in self?.applyResourceCard(key: key) }
            }
        case .editDefaultsTapped:
            showRoot()
        }
    }

    private func applyResourceCard(key: BalanceNotificationResourceKey) {
        guard let card = resourceCards[key] else { return }
        let settings = configuration.coordinator.settings
        let descriptors = configuration.coordinator.resourceDescriptors(
            agent: key.agent,
            providerID: key.providerID
        )
        guard let descriptor = descriptors.first(where: { $0.key == key }) else { return }
        card.apply(resourceState(for: descriptor, settings: settings))
    }

    private func thresholdEditorUnitText(
        kind: BalanceNotificationResourceKind,
        unit: String?
    ) -> String {
        if kind == .quotaPercent {
            return "%"
        }
        let raw = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "USD" : raw
    }

    private func balanceText(_ value: Double, unit: String?) -> String {
        let number = formatted(value, kind: .balance)
        guard let unit, !unit.isEmpty else { return "\(number) USD" }
        if ["$", "€", "£", "¥"].contains(unit) {
            return "\(unit)\(number)"
        }
        return "\(number) \(unit)"
    }

    private func formatted(_ value: Double, kind: BalanceNotificationResourceKind) -> String {
        kind == .quotaPercent ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

}
