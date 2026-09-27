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
    var onGlobalSecondToggle: ((String, Bool) -> Void)?
    var onResume: (() -> Void)?
    var onAgent: ((BalanceNotificationAgent) -> Void)?
    var onProvider: ((BalanceNotificationAgent, String) -> Void)?
    var onEditDefaultRules: (() -> Void)?
    var onFinishDefaultRules: (() -> Void)?
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

    @objc func editDefaultRules(_ sender: NSButton) { onEditDefaultRules?() }

    @objc func finishDefaultRules(_ sender: NSButton) { onFinishDefaultRules?() }

    @objc func globalSecondToggle(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("global-second:") else { return }
        onGlobalSecondToggle?(String(raw.dropFirst("global-second:".count)), sender.state == .on)
    }

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
    private weak var reminderRulesView: NSView?
    private weak var agentSettingsView: NSView?
    private weak var detailsStack: NSStackView?
    private var agentRows: [BalanceNotificationAgent: SettingsRowView] = [:]
    private var agentDetailButtons: [BalanceNotificationAgent: NSButton] = [:]
    private var providerRows: [String: SettingsRowView] = [:]
    private var providerDetailButtons: [String: NSButton] = [:]
    private var resourceRuleRows: [BalanceNotificationResourceKey: ResourceRuleRows] = [:]
    private var globalSecondThresholdRows: [String: SettingsRowView] = [:]
    private var globalSecondThresholdFields: [String: NSTextField] = [:]
    private var pauseTimer: Timer?
    private var applyGlobalRulesAlert: NSAlert?
    private var editingDefaultRules = false

    var applyGlobalRulesAlertForTesting: NSAlert? {
        applyGlobalRulesAlert
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

    private final class ResourceRuleRows {
        let enableRow: SettingsRowView
        let sourceRow: SettingsRowView
        let firstThresholdRow: SettingsRowView
        let secondToggleRow: SettingsRowView
        let secondThresholdRow: SettingsRowView
        let firstField: NSTextField
        let secondField: NSTextField
        let secondSwitch: NSSwitch
        weak var section: SettingsSectionView?
        private(set) var resourceEnabled = false
        private(set) var secondEnabled = false
        private(set) var usesGlobalDefaults = true

        init(
            enableRow: SettingsRowView,
            sourceRow: SettingsRowView,
            firstThresholdRow: SettingsRowView,
            secondToggleRow: SettingsRowView,
            secondThresholdRow: SettingsRowView,
            firstField: NSTextField,
            secondField: NSTextField,
            secondSwitch: NSSwitch
        ) {
            self.enableRow = enableRow
            self.sourceRow = sourceRow
            self.firstThresholdRow = firstThresholdRow
            self.secondToggleRow = secondToggleRow
            self.secondThresholdRow = secondThresholdRow
            self.firstField = firstField
            self.secondField = secondField
            self.secondSwitch = secondSwitch
        }

        func updateVisibility(resourceEnabled: Bool, secondEnabled: Bool, usesGlobalDefaults: Bool? = nil) {
            self.resourceEnabled = resourceEnabled
            self.secondEnabled = secondEnabled
            if let usesGlobalDefaults { self.usesGlobalDefaults = usesGlobalDefaults }
            enableRow.isHidden = false
            sourceRow.isHidden = false
            firstThresholdRow.isHidden = !resourceEnabled
            secondToggleRow.isHidden = !resourceEnabled
            secondThresholdRow.isHidden = !resourceEnabled || !secondEnabled
            firstField.isEditable = !self.usesGlobalDefaults
            firstField.isEnabled = !self.usesGlobalDefaults
            secondField.isEditable = !self.usesGlobalDefaults
            secondField.isEnabled = !self.usesGlobalDefaults
            secondSwitch.isEnabled = !self.usesGlobalDefaults
            section?.reconcileSeparators()
        }

        func updateInheritance(_ usesGlobalDefaults: Bool) {
            self.usesGlobalDefaults = usesGlobalDefaults
            firstField.isEditable = !usesGlobalDefaults
            firstField.isEnabled = !usesGlobalDefaults
            secondField.isEditable = !usesGlobalDefaults
            secondField.isEnabled = !usesGlobalDefaults
            secondSwitch.isEnabled = !usesGlobalDefaults
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
            coordinator.performAsync { coordinator.setAgentEnabled(enabled, agent: agent) }
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
                DispatchQueue.main.async { [weak self] in
                    self?.updateResourceInheritance(key: key, usesGlobalDefaults: usesDefault)
                }
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
        relay.onGlobalSecondToggle = { [weak self] resourceID, enabled in
            guard let self else { return }
            let coordinator = self.configuration.coordinator
            coordinator.performAsync {
                let key = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: resourceID)
                let kind: BalanceNotificationResourceKind = resourceID == "balance" ? .balance : .quotaPercent
                let current = coordinator.settings.globalThresholds(for: key, kind: kind)
                let second = enabled
                    ? (current.second > 0 ? current.second : max(kind == .balance ? 0.01 : 1, current.first / 2))
                    : 0
                coordinator.updateGlobalRule(
                    resourceID: resourceID,
                    kind: kind,
                    firstThreshold: current.first,
                    secondThreshold: second
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.globalSecondThresholdRows[resourceID]?.isHidden = !enabled
                    if let field = self.globalSecondThresholdFields[resourceID] {
                        field.stringValue = enabled
                            ? self.formatted(second, kind: kind)
                            : ""
                    }
                    self.globalSecondThresholdRows[resourceID]?.superview?.needsLayout = true
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
        relay.onEditDefaultRules = { [weak self] in
            guard let self else { return }
            self.editingDefaultRules = true
            self.replaceReminderRulesView()
        }
        relay.onFinishDefaultRules = { [weak self] in
            guard let self else { return }
            self.editingDefaultRules = false
            self.replaceReminderRulesView()
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

    private func replaceReminderRulesView() {
        guard (path.last ?? .root) == .root,
              let oldView = reminderRulesView,
              let detailsStack,
              let index = detailsStack.arrangedSubviews.firstIndex(where: { $0 === oldView }) else { return }
        let newView = makeReminderRulesSection(settings: configuration.coordinator.settings)
        detailsStack.removeArrangedSubview(oldView)
        oldView.removeFromSuperview()
        detailsStack.insertView(newView, at: index, in: .top)
        newView.widthAnchor.constraint(equalTo: detailsStack.widthAnchor).isActive = true
        reminderRulesView = newView
        detailsStack.needsLayout = true
        detailsStack.superview?.needsLayout = true
    }

    private func makeReminderRulesSection(settings: BalanceNotificationSettings) -> NSView {
        globalSecondThresholdRows.removeAll(keepingCapacity: true)
        globalSecondThresholdFields.removeAll(keepingCapacity: true)
        let fiveHourKey = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: "five-hour")
        let sevenDayKey = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: "weekly")
        let balanceKey = BalanceNotificationResourceKey(agent: .gpt, providerID: "global", resourceID: "balance")
        let definitions: [(String, BalanceNotificationResourceKey, BalanceNotificationResourceKind)] = [
            (tr("notifications.five_hour_reminder"), fiveHourKey, .quotaPercent),
            (tr("notifications.seven_day_reminder"), sevenDayKey, .quotaPercent),
            (tr("notifications.balance_reminder"), balanceKey, .balance)
        ]
        let rows: [NSView]
        if editingDefaultRules {
            rows = definitions.flatMap { title, key, kind in
                makeDefaultRuleEditorRows(title: title, resourceID: key.resourceID, thresholds: settings.globalThresholds(for: key, kind: kind), kind: kind)
            } + [makeDoneEditingRow()]
        } else {
            rows = definitions.map { title, key, kind in
                let thresholds = settings.globalThresholds(for: key, kind: kind)
                let edit = NSButton(
                    title: tr("notifications.edit"),
                    target: relay,
                    action: #selector(DashboardNotificationPageRelay.editDefaultRules(_:))
                )
                edit.identifier = NSUserInterfaceItemIdentifier("default-rule-edit:\(key.resourceID)")
                return SettingsRowView(
                    title: title,
                    detail: defaultRuleSummary(thresholds, kind: kind),
                    accessoryView: edit
                )
            }
        }
        let subtitle = NSTextField(wrappingLabelWithString: tr("notifications.global_rules_hint"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let section = SettingsSectionView(
            title: tr("notifications.reminder_rules"),
            contentViews: [subtitle] + rows
        )
        return section
    }

    private func makeDoneEditingRow() -> SettingsRowView {
        let done = NSButton(
            title: tr("notifications.done"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.finishDefaultRules(_:))
        )
        done.identifier = NSUserInterfaceItemIdentifier("default-rules-done")
        return SettingsRowView(
            title: tr("notifications.default_rules"),
            detail: tr("notifications.default_rules_edit_hint"),
            accessoryView: done
        )
    }

    private func makeDefaultRuleEditorRows(
        title: String,
        resourceID: String,
        thresholds: (first: Double, second: Double),
        kind: BalanceNotificationResourceKind
    ) -> [SettingsRowView] {
        let firstField = makeGlobalRuleField(resourceID: resourceID, isSecond: false, value: thresholds.first, kind: kind)
        let firstRow = SettingsRowView(
            title: title,
            detail: tr("notifications.first_reminder"),
            accessoryView: firstField
        )
        let secondSwitch = DashboardSettingsComponents.makeSwitch(
            identifier: "global-second:\(resourceID)",
            isOn: thresholds.second > 0,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.globalSecondToggle(_:))
        )
        secondSwitch.setAccessibilityValue(kind.rawValue)
        secondSwitch.toolTip = kind == .balance ? "USD" : "%"
        let secondToggleRow = SettingsRowView(
            title: tr("notifications.second_alert"),
            detail: tr("notifications.second_alert_enabled"),
            accessoryView: secondSwitch
        )
        let secondField = makeGlobalRuleField(resourceID: resourceID, isSecond: true, value: thresholds.second, kind: kind)
        let secondRow = SettingsRowView(
            title: tr("notifications.second_threshold"),
            detail: thresholdDetail(thresholds.second, kind: kind, unit: kind == .balance ? "USD" : nil),
            accessoryView: secondField
        )
        globalSecondThresholdRows[resourceID] = secondRow
        globalSecondThresholdFields[resourceID] = secondField.field
        secondRow.isHidden = thresholds.second <= 0
        return [firstRow, secondToggleRow, secondRow]
    }

    private func defaultRuleSummary(
        _ thresholds: (first: Double, second: Double),
        kind: BalanceNotificationResourceKind
    ) -> String {
        let unit = kind == .quotaPercent ? "%" : " USD"
        let first = "\(formatted(thresholds.first, kind: kind))\(unit)"
        let firstSummary = thresholds.first > 0 ? first : tr("notifications.first_disabled")
        let second = thresholds.second > 0
            ? "\(formatted(thresholds.second, kind: kind))\(unit)"
            : tr("notifications.second_disabled")
        return tr("notifications.rule_summary", arguments: [firstSummary, second])
    }

    private func makeGlobalRuleField(
        resourceID: String,
        isSecond: Bool,
        value: Double,
        kind: BalanceNotificationResourceKind
    ) -> DashboardSettingsComponents.CompactNumericFieldAccessory {
        let identifier = "global-rule:\(resourceID):\(isSecond ? "second" : "first")"
        return DashboardSettingsComponents.makeNumericTextField(
            identifier: identifier,
            value: value > 0 ? formatted(value, kind: kind) : "",
            placeholder: kind == .quotaPercent ? "20" : "0.50",
            capacityTemplate: kind == .quotaPercent ? "000" : DashboardSettingsComponents.amountCapacityTemplate,
            delegate: relay,
            toolTip: tr("notifications.threshold_input_hint")
        )
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
        var sections: [NSView] = [providerSection]
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
            sections.append(SettingsSectionView(title: "", contentViews: [restoreRow]))
        }
        let header = DashboardSettingsComponents.makePageHeader(
            agent.title,
            subtitle: tr("notifications.agent_page_description")
        )
        return DashboardSettingsComponents.makeSettingsPageContent([header] + sections)
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
        providerID: String,
        enabled: Bool
    ) {
        let key = providerRowKey(agent, providerID: providerID)
        guard let row = providerRows[key] else { return }
        let settings = configuration.coordinator.settings
        row.updateDetail(
            providerUsesCustomRules(settings, agent: agent, providerID: providerID)
                ? tr("notifications.agent_customized")
                : tr("notifications.agent_follows_global")
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
            let providerIDs = self.configuration.providerChoices(agent).map(\.id)
            self.configuration.coordinator.performAsync { [weak self] in
                guard let self else { return }
                self.configuration.coordinator.applyGlobalRules(to: agent, providerIDs: providerIDs)
                DispatchQueue.main.async { [weak self] in
                    self?.rebuild()
                }
            }
        }
    }

    private func makeProviderPage(_ agent: BalanceNotificationAgent, providerID: String) -> NSView {
        let descriptors = configuration.coordinator.resourceDescriptors(agent: agent, providerID: providerID)
        let settings = configuration.coordinator.settings
        resourceRuleRows.removeAll(keepingCapacity: true)
        let providerName = configuration.providerChoices(agent).first { $0.id == providerID }?.name ?? providerID
        var content: [NSView] = []
        if descriptors.isEmpty {
            content.append(SettingsRowView(
                title: tr("notifications.resource_rules"),
                detail: tr("notifications.no_providers")
            ))
        } else {
            for descriptor in descriptors {
                content.append(contentsOf: makeResourceSettingsRows(descriptor, settings: settings))
            }
        }
        let section = SettingsSectionView(title: tr("notifications.resource_rules"), contentViews: content)
        for descriptor in descriptors {
            resourceRuleRows[descriptor.key]?.section = section
        }
        section.reconcileSeparators()
        let header = DashboardSettingsComponents.makePageHeader(providerName, subtitle: agent.title)
        return DashboardSettingsComponents.makeSettingsPageContent([header, section])
    }

    private func makeResourceSettingsRows(
        _ descriptor: BalanceNotificationResourceDescriptor,
        settings: BalanceNotificationSettings
    ) -> [NSView] {
        let storedRule = settings.rule(for: descriptor.key)
        let usesGlobalDefaults = storedRule?.usesGlobalDefaults ?? true
        var rule = usesGlobalDefaults
            ? settings.defaultRule(for: descriptor.key, kind: descriptor.kind, unit: descriptor.unit)
            : (storedRule ?? settings.defaultRule(for: descriptor.key, kind: descriptor.kind, unit: descriptor.unit))
        if let storedRule {
            rule.enabled = storedRule.enabled
        }
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
                : tr("notifications.balance_value", arguments: [
                    descriptor.title,
                    balanceText(descriptor.value ?? 0, unit: descriptor.unit)
                ]),
            accessoryView: enabled
        )
        let firstField = thresholdField(
            rule.firstThreshold,
            key: descriptor.key,
            kind: descriptor.kind,
            unit: descriptor.unit,
            isSecond: false,
            editable: !usesGlobalDefaults
        )
        let firstRow = SettingsRowView(
            title: tr("notifications.first_threshold"),
            detail: thresholdDetail(rule, descriptor: descriptor, second: false),
            accessoryView: firstField
        )
        let source = DashboardSettingsComponents.makePopUpButton(
            identifier: "source:\(descriptor.key.agent.rawValue):\(descriptor.key.providerID):\(descriptor.key.resourceID)",
            items: [
                DashboardSettingsComponents.PopUpItem(
                    title: tr("notifications.use_default_rules"),
                    representedObject: NSNumber(value: true)
                ),
                DashboardSettingsComponents.PopUpItem(
                    title: tr("notifications.custom_rules"),
                    representedObject: NSNumber(value: false)
                )
            ],
            selectedIndex: usesGlobalDefaults ? 0 : 1,
            target: relay,
            action: #selector(DashboardNotificationPageRelay.ruleSource(_:)),
            ignoresScrollWheel: true
        )
        source.toolTip = descriptor.unit ?? ""
        source.setAccessibilityValue(descriptor.kind.rawValue)
        let sourceRow = SettingsRowView(
            title: tr("notifications.rule_source"),
            detail: usesGlobalDefaults
                ? tr("notifications.inherited_rule_detail")
                : tr("notifications.custom_rule_detail"),
            accessoryView: source
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
        let secondField = thresholdField(
            rule.secondThreshold,
            key: descriptor.key,
            kind: descriptor.kind,
            unit: descriptor.unit,
            isSecond: true,
            editable: !usesGlobalDefaults
        )
        let secondThresholdRow = SettingsRowView(
            title: tr("notifications.second_threshold"),
            detail: thresholdDetail(rule, descriptor: descriptor, second: true),
            accessoryView: secondField
        )
        let resourceRows = ResourceRuleRows(
            enableRow: enableRow,
            sourceRow: sourceRow,
            firstThresholdRow: firstRow,
            secondToggleRow: secondRow,
            secondThresholdRow: secondThresholdRow,
            firstField: firstField,
            secondField: secondField,
            secondSwitch: secondSwitch
        )
        resourceRuleRows[descriptor.key] = resourceRows
        resourceRows.updateVisibility(
            resourceEnabled: rule.enabled,
            secondEnabled: rule.secondEnabled,
            usesGlobalDefaults: usesGlobalDefaults
        )
        return [enableRow, sourceRow, firstRow, secondRow, secondThresholdRow]
    }

    private func updateResourceVisibility(
        key: BalanceNotificationResourceKey,
        resourceEnabled: Bool
    ) {
        guard let resourceRows = resourceRuleRows[key] else { return }
        resourceRows.updateVisibility(resourceEnabled: resourceEnabled, secondEnabled: resourceRows.secondEnabled)
    }

    private func updateResourceInheritance(
        key: BalanceNotificationResourceKey,
        usesGlobalDefaults: Bool
    ) {
        guard let rows = resourceRuleRows[key] else { return }
        let descriptors = configuration.coordinator.resourceDescriptors(
            agent: key.agent,
            providerID: key.providerID
        )
        guard let descriptor = descriptors.first(where: { $0.key == key }) else { return }
        let settings = configuration.coordinator.settings
        let stored = settings.rule(for: key)
        var rule = usesGlobalDefaults
            ? settings.defaultRule(for: key, kind: descriptor.kind, unit: descriptor.unit)
            : (stored ?? settings.defaultRule(for: key, kind: descriptor.kind, unit: descriptor.unit))
        if let stored { rule.enabled = stored.enabled }
        rows.firstField.stringValue = rule.firstThreshold > 0
            ? formatted(rule.firstThreshold, kind: descriptor.kind)
            : ""
        rows.secondField.stringValue = rule.secondThreshold > 0
            ? formatted(rule.secondThreshold, kind: descriptor.kind)
            : ""
        rows.secondSwitch.state = rule.secondEnabled ? .on : .off
        rows.sourceRow.updateDetail(
            usesGlobalDefaults
                ? tr("notifications.inherited_rule_detail")
                : tr("notifications.custom_rule_detail")
        )
        rows.updateVisibility(
            resourceEnabled: rule.enabled,
            secondEnabled: rule.secondEnabled,
            usesGlobalDefaults: usesGlobalDefaults
        )
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
        isSecond: Bool,
        editable: Bool = true
    ) -> NSTextField {
        let field = NSTextField(string: value > 0 ? formatted(value, kind: kind) : "")
        field.toolTip = unit ?? ""
        field.setAccessibilityValue(kind.rawValue)
        field.identifier = NSUserInterfaceItemIdentifier(
            "resource:\(key.agent.rawValue):\(key.providerID):\(key.resourceID)|\(isSecond ? "second" : "first")"
        )
        field.alignment = .right
        field.isEditable = editable
        field.isEnabled = editable
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        field.target = editable ? relay : nil
        field.action = editable ? #selector(DashboardNotificationPageRelay.thresholdChanged(_:)) : nil
        return field
    }

    private func thresholdDetail(
        _ rule: BalanceNotificationResourceRule,
        descriptor: BalanceNotificationResourceDescriptor,
        second: Bool
    ) -> String {
        let value = second ? rule.secondThreshold : rule.firstThreshold
        if value <= 0 {
            return second ? tr("notifications.second_disabled") : tr("notifications.first_disabled")
        }
        return descriptor.kind == .quotaPercent
            ? "\(formatted(value, kind: .quotaPercent))%"
            : balanceText(value, unit: descriptor.unit)
    }

    private func thresholdDetail(
        _ value: Double,
        kind: BalanceNotificationResourceKind,
        unit: String?
    ) -> String {
        kind == .quotaPercent
            ? "\(formatted(value, kind: kind))%"
            : balanceText(value, unit: unit)
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
