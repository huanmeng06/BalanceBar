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
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
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

struct DashboardProviderPageMount: Equatable {
    let rawValue: UUID
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

    @objc func refresh(_ sender: NSButton) { onRefresh?() }

    @objc func switchProvider(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSwitchProvider?(id)
    }

    @objc func openProvider(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onOpenProvider?(id)
    }

    @objc func selectProvider(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSelectProvider?(id)
    }

    @objc func searchChanged(_ sender: NSSearchField) { onSearchChanged?() }
    @objc func sortChanged(_ sender: NSButton) { onSortChanged?() }

    func teardown() {
        onRefresh = nil
        onSwitchProvider = nil
        onOpenProvider = nil
        onSelectProvider = nil
        onSearchChanged = nil
        onSortChanged = nil
    }
}

private protocol DashboardProviderMountedPage: AnyObject {
    var mount: DashboardProviderPageMount { get }
    func refresh(input: DashboardProviderPageInput) -> Bool
    func teardown()
}

private final class DashboardProviderPageHost: NSView {
    let page: DashboardProviderMountedPage

    init(page: DashboardProviderMountedPage) {
        self.page = page
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }
}

private final class DashboardProviderDetailPage: DashboardProviderMountedPage {
    let mount = DashboardProviderPageMount(rawValue: UUID())

    private let choiceID: String
    private let providerLabel: NSTextField
    private let amountLabel: NSTextField
    private let resetLabel: NSTextField
    private let relay: DashboardProviderPageRelay
    private let root: NSView

    init(choice: ProviderChoice, input: DashboardProviderPageInput, actions: DashboardProviderPageActions) {
        choiceID = choice.id
        providerLabel = NSTextField(labelWithString: choice.name)
        amountLabel = NSTextField(labelWithString: "—")
        resetLabel = NSTextField(labelWithString: "")
        relay = DashboardProviderPageRelay()

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

        amountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
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
        root = DashboardSettingsComponents.makeSettingsPage([heading, usage, connection])

        relay.onRefresh = actions.onRefresh
        relay.onSwitchProvider = actions.onSwitchProvider
        relay.onOpenProvider = actions.onOpenProvider
        relay.onSelectProvider = actions.onSelectProvider
        refresh(input: input)
    }

    var view: NSView { root }

    func refresh(input: DashboardProviderPageInput) -> Bool {
        guard let choice = input.choices.first(where: { $0.id == choiceID }) else { return false }
        providerLabel.stringValue = choice.name
        amountLabel.stringValue = choice.isCurrent
            ? input.snapshot.overviewLargeAmount
            : (input.quickSwitchSummaries[choice.id] ?? tr("正在读取…", "Loading…"))
        resetLabel.stringValue = choice.isCurrent
            ? input.snapshot.overviewReset(refreshDate: input.refreshDate, formatter: Self.timeFormatter)
            : tr("选择为当前供应商后显示详细重置时间", "Select this Provider to display detailed reset information")
        return true
    }

    func teardown() {
        relay.teardown()
        clearDashboardProviderControlTargets(in: root)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private func clearDashboardProviderControlTargets(in view: NSView) {
    if let control = view as? NSControl {
        control.target = nil
        control.action = nil
    }
    view.subviews.forEach { clearDashboardProviderControlTargets(in: $0) }
}

private final class DashboardProviderOverviewPage: DashboardProviderMountedPage {
    let mount = DashboardProviderPageMount(rawValue: UUID())

    private let providerLabel = NSTextField(labelWithString: tr("正在读取…", "Loading…"))
    private let amountLabel = NSTextField(labelWithString: "—")
    private let quotaLabel = NSTextField(labelWithString: tr("等待额度信息", "Waiting for quota data"))
    private let resetLabel = NSTextField(labelWithString: "")
    private let refreshLabel = NSTextField(labelWithString: "--:--:--")
    private let statusLabel = NSTextField(labelWithString: tr("正在连接 CC Switch", "Connecting to CC Switch"))
    private let progressHost = NSView()
    private let providersStack = NSStackView()
    private let relay: DashboardProviderPageRelay
    private let root: NSView
    private var choices: [ProviderChoice]
    private var quickSwitchSummaries: [String: String]

    init(input: DashboardProviderPageInput, actions: DashboardProviderPageActions) {
        relay = DashboardProviderPageRelay()
        choices = input.choices
        quickSwitchSummaries = input.quickSwitchSummaries
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
        root = NSView()
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
        relay.onRefresh = actions.onRefresh
        relay.onSwitchProvider = actions.onSwitchProvider
        relay.onOpenProvider = actions.onOpenProvider
        relay.onSelectProvider = actions.onSelectProvider
        refresh(input: input)
    }

    var view: NSView { root }

    func refresh(input: DashboardProviderPageInput) -> Bool {
        choices = input.choices
        quickSwitchSummaries = input.quickSwitchSummaries
        if let current = choices.first(where: { $0.isCurrent }) {
            providerLabel.stringValue = current.name
            amountLabel.stringValue = input.snapshot.overviewLargeAmount
            resetLabel.stringValue = input.snapshot.overviewReset(refreshDate: input.refreshDate, formatter: Self.timeFormatter)
            refreshLabel.stringValue = input.refreshDate.map(Self.timeFormatter.string(from:)) ?? "--:--:--"
        }
        refreshRows()
        return true
    }

    private func refreshRows() {
        providersStack.arrangedSubviews.forEach {
            providersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !choices.isEmpty else {
            let empty = NSTextField(labelWithString: tr("未找到 Codex 供应商", "No Codex Provider Found"))
            empty.textColor = .secondaryLabelColor
            providersStack.addArrangedSubview(empty)
            return
        }
        for (index, choice) in choices.enumerated() {
            let name = NSTextField(labelWithString: choice.name)
            name.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingTail
            let summary = NSTextField(labelWithString: quickSwitchSummaries[choice.id] ?? tr("正在读取…", "Loading…"))
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
            action.translatesAutoresizingMaskIntoConstraints = false
            action.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let row = NSStackView(views: [name, NSView(), summary, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true
            row.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
            providersStack.addArrangedSubview(row)
            if index < choices.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
                providersStack.addArrangedSubview(separator)
            }
        }
    }

    func teardown() {
        relay.teardown()
        clearDashboardProviderControlTargets(in: root)
        providersStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Retains only pure coordinator state and a weak mounted page. Every page
/// construction creates a fresh page object and fresh AppKit controls.
final class DashboardProviderPageCoordinator {
    private let actions: DashboardProviderPageActions
    private weak var mountedPage: DashboardProviderMountedPage?
    private var mountedMount: DashboardProviderPageMount?
    private var isTornDown = false

    init(actions: DashboardProviderPageActions) {
        self.actions = actions
    }

    func makeDetailPage(choice: ProviderChoice, input: DashboardProviderPageInput) -> NSView {
        guard !isTornDown else { return NSView() }
        unmount()
        let page = DashboardProviderDetailPage(choice: choice, input: input, actions: actions)
        return mount(page)
    }

    func makeOverviewPage(input: DashboardProviderPageInput) -> NSView {
        guard !isTornDown else { return NSView() }
        unmount()
        let page = DashboardProviderOverviewPage(input: input, actions: actions)
        return mount(page)
    }

    @discardableResult
    func refreshMountedPage(input: DashboardProviderPageInput) -> Bool {
        guard !isTornDown,
              let page = mountedPage,
              mountedMount == page.mount else { return false }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                _ = self?.refreshMountedPage(input: input)
            }
            return false
        }
        return mountedPage?.refresh(input: input) ?? false
    }

    func unmount() {
        mountedPage?.teardown()
        mountedPage = nil
        mountedMount = nil
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        unmount()
    }

    private func mount(_ page: DashboardProviderMountedPage) -> NSView {
        mountedPage = page
        mountedMount = page.mount
        if let page = page as? DashboardProviderDetailPage {
            return DashboardProviderPageHost(page: page, content: page.view)
        }
        if let page = page as? DashboardProviderOverviewPage {
            return DashboardProviderPageHost(page: page, content: page.view)
        }
        return NSView()
    }
}

private extension DashboardProviderPageHost {
    convenience init(page: DashboardProviderMountedPage, content: NSView) {
        self.init(page: page)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
