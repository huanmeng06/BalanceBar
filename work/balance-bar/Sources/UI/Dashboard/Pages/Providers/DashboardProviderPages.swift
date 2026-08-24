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
    private let statusLabel: NSTextField
    private let syncSubtitleLabel: NSTextField
    private let actionButton: NSButton
    private let relay: DashboardProviderPageRelay
    private let root: NSView

    init(choice: ProviderChoice, input: DashboardProviderPageInput, actions: DashboardProviderPageActions) {
        choiceID = choice.id
        providerLabel = NSTextField(labelWithString: choice.name)
        amountLabel = NSTextField(labelWithString: "—")
        resetLabel = NSTextField(labelWithString: "")
        statusLabel = NSTextField(labelWithString: "")
        syncSubtitleLabel = NSTextField(wrappingLabelWithString: "")
        actionButton = NSButton()
        relay = DashboardProviderPageRelay()

        providerLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let heading = NSStackView(views: [providerLabel, statusLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        amountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        resetLabel.stringValue = choice.isCurrent
            ? choice.initialResetText(input: input, formatter: Self.timeFormatter)
            : tr(.keyDashboardProviderPagesSelectThisProviderToDisplayDetailedResetInformation)
        let usage = DashboardSettingsComponents.makeSettingsSection(tr(.keyDashboardProviderPagesUsage), rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardProviderPagesRemainingBalance),
                subtitle: resetLabel.stringValue,
                subtitleLabel: resetLabel,
                control: amountLabel,
                minimumHeight: 76
            )
        ])

        actionButton.bezelStyle = .roundRect
        let connection = DashboardSettingsComponents.makeSettingsSection("CC Switch", rows: [
            DashboardSettingsComponents.makeSettingsRow(
                tr(.keyDashboardProviderPagesSyncStatus),
                subtitle: "",
                subtitleLabel: syncSubtitleLabel,
                control: actionButton
            )
        ])
        root = DashboardSettingsComponents.makeSettingsPage([heading, usage, connection])

        relay.onRefresh = actions.onRefresh
        relay.onSwitchProvider = actions.onSwitchProvider
        relay.onOpenProvider = actions.onOpenProvider
        relay.onSelectProvider = actions.onSelectProvider
        updateActionState(for: choice)
        refresh(input: input)
    }

    var view: NSView { root }

    func refresh(input: DashboardProviderPageInput) -> Bool {
        guard let choice = input.choices.first(where: { $0.id == choiceID }) else {
            providerLabel.stringValue = tr(.keyDashboardProviderPagesProviderUnavailable)
            amountLabel.stringValue = "—"
            resetLabel.stringValue = tr(.keyDashboardProviderPagesThisProviderIsNoLongerAvailable)
            updateActionState(for: nil)
            return true
        }
        providerLabel.stringValue = choice.name
        amountLabel.stringValue = choice.isCurrent
            ? input.snapshot.overviewLargeAmount
            : (input.quickSwitchSummaries[choice.id] ?? tr(.keyDashboardProviderPagesLoading))
        resetLabel.stringValue = choice.isCurrent
            ? input.snapshot.overviewReset(refreshDate: input.refreshDate, formatter: Self.timeFormatter)
            : tr(.keyDashboardProviderPagesSelectThisProviderToDisplayDetailedResetInformation2)
        updateActionState(for: choice)
        return true
    }

    private func updateActionState(for choice: ProviderChoice?) {
        guard let choice else {
            statusLabel.stringValue = tr(.keyDashboardProviderPagesProviderUnavailable2)
            statusLabel.textColor = .secondaryLabelColor
            syncSubtitleLabel.stringValue = tr(.keyDashboardProviderPagesThisProviderDisappearedFromCcSwitch)
            actionButton.title = tr(.keyDashboardProviderPagesUnavailable)
            actionButton.isEnabled = false
            actionButton.target = nil
            actionButton.action = nil
            actionButton.identifier = nil
            return
        }
        statusLabel.stringValue = choice.isCurrent
            ? tr(.keyDashboardProviderPagesCurrentProvider)
            : tr(.keyDashboardProviderPagesAvailableProvider)
        statusLabel.textColor = choice.isCurrent ? .systemGreen : .secondaryLabelColor
        syncSubtitleLabel.stringValue = choice.isCurrent
            ? tr(.keyDashboardProviderPagesFollowingThisProvider)
            : tr(.keyDashboardProviderPagesThisProviderIsNotCurrentlyActive)
        actionButton.target = relay
        actionButton.isEnabled = true
        if choice.isCurrent {
            actionButton.title = tr(.keyDashboardProviderPagesRefreshNow)
            actionButton.action = #selector(DashboardProviderPageRelay.refresh(_:))
            actionButton.identifier = nil
            actionButton.toolTip = nil
        } else {
            actionButton.title = tr(.keyDashboardProviderPagesSwitchToThisProvider)
            actionButton.action = #selector(DashboardProviderPageRelay.switchProvider(_:))
            actionButton.identifier = NSUserInterfaceItemIdentifier(choice.id)
            actionButton.toolTip = choice.name
        }
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

private extension ProviderChoice {
    func initialResetText(input: DashboardProviderPageInput, formatter: DateFormatter) -> String {
        input.snapshot.overviewReset(refreshDate: input.refreshDate, formatter: formatter)
    }
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

    private let providerLabel = NSTextField(labelWithString: tr(.keyDashboardProviderPagesLoading2))
    private let amountLabel = NSTextField(labelWithString: "—")
    private let quotaLabel = NSTextField(labelWithString: tr(.keyDashboardProviderPagesWaitingForQuotaData))
    private let resetLabel = NSTextField(labelWithString: "")
    private let refreshLabel = NSTextField(labelWithString: "--:--:--")
    private let statusLabel = NSTextField(labelWithString: tr(.keyDashboardProviderPagesConnectingToCcSwitch))
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
            tr(.keyDashboardProviderPagesOverview),
            subtitle: tr(.keyDashboardProviderPagesCurrentBalanceSyncStatusAndCodexProvider)
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
        let providersTitle = NSTextField(labelWithString: tr(.keyDashboardProviderPagesProviders))
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
        guard let current = choices.first(where: { $0.isCurrent }) else {
            providerLabel.stringValue = tr(.keyDashboardProviderPagesNoCodexProviderFound)
            amountLabel.stringValue = "—"
            resetLabel.stringValue = tr(.keyDashboardProviderPagesCurrentProviderUnavailable)
            refreshLabel.stringValue = "--:--:--"
            statusLabel.stringValue = tr(.keyDashboardProviderPagesWaitingForProvider)
            refreshRows()
            return true
        }
        providerLabel.stringValue = current.name
        amountLabel.stringValue = input.snapshot.overviewLargeAmount
        resetLabel.stringValue = input.snapshot.overviewReset(refreshDate: input.refreshDate, formatter: Self.timeFormatter)
        refreshLabel.stringValue = input.refreshDate.map(Self.timeFormatter.string(from:)) ?? "--:--:--"
        statusLabel.stringValue = tr(.keyDashboardProviderPagesFollowingCurrentProvider)
        refreshRows()
        return true
    }

    private func refreshRows() {
        providersStack.arrangedSubviews.forEach {
            providersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !choices.isEmpty else {
            let empty = NSTextField(labelWithString: tr(.keyDashboardProviderPagesNoCodexProviderFound2))
            empty.textColor = .secondaryLabelColor
            providersStack.addArrangedSubview(empty)
            return
        }
        for (index, choice) in choices.enumerated() {
            let name = NSTextField(labelWithString: choice.name)
            name.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingTail
            let summary = NSTextField(labelWithString: quickSwitchSummaries[choice.id] ?? tr(.keyDashboardProviderPagesLoading3))
            summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.alignment = .right
            summary.translatesAutoresizingMaskIntoConstraints = false
            summary.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let action = NSButton(
                title: choice.isCurrent ? tr(.keyDashboardProviderPagesCurrent) : tr(.keyDashboardProviderPagesSwitch),
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
            providersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
            if index < choices.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                providersStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
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
    private var revisionGate = DashboardProviderRevisionGate()
    private var isTornDown = false

    init(actions: DashboardProviderPageActions) {
        self.actions = actions
    }

    func makeDetailPage(choice: ProviderChoice, input: DashboardProviderPageInput) -> NSView {
        guard !isTornDown else { return NSView() }
        unmount()
        let page = DashboardProviderDetailPage(choice: choice, input: input, actions: actions)
        revisionGate = DashboardProviderRevisionGate()
        return mount(page)
    }

    func makeOverviewPage(input: DashboardProviderPageInput) -> NSView {
        guard !isTornDown else { return NSView() }
        unmount()
        let page = DashboardProviderOverviewPage(input: input, actions: actions)
        revisionGate = DashboardProviderRevisionGate()
        return mount(page)
    }

    @discardableResult
    func refreshMountedPage(input: DashboardProviderPageInput) -> Bool {
        guard !isTornDown,
              let page = mountedPage,
              mountedMount == page.mount else { return false }
        guard revisionGate.accepts(input.revision) else { return false }
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
