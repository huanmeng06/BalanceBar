import AppKit

struct DashboardNotificationPageConfiguration {
    let coordinator: BalanceNotificationCoordinator
    let providerChoices: (BalanceNotificationAgent) -> [ProviderChoice]
}

private final class DashboardNotificationPageRelay: NSObject {
    var onGlobalToggle: ((Bool) -> Void)?
    var onAgentToggle: ((BalanceNotificationAgent, Bool) -> Void)?
    var onProviderToggle: ((BalanceNotificationAgent, String, Bool) -> Void)?
    var onResourceToggle: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool) -> Void)?
    var onThreshold: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool, Double) -> Void)?
    var onSecondThresholdToggle: ((BalanceNotificationResourceKey, BalanceNotificationResourceKind, String?, Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPauseSelection: ((String) -> Void)?
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
    @objc func resume(_ sender: NSButton) { onResume?() }
    @objc func back(_ sender: NSButton) { onBack?() }

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

    private enum NotificationPagePath: Equatable {
        case root
        case agent(BalanceNotificationAgent)
        case provider(BalanceNotificationAgent, String)
        case resource(BalanceNotificationResourceKey)
    }

    init(configuration: DashboardNotificationPageConfiguration) {
        self.configuration = configuration
        relay.onGlobalToggle = { [weak self] enabled in
            self?.configuration.coordinator.setGlobalEnabled(enabled)
            self?.refresh()
        }
        relay.onAgentToggle = { [weak self] agent, enabled in
            self?.configuration.coordinator.setAgentEnabled(enabled, agent: agent)
            self?.refresh()
        }
        relay.onProviderToggle = { [weak self] agent, providerID, enabled in
            self?.configuration.coordinator.setProviderEnabled(enabled, agent: agent, providerID: providerID)
            self?.refresh()
        }
        relay.onResourceToggle = { [weak self] key, kind, unit, enabled in
            self?.configuration.coordinator.setResourceEnabled(enabled, key: key, kind: kind, unit: unit)
            self?.refresh()
        }
        relay.onThreshold = { [weak self] key, kind, unit, isSecond, value in
            self?.configuration.coordinator.updateRule(key: key, kind: kind, unit: unit) { rule in
                if isSecond { rule.secondThreshold = BalanceNotificationResourceRule.normalizedSecondThreshold(value, firstThreshold: rule.firstThreshold, kind: kind) }
                else { rule.firstThreshold = BalanceNotificationResourceRule.normalizedFirstThreshold(value, kind: kind) }
            }
            self?.refresh()
        }
        relay.onSecondThresholdToggle = { [weak self] key, kind, unit, enabled in
            self?.configuration.coordinator.updateRule(key: key, kind: kind, unit: unit) { $0.secondEnabled = enabled }
            self?.refresh()
        }
        relay.onOpenSettings = { [weak self] in self?.configuration.coordinator.openSystemSettings() }
        relay.onPauseSelection = { [weak self] selection in
            guard let self else { return }
            switch selection {
            case "today":
                let calendar = Calendar.autoupdatingCurrent
                let start = calendar.startOfDay(for: Date())
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
                self.configuration.coordinator.pause(for: max(0, end.timeIntervalSinceNow))
            default:
                self.configuration.coordinator.pause(for: 3_600)
            }
            self.refresh()
        }
        relay.onResume = { [weak self] in self?.configuration.coordinator.resume(); self?.refresh() }
        relay.onBack = { [weak self] in self?.goBack() }
        relay.onAgent = { [weak self] agent in self?.path = [.agent(agent)]; self?.rebuild() }
        relay.onProvider = { [weak self] agent, providerID in self?.path = [.provider(agent, providerID)]; self?.rebuild() }
        relay.onResource = { [weak self] key in self?.path = [.resource(key)]; self?.rebuild() }
        container.translatesAutoresizingMaskIntoConstraints = false
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
        globalControls.append(globalSwitch)
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
        pauseMenu.addItem(withTitle: tr("notifications.pause_one_hour"))
        pauseMenu.item(at: 0)?.representedObject = "oneHour"
        pauseMenu.addItem(withTitle: tr("notifications.pause_today"))
        pauseMenu.item(at: 1)?.representedObject = "today"
        pauseMenu.target = relay
        pauseMenu.action = #selector(DashboardNotificationPageRelay.pauseSelection(_:))
        let resumeButton = NSButton(
            title: tr("notifications.resume"),
            target: relay,
            action: #selector(DashboardNotificationPageRelay.resume(_:))
        )
        let pauseControls = NSStackView(views: [pauseMenu, resumeButton])
        pauseControls.orientation = .horizontal
        pauseControls.spacing = 8
        let pauseDetail = tr("notifications.pause_duration")
        let notificationRows: [NSView] = [
            global,
            SettingsRowView(
                title: tr("notifications.pause_notifications"),
                detail: pauseDetail,
                accessoryView: pauseControls
            )
        ]
        return DashboardSettingsComponents.makeSettingsPageContent([
            SettingsSectionView(title: tr("notifications.page.title"), contentViews: notificationRows),
            makeAgentSettingsSection(settings: settings)
        ])
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
        cards.spacing = 10
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
        let detail = settings.isAgentEnabled(agent)
            ? tr("notifications.agent_enabled")
            : tr("notifications.agent_disabled")
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
        let rule = settings.rule(for: key) ?? BalanceNotificationResourceRule(key: key, kind: descriptor.kind, unit: descriptor.unit)
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
        let rule = settings.rule(for: descriptor.key) ?? BalanceNotificationResourceRule(key: descriptor.key, kind: descriptor.kind, unit: descriptor.unit)
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
