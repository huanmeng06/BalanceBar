import AppKit

struct DashboardProviderPageInput {
    let choices: [ProviderChoice]
    let selectedProviderID: String?
    let snapshot: Snapshot
    let quickSwitchSummaries: [String: String]
    let refreshDate: Date?
    let revision: UInt64
}

enum DashboardProviderListModel {
    static func filteredAndSorted(
        choices: [ProviderChoice],
        query: String,
        sortAlphabetically: Bool
    ) -> [ProviderChoice] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = choices.enumerated().filter { _, choice in
            normalizedQuery.isEmpty || choice.name.localizedCaseInsensitiveContains(normalizedQuery)
        }
        guard sortAlphabetically else { return filtered.map(\.element) }

        return filtered
            .sorted { lhs, rhs in
                let order = lhs.element.name.localizedCaseInsensitiveCompare(rhs.element.name)
                if order == .orderedSame {
                    return lhs.offset < rhs.offset
                }
                return order == .orderedAscending
            }
            .map(\.element)
    }
}

struct DashboardProviderSelectionState {
    private(set) var selectedProviderID: String?

    @discardableResult
    mutating func select(providerID: String, from choices: [ProviderChoice]) -> Bool {
        guard choices.contains(where: { $0.id == providerID }) else { return false }
        selectedProviderID = providerID
        return true
    }

    mutating func reconcile(with choices: [ProviderChoice]) {
        guard let selectedProviderID,
              choices.contains(where: { $0.id == selectedProviderID }) else {
            self.selectedProviderID = nil
            return
        }
    }
}

struct DashboardProviderRevisionGate {
    private(set) var latestRevision: UInt64?

    @discardableResult
    mutating func accepts(_ revision: UInt64) -> Bool {
        if let latestRevision, revision < latestRevision { return false }
        latestRevision = revision
        return true
    }
}

struct DashboardProviderPageActions {
    let onRefresh: () -> Void
    let onSwitchProvider: (String) -> Void
    let onOpenProvider: (String) -> Void
    let onSelectProvider: (String) -> Void
    let isSortAlphabetically: () -> Bool
    let setSortAlphabetically: (Bool) -> Void
}

final class DashboardProviderPageRelay: NSObject {
    var onRefresh: (() -> Void)?
    var onSwitchProvider: ((String) -> Void)?
    var onOpenProvider: ((String) -> Void)?
    var onSelectProvider: ((String) -> Void)?
    var onSearchChanged: (() -> Void)?
    var onSortChanged: (() -> Void)?

    @objc func refresh(_ sender: NSButton) {
        onRefresh?()
    }

    @objc func switchProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        onSwitchProvider?(providerID)
    }

    @objc func openProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        onOpenProvider?(providerID)
    }

    @objc func selectProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        onSelectProvider?(providerID)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        onSearchChanged?()
    }

    @objc func sortChanged(_ sender: NSButton) {
        onSortChanged?()
    }
}

/// Owns Provider-specific controls and rendering. Data services remain in
/// AppDelegate; this object only consumes immutable page inputs and callbacks.
final class DashboardProviderPages {
    private let actions: DashboardProviderPageActions
    private let relay = DashboardProviderPageRelay()

    private let providerLabel = NSTextField(labelWithString: tr("正在读取…", "Loading…"))
    private let amountLabel = NSTextField(labelWithString: "—")
    private let quotaLabel = NSTextField(labelWithString: tr("等待额度信息", "Waiting for quota data"))
    private let resetLabel = NSTextField(labelWithString: "")
    private let refreshLabel = NSTextField(labelWithString: "--:--:--")
    private let statusLabel = NSTextField(labelWithString: tr("正在连接 CC Switch", "Connecting to CC Switch"))
    private let currentProviderSubtitle = NSTextField(wrappingLabelWithString: "")
    private let providersStack = NSStackView()
    private let progressHost = NSView()
    private let providerSearch = NSSearchField()
    private let providerList = NSStackView()
    private let providerCountLabel = NSTextField(labelWithString: "")
    private let sortButton = NSButton(title: tr("排序", "Sort"), target: nil, action: nil)

    private var providerButtons: [String: NSButton] = [:]
    private var lastListInput: DashboardProviderPageInput?
    private var revisionGate = DashboardProviderRevisionGate()
    private var isTornDown = false

    init(actions: DashboardProviderPageActions) {
        self.actions = actions
        relay.onRefresh = actions.onRefresh
        relay.onSwitchProvider = actions.onSwitchProvider
        relay.onOpenProvider = actions.onOpenProvider
        relay.onSelectProvider = actions.onSelectProvider
        relay.onSearchChanged = { [weak self] in
            self?.refreshProviderListFromLastInput()
        }
        relay.onSortChanged = { [weak self] in
            guard let self, !self.isTornDown else { return }
            let nextValue = !self.actions.isSortAlphabetically()
            self.actions.setSortAlphabetically(nextValue)
            self.sortButton.contentTintColor = nextValue ? .controlAccentColor : .secondaryLabelColor
            self.refreshProviderListFromLastInput()
        }

        providerSearch.target = relay
        providerSearch.action = #selector(DashboardProviderPageRelay.searchChanged(_:))
        sortButton.target = relay
        sortButton.action = #selector(DashboardProviderPageRelay.sortChanged(_:))
        sortButton.bezelStyle = .texturedRounded
        sortButton.controlSize = .small
        sortButton.contentTintColor = actions.isSortAlphabetically()
            ? .controlAccentColor
            : .secondaryLabelColor
    }

    func makeProviderPage(
        choice: ProviderChoice,
        input: DashboardProviderPageInput
    ) -> NSView {
        guard !isTornDown else { return NSView() }

        providerLabel.stringValue = choice.name
        providerLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(labelWithString: choice.isCurrent
            ? tr("当前供应商", "Current Provider")
            : tr("可用供应商", "Available Provider"))
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = choice.isCurrent ? .systemGreen : .secondaryLabelColor
        let heading = NSStackView(views: [providerLabel, status])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        amountLabel.stringValue = choice.isCurrent
            ? input.snapshot.overviewLargeAmount
            : (input.quickSwitchSummaries[choice.id] ?? tr("正在读取…", "Loading…"))
        amountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        quotaLabel.stringValue = tr("剩余额度", "Remaining Balance")
        resetLabel.stringValue = choice.isCurrent
            ? input.snapshot.overviewReset(refreshDate: input.refreshDate, formatter: Self.timeFormatter)
            : tr("选择为当前供应商后显示详细重置时间", "Select this Provider to display detailed reset information")
        let usage = DashboardSettingsComponents.makeSettingsSection(tr("用量", "Usage"), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("剩余额度", "Remaining Balance"),
                subtitle: resetLabel.stringValue,
                control: amountLabel,
                minimumHeight: 76
            )
        ])

        let action: NSButton
        if choice.isCurrent {
            action = NSButton(
                title: tr("立即刷新", "Refresh Now"),
                target: relay,
                action: #selector(DashboardProviderPageRelay.refresh(_:))
            )
        } else {
            action = NSButton(
                title: tr("切换到此供应商", "Switch to This Provider"),
                target: relay,
                action: #selector(DashboardProviderPageRelay.switchProvider(_:))
            )
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
        }
        let connection = DashboardSettingsComponents.makeSettingsSection("CC Switch", rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr("同步状态", "Sync Status"),
                subtitle: choice.isCurrent
                    ? tr("正在跟随此供应商", "Following this Provider")
                    : tr("当前未使用此供应商", "This Provider is not currently active"),
                control: action
            )
        ])
        return DashboardSettingsComponents.makeSettingsPage([heading, usage, connection])
    }

    func makeOverviewPage(input: DashboardProviderPageInput) -> NSView {
        guard !isTornDown else { return NSView() }

        let root = NSView()
        let header = DashboardSettingsComponents.makePageHeader(
            tr("概览", "Overview"),
            subtitle: tr("当前余额、同步状态和 Codex 供应商", "Current balance, sync status, and Codex Provider")
        )
        providerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        providerLabel.lineBreakMode = .byTruncatingTail
        refreshLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        refreshLabel.textColor = .secondaryLabelColor
        refreshLabel.alignment = .right
        let providerRow = NSStackView(views: [providerLabel, NSView(), refreshLabel])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY
        quotaLabel.font = .systemFont(ofSize: 13, weight: .medium)
        resetLabel.font = .systemFont(ofSize: 13)
        resetLabel.textColor = .secondaryLabelColor
        let quotaStack = NSStackView(views: [quotaLabel, resetLabel])
        quotaStack.orientation = .vertical
        quotaStack.alignment = .leading
        quotaStack.spacing = 5
        amountLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        amountLabel.alignment = .right
        let quotaRow = NSStackView(views: [quotaStack, NSView(), amountLabel])
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .centerY
        progressHost.translatesAutoresizingMaskIntoConstraints = false
        progressHost.heightAnchor.constraint(equalToConstant: 6).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        let separator = NSBox()
        separator.boxType = .separator
        let providersTitle = NSTextField(labelWithString: tr("供应商", "Providers"))
        providersTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        providersStack.orientation = .vertical
        providersStack.alignment = .leading
        providersStack.spacing = 0
        let stack = NSStackView(views: [
            header, providerRow, quotaRow, progressHost, statusLabel,
            separator, providersTitle, providersStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(7, after: progressHost)
        stack.setCustomSpacing(18, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            providerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quotaRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            providersStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshOverview(input: input)
        return root
    }

    @discardableResult
    func refreshOverview(input: DashboardProviderPageInput) -> Bool {
        guard !isTornDown else { return false }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                _ = self?.refreshOverview(input: input)
            }
            return false
        }
        guard revisionGate.accepts(input.revision) else { return false }
        lastListInput = input

        if let currentName = input.choices.first(where: { $0.isCurrent })?.name {
            updateCurrentProvider(currentName)
        }
        if let selectedID = input.selectedProviderID,
           let choice = input.choices.first(where: { $0.id == selectedID }) {
            providerLabel.stringValue = choice.name
            if choice.isCurrent {
                amountLabel.stringValue = input.snapshot.overviewLargeAmount
                resetLabel.stringValue = input.snapshot.overviewReset(
                    refreshDate: input.refreshDate,
                    formatter: Self.timeFormatter
                )
            } else {
                amountLabel.stringValue = input.quickSwitchSummaries[selectedID]
                    ?? tr("正在读取…", "Loading…")
                resetLabel.stringValue = tr(
                    "选择为当前供应商后显示详细重置时间",
                    "Select this Provider to display detailed reset information"
                )
            }
        }
        refreshProviderList(input: input)
        refreshProviderRows(input: input)
        return true
    }

    func updateCurrentProvider(_ name: String) {
        guard !isTornDown else { return }
        currentProviderSubtitle.stringValue = tr(
            "当前供应商：\(name)",
            "Current Provider: \(name)"
        )
    }

    func refreshProviderList(input: DashboardProviderPageInput) {
        guard !isTornDown, Thread.isMainThread else { return }
        lastListInput = input
        for child in providerList.arrangedSubviews {
            providerList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        providerButtons.removeAll()

        let choices = DashboardProviderListModel.filteredAndSorted(
            choices: input.choices,
            query: providerSearch.stringValue,
            sortAlphabetically: actions.isSortAlphabetically()
        )
        providerCountLabel.stringValue = tr(
            "\(input.choices.count) 个",
            "\(input.choices.count)"
        )
        for choice in choices {
            let button = NSButton(
                title: choice.name,
                target: relay,
                action: #selector(DashboardProviderPageRelay.selectProvider(_:))
            )
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            let isSelected = input.selectedProviderID == choice.id
            button.isBordered = isSelected
            button.state = isSelected ? .on : .off
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            button.contentTintColor = isSelected
                ? .controlAccentColor
                : (choice.isCurrent ? .labelColor : .secondaryLabelColor)
            button.focusRingType = .none
            button.identifier = NSUserInterfaceItemIdentifier(choice.id)
            button.toolTip = choice.isCurrent
                ? tr("当前供应商", "Current Provider")
                : tr("查看 \(choice.name)", "View \(choice.name)")
            if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
               let image = NSImage(contentsOf: iconURL) {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                button.image = image
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 228).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            providerButtons[choice.id] = button
            providerList.addArrangedSubview(button)
        }
    }

    func refreshProviderRows(input: DashboardProviderPageInput) {
        guard !isTornDown, Thread.isMainThread else { return }
        for child in providersStack.arrangedSubviews {
            providersStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        guard !input.choices.isEmpty else {
            let empty = NSTextField(labelWithString: tr("未找到 Codex 供应商", "No Codex Provider Found"))
            empty.textColor = .secondaryLabelColor
            providersStack.addArrangedSubview(empty)
            return
        }

        for (index, choice) in input.choices.enumerated() {
            let name = NSTextField(labelWithString: choice.name)
            name.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingTail
            let summary = NSTextField(labelWithString: input.quickSwitchSummaries[choice.id] ?? tr("正在读取…", "Loading…"))
            summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.alignment = .right
            summary.translatesAutoresizingMaskIntoConstraints = false
            summary.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let action = NSButton(
                title: choice.isCurrent ? tr("当前", "Current") : tr("切换", "Switch"),
                target: relay,
                action: #selector(DashboardProviderPageRelay.switchProvider(_:))
            )
            action.bezelStyle = .roundRect
            action.controlSize = .small
            action.isEnabled = !choice.isCurrent
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
            action.translatesAutoresizingMaskIntoConstraints = false
            action.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let row = NSStackView(views: [name, NSView(), summary, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true
            providersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true

            if index < input.choices.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
                providersStack.addArrangedSubview(separator)
            }
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        [providerSearch, sortButton].forEach {
            $0.target = nil
            $0.action = nil
        }
        providerList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        providersStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        providerButtons.removeAll()
        lastListInput = nil
        relay.onRefresh = nil
        relay.onSwitchProvider = nil
        relay.onOpenProvider = nil
        relay.onSelectProvider = nil
        relay.onSearchChanged = nil
        relay.onSortChanged = nil
    }

    private func refreshProviderListFromLastInput() {
        guard let input = lastListInput else { return }
        refreshProviderList(input: input)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
