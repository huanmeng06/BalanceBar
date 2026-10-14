import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardProviderPagesTests: XCTestCase {
    private var previousLanguage = AppLanguage.system
    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguage.selected
        AppLanguage.selected = .english
    }
    override func tearDown() {
        AppLanguage.selected = previousLanguage
        super.tearDown()
    }

    func testSearchAndSortArePureAndStable() {
        let choices = [
            ProviderChoice(id: "zeta", name: "Zeta", isCurrent: false),
            ProviderChoice(id: "alpha-1", name: "Alpha", isCurrent: false),
            ProviderChoice(id: "alpha-2", name: "alpha", isCurrent: false),
            ProviderChoice(id: "relay", name: "Relay Service", isCurrent: true)
        ]

        XCTAssertEqual(
            DashboardProviderListModel.filteredAndSorted(
                choices: choices,
                query: " service ",
                sortAlphabetically: false
            ).map(\.id),
            ["relay"]
        )
        XCTAssertEqual(
            DashboardProviderListModel.filteredAndSorted(
                choices: choices,
                query: "",
                sortAlphabetically: true
            ).map(\.id),
            ["alpha-1", "alpha-2", "relay", "zeta"]
        )
    }

    func testAppDelegateWiringKeepsNativeSourceListResponsiveAfterPageReplacement() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-29-provider-pages.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let outline = try XCTUnwrap(
            descendants(of: window.contentView!, as: NSOutlineView.self).first
        )
        XCTAssertEqual(outline.style, .sourceList)
        for section in DashboardSection.allCases.dropFirst() {
            let row = try XCTUnwrap(
                (0..<outline.numberOfRows).first { row in
                    (outline.item(atRow: row) as? DashboardSidebarNode)?.section == section
                }
            )
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertEqual(window.title, section.title)
            XCTAssertEqual(
                (outline.item(atRow: outline.selectedRow) as? DashboardSidebarNode)?.section,
                section
            )
        }
    }

    func testSelectionRejectsMissingProviderAndRevisionRejectsStaleData() {
        let choices = [ProviderChoice(id: "current", name: "Current", isCurrent: true)]
        var selection = DashboardProviderSelectionState()
        XCTAssertTrue(selection.select(providerID: "current", from: choices))
        XCTAssertFalse(selection.select(providerID: "gone", from: choices))
        selection.reconcile(with: [])
        XCTAssertNil(selection.selectedProviderID)

        var revisions = DashboardProviderRevisionGate()
        XCTAssertTrue(revisions.accepts(3))
        XCTAssertFalse(revisions.accepts(2))
        XCTAssertTrue(revisions.accepts(4))
    }

    func testFreshDetailPagesRouteActionsAndDoNotShareControls() throws {
        var refreshCount = 0
        var switched: [String] = []
        let actions = DashboardProviderPageActions(
            onRefresh: { refreshCount += 1 },
            onSwitchProvider: { switched.append($0) },
            onOpenProvider: { _ in },
            onSelectProvider: { _ in },
            isSortAlphabetically: { false },
            setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let input = DashboardProviderPageInput(
            choices: choices,
            selectedProviderID: "current",
            snapshot: .placeholder,
            quickSwitchSummaries: [:],
            refreshDate: nil,
            revision: 1, snapshotProviderID: (choices as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )

        let first = coordinator.makeDetailPage(choice: choices[0], input: input)
        let second = coordinator.makeDetailPage(choice: choices[1], input: input)
        XCTAssertFalse(first === second)

        let switchButton = try XCTUnwrap(
            descendants(of: second, as: NSButton.self).first { $0.title.contains("切换") || $0.title.contains("Switch") }
        )
        switchButton.performClick(nil)
        XCTAssertEqual(switched, ["other"])
        XCTAssertEqual(refreshCount, 0)
    }

    func testRefreshOnlyUpdatesMountedPageAndTeardownClearsActions() throws {
        var refreshCount = 0
        let actions = DashboardProviderPageActions(
            onRefresh: { refreshCount += 1 },
            onSwitchProvider: { _ in },
            onOpenProvider: { _ in },
            onSelectProvider: { _ in },
            isSortAlphabetically: { false },
            setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let input = DashboardProviderPageInput(
            choices: [choice],
            selectedProviderID: choice.id,
            snapshot: .placeholder,
            quickSwitchSummaries: [:],
            refreshDate: nil,
            revision: 1, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        let page = coordinator.makeDetailPage(choice: choice, input: input)
        let refreshButton = try XCTUnwrap(
            descendants(of: page, as: NSButton.self).first { $0.title.contains("刷新") || $0.title.contains("Refresh") }
        )
        XCTAssertTrue(coordinator.refreshMountedPage(input: input))
        let newerInput = DashboardProviderPageInput(
            choices: [choice],
            selectedProviderID: choice.id,
            snapshot: .placeholder,
            quickSwitchSummaries: [:],
            refreshDate: nil,
            revision: 2, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        XCTAssertTrue(coordinator.refreshMountedPage(input: newerInput))
        XCTAssertFalse(coordinator.refreshMountedPage(input: input))
        refreshButton.performClick(nil)
        XCTAssertEqual(refreshCount, 1)

        coordinator.unmount()
        XCTAssertFalse(coordinator.refreshMountedPage(input: input))
        XCTAssertNil(refreshButton.target)
    }

    func testDetailResetSubtitleIsMountedAndUpdatesWithNewerRefresh() throws {
        let actions = DashboardProviderPageActions(
            onRefresh: {}, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in },
            isSortAlphabetically: { false }, setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let initial = DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 75, "7-day", "initial-reset", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 1, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        let page = coordinator.makeDetailPage(choice: choice, input: initial)
        XCTAssertTrue(try XCTUnwrap(descendants(of: page, as: NSTextField.self).first { $0.stringValue.contains("initial-reset") }).isHidden == false)

        let newer = DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 65, "7-day", "new-reset", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 2, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        XCTAssertTrue(coordinator.refreshMountedPage(input: newer))
        XCTAssertNotNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue.contains("new-reset") })
        XCTAssertNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue.contains("initial-reset") })
    }

    func testDetailDisappearanceClearsVisibleStateAndActions() throws {
        let actions = DashboardProviderPageActions(
            onRefresh: {}, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in },
            isSortAlphabetically: { false }, setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choice = ProviderChoice(id: "gone", name: "Gone Provider", isCurrent: true)
        let input = DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Gone Provider", 75, "7-day", "old-reset", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 1, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        let page = coordinator.makeDetailPage(choice: choice, input: input)
        let updated = DashboardProviderPageInput(
            choices: [], selectedProviderID: nil, snapshot: .placeholder,
            quickSwitchSummaries: [:], refreshDate: nil, revision: 2, snapshotProviderID: ([] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        XCTAssertTrue(coordinator.refreshMountedPage(input: updated))
        XCTAssertNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue == "Gone Provider" })
        XCTAssertNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue.contains("old-reset") })
        let action = try XCTUnwrap(descendants(of: page, as: NSButton.self).first)
        XCTAssertFalse(action.isEnabled)
        XCTAssertNil(action.target)
        XCTAssertTrue(action.title.contains("不可用") || action.title.contains("Unavailable"))
    }

    func testDetailCurrentTransitionUpdatesBadgeAndActionSemantics() throws {
        let actions = DashboardProviderPageActions(
            onRefresh: {}, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in },
            isSortAlphabetically: { false }, setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let other = ProviderChoice(id: "other", name: "Other", isCurrent: false)
        let initial = DashboardProviderPageInput(
            choices: [other], selectedProviderID: other.id, snapshot: .placeholder,
            quickSwitchSummaries: [other.id: "$1.00"], refreshDate: nil, revision: 1, snapshotProviderID: ([other] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        let page = coordinator.makeDetailPage(choice: other, input: initial)
        let initialAction = try XCTUnwrap(descendants(of: page, as: NSButton.self).first)
        XCTAssertTrue(initialAction.isEnabled)
        XCTAssertNotNil(initialAction.identifier)
        XCTAssertTrue(initialAction.title.contains("切换") || initialAction.title.contains("Switch"))

        let current = ProviderChoice(id: other.id, name: "Other", isCurrent: true)
        let updated = DashboardProviderPageInput(
            choices: [current], selectedProviderID: current.id,
            snapshot: .official("Other", 80, "7-day", "reset", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 2, snapshotProviderID: ([current] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )
        XCTAssertTrue(coordinator.refreshMountedPage(input: updated))
        XCTAssertTrue(initialAction.isEnabled)
        XCTAssertNil(initialAction.identifier)
        XCTAssertTrue(initialAction.title.contains("刷新") || initialAction.title.contains("Refresh"))
        XCTAssertNotNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue.contains("当前服务商") || $0.stringValue.contains("Current provider") })
    }

    func testOverviewDisappearanceClearsEveryCurrentField() throws {
        let actions = DashboardProviderPageActions(
            onRefresh: {}, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in },
            isSortAlphabetically: { false }, setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let page = coordinator.makeOverviewPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 90, "7-day", "overview-reset", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 1, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        ))
        XCTAssertTrue(coordinator.refreshMountedPage(input: DashboardProviderPageInput(
            choices: [], selectedProviderID: nil, snapshot: .placeholder,
            quickSwitchSummaries: [:], refreshDate: nil, revision: 2, snapshotProviderID: ([] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )))
        XCTAssertNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue == "Current" })
        XCTAssertNotNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue == "—" })
        XCTAssertNotNil(descendants(of: page, as: NSTextField.self).first { $0.stringValue.contains("Current provider unavailable") || $0.stringValue.contains("当前服务商不可用") })
    }

    func testOverviewHidesLunaReserveCardOnTheShippingUserFacingPath() throws {
        XCTAssertFalse(LunaReserveUserFacing.isEnabled)
        let actions = DashboardProviderPageActions(
            onRefresh: {}, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in },
            isSortAlphabetically: { false }, setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let reserve = LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m")
        let page = coordinator.makeOverviewPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 80, "5-hour", "1h0m", Date(), lunaReserve: reserve),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 1,
            currentProviderIsOfficial: true, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        ))
        let card = try XCTUnwrap(
            descendants(of: page, as: NSView.self).first {
                $0.identifier?.rawValue == "lunaReserveCard"
            }
        )
        XCTAssertTrue(card.isHidden)

        XCTAssertTrue(coordinator.refreshMountedPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 80, "5-hour", "1h0m", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 2,
            currentProviderIsOfficial: true, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )))
        XCTAssertTrue(card.isHidden)

        XCTAssertTrue(coordinator.refreshMountedPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .placeholder,
            quickSwitchSummaries: [:], refreshDate: nil, revision: 3,
            currentProviderIsOfficial: true, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )))
        XCTAssertTrue(card.isHidden)
    }

    func testOverviewShowsLunaReserveOnlyWhenOfficialDataContainsIt() throws {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
        let actions = DashboardProviderPageActions(
            onRefresh: {}, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in },
            isSortAlphabetically: { false }, setSortAlphabetically: { _ in }
        )
        let coordinator = DashboardProviderPageCoordinator(actions: actions)
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let reserve = LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m")
        let page = coordinator.makeOverviewPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 80, "5-hour", "1h0m", Date(), lunaReserve: reserve),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 1,
            currentProviderIsOfficial: true, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        ))
        let card = try XCTUnwrap(
            descendants(of: page, as: NSView.self).first {
                $0.identifier?.rawValue == "lunaReserveCard"
            }
        )
        XCTAssertFalse(card.isHidden)
        XCTAssertNotNil(descendants(of: card, as: NSTextField.self).first {
            $0.identifier?.rawValue == "lunaReserveRemaining"
                && $0.stringValue == reserve.remainingText
        })

        XCTAssertTrue(coordinator.refreshMountedPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .official("Current", 80, "5-hour", "1h0m", Date()),
            quickSwitchSummaries: [:], refreshDate: nil, revision: 2,
            currentProviderIsOfficial: true, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )))
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(
            descendants(of: card, as: NSTextField.self).first {
                $0.identifier?.rawValue == "lunaReserveStatus"
            }?.stringValue,
            tr(.keyLunaReserveStatusUnavailable)
        )

        XCTAssertTrue(coordinator.refreshMountedPage(input: DashboardProviderPageInput(
            choices: [choice], selectedProviderID: choice.id,
            snapshot: .placeholder,
            quickSwitchSummaries: [:], refreshDate: nil, revision: 3,
            currentProviderIsOfficial: true, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        )))
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(
            descendants(of: card, as: NSTextField.self).first {
                $0.identifier?.rawValue == "lunaReserveStatus"
            }?.stringValue,
            tr(.keyLunaReserveStatusLoading)
        )
    }

    func testDetailOrdinaryRowsUseNativeSettingsPrimitivesWithoutLegacyHeightEngine() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let coordinator = DashboardProviderPageCoordinator(actions: inactiveProviderActions())
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let page = coordinator.makeDetailPage(
            choice: choice,
            input: DashboardProviderPageInput(
                choices: [choice],
                selectedProviderID: choice.id,
                snapshot: .official("Current", 75, "7-day", "initial-reset", Date()),
                quickSwitchSummaries: [:],
                refreshDate: nil,
                revision: 1, snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
            )
        )

        let amount = try XCTUnwrap(
            descendants(of: page, as: NSTextField.self).first { $0.font?.pointSize == 34 }
        )
        let usageRow = try XCTUnwrap(SettingsRowView.enclosing(amount))
        XCTAssertEqual(usageRow.titleLabel.stringValue, tr(.keyDashboardProviderPagesRemainingBalance))
        XCTAssertTrue(usageRow.detailLabel.stringValue.contains("initial-reset"))
        XCTAssertIdentical(usageRow.accessoryView, amount)
        let usageSection = try XCTUnwrap(SettingsSectionView.enclosing(amount))
        XCTAssertEqual(usageSection.headingLabel.stringValue, tr(.keyDashboardProviderPagesUsage))
        XCTAssertEqual(usageSection.contentViews.count, 1)

        let action = try XCTUnwrap(descendants(of: page, as: NSButton.self).first)
        let connectionRow = try XCTUnwrap(SettingsRowView.enclosing(action))
        XCTAssertEqual(connectionRow.titleLabel.stringValue, tr(.keyDashboardProviderPagesSyncStatus))
        XCTAssertEqual(
            connectionRow.detailLabel.stringValue,
            tr(.keyDashboardProviderPagesFollowingThisProvider)
        )
        XCTAssertIdentical(connectionRow.accessoryView, action)
        let connectionSection = try XCTUnwrap(SettingsSectionView.enclosing(action))
        XCTAssertEqual(
            connectionSection.headingLabel.stringValue,
            tr(.keyDashboardProviderPagesCcSwitch)
        )
        XCTAssertEqual(connectionSection.contentViews.count, 1)

        let providerName = try XCTUnwrap(
            descendants(of: page, as: NSTextField.self).first { $0.stringValue == "Current" }
        )
        XCTAssertNil(SettingsRowView.enclosing(providerName))
        XCTAssertNil(SettingsSectionView.enclosing(providerName))

        DashboardSettingsLayoutMetrics.reset()
        let window = makeTestWindow(width: 880)
        let host = pinningHost(for: page, in: window, width: 880)
        defer { window.orderOut(nil) }
        XCTAssertGreaterThanOrEqual(usageRow.frame.height, SettingsRowView.minimumHeight)
        XCTAssertGreaterThanOrEqual(connectionRow.frame.height, SettingsRowView.minimumHeight)
        XCTAssertEqual(usageSection.cardView.frame.height, usageRow.frame.height, accuracy: 0.5)
        XCTAssertEqual(connectionSection.cardView.frame.height, connectionRow.frame.height, accuracy: 0.5)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.textLineMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.controlFittingMeasurements, 0)

        pin(page, to: host, window: window, width: 516)
        XCTAssertGreaterThanOrEqual(usageRow.frame.height, SettingsRowView.minimumHeight)
        XCTAssertGreaterThanOrEqual(connectionRow.frame.height, SettingsRowView.minimumHeight)
        XCTAssertEqual(usageRow.frame.width, usageSection.cardView.frame.width, accuracy: 0.5)
        XCTAssertEqual(connectionRow.frame.width, connectionSection.cardView.frame.width, accuracy: 0.5)
        XCTAssertGreaterThan(usageRow.detailLabel.preferredMaxLayoutWidth, 1)
        XCTAssertGreaterThan(connectionRow.detailLabel.preferredMaxLayoutWidth, 1)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.cardHeightMeasurements, 0)
        XCTAssertEqual(DashboardSettingsLayoutMetrics.preferredHeightMeasurements, 0)
    }

    func testOverviewCustomProviderListDoesNotUseNativeSettingsRows() throws {
        let coordinator = DashboardProviderPageCoordinator(actions: inactiveProviderActions())
        let current = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        let other = ProviderChoice(id: "other", name: "Other", isCurrent: false)
        let page = coordinator.makeOverviewPage(input: DashboardProviderPageInput(
            choices: [current, other],
            selectedProviderID: current.id,
            snapshot: .official("Current", 90, "7-day", "overview-reset", Date()),
            quickSwitchSummaries: [other.id: "$1.00"],
            refreshDate: nil,
            revision: 1, snapshotProviderID: ([current, other] as [ProviderChoice]).first(where: { $0.isCurrent })?.id
        ))
        let switchButton = try XCTUnwrap(
            descendants(of: page, as: NSButton.self).first {
                $0.title.contains("切换") || $0.title.contains("Switch")
            }
        )
        XCTAssertNil(SettingsRowView.enclosing(switchButton))
        XCTAssertNil(SettingsSectionView.enclosing(switchButton))
        XCTAssertTrue(descendants(of: page, as: SettingsRowView.self).isEmpty)
        XCTAssertTrue(descendants(of: page, as: SettingsSectionView.self).isEmpty)
    }
}

private func inactiveProviderActions() -> DashboardProviderPageActions {
    DashboardProviderPageActions(
        onRefresh: {},
        onSwitchProvider: { _ in },
        onOpenProvider: { _ in },
        onSelectProvider: { _ in },
        isSortAlphabetically: { false },
        setSortAlphabetically: { _ in }
    )
}

private func makeTestWindow(width: CGFloat) -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
}

private func pinningHost(for page: NSView, in window: NSWindow, width: CGFloat) -> NSView {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 720))
    window.contentView = host
    host.addSubview(page)
    pin(page, to: host, window: window, width: width)
    return host
}

private func pin(_ page: NSView, to host: NSView, window: NSWindow, width: CGFloat) {
    window.setContentSize(NSSize(width: width, height: 720))
    host.setFrameSize(NSSize(width: width, height: 720))
    page.translatesAutoresizingMaskIntoConstraints = false
    page.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    host.removeConstraints(host.constraints)
    NSLayoutConstraint.activate([
        page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        page.topAnchor.constraint(equalTo: host.topAnchor)
    ])
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    page.layoutSubtreeIfNeeded()
    window.layoutIfNeeded()
    page.layoutSubtreeIfNeeded()
}

private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    root.subviews.flatMap { child in
        ([child].compactMap { $0 as? T }) + descendants(of: child, as: type)
    }
}


extension DashboardProviderPagesTests {
    func testMountedProviderReformatsTimestampWithoutRequestingRefresh() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T23:30:00Z"))
        let snapshot = Snapshot.balance("Current", 10, "USD", nil, date)
        let choice = ProviderChoice(id: "current", name: "Current", isCurrent: true)
        var requests = 0
        let coordinator = DashboardProviderPageCoordinator(actions: .init(onRefresh: { requests += 1 }, onSwitchProvider: { _ in }, onOpenProvider: { _ in }, onSelectProvider: { _ in }, isSortAlphabetically: { false }, setSortAlphabetically: { _ in }))
        let input: (Int, UInt64) -> DashboardProviderPageInput = { minutes, revision in
            .init(choices: [choice], selectedProviderID: choice.id, snapshot: snapshot, quickSwitchSummaries: [:], refreshDate: date, revision: revision, displayTimeZone: AppTimeZoneSelection.fixedOffset(minutes: minutes).resolved(), snapshotProviderID: ([choice] as [ProviderChoice]).first(where: { $0.isCurrent })?.id)
        }
        let page = coordinator.makeDetailPage(choice: choice, input: input(0, 1))
        XCTAssertTrue(descendants(of: page, as: NSTextField.self).contains { $0.stringValue.contains("23:30:00") })
        _ = coordinator.refreshMountedPage(input: input(345, 2))
        XCTAssertTrue(descendants(of: page, as: NSTextField.self).contains { $0.stringValue.contains("05:15:00") })
        XCTAssertFalse(descendants(of: page, as: NSTextField.self).contains { $0.stringValue.contains("23:30:00") })
        XCTAssertEqual(requests, 0)
    }
}

extension DashboardProviderPagesTests {
    func testAggregationDefaultCannotPopulateSameNamedDirectProviderDetailOrOverview() throws {
        let direct = ProviderChoice(id: "direct", name: "tokenshop", isCurrent: true)
        let route = ProviderChoice(id: "route", name: "tokenshop", isCurrent: false)
        let balance = Snapshot.balance("tokenshop", 2.67, "CNY", nil, Date(timeIntervalSince1970: 100), progressPercentage: nil)
        let official = Snapshot.official("tokenshop", 94, "5h", nil, Date(timeIntervalSince1970: 200))
        let input = DashboardProviderPageInput(choices: [direct, route], selectedProviderID: direct.id,
            snapshot: official, quickSwitchSummaries: [:], refreshDate: official.date, revision: 1,
            snapshotProviderID: route.id, aggregatedSnapshots: [direct.id: balance, route.id: official], isAggregationMode: true)
        XCTAssertEqual(input.snapshot(for: direct.id), balance)
        XCTAssertEqual(input.snapshot(for: route.id), official)
        XCTAssertEqual(input.refreshDate(for: direct.id), balance.date)
        let coordinator = DashboardProviderPageCoordinator(actions: .init(onRefresh: {}, onSwitchProvider: { _ in },
            onOpenProvider: { _ in }, onSelectProvider: { _ in }, isSortAlphabetically: { false }, setSortAlphabetically: { _ in }))
        defer { coordinator.teardown() }
        let detail = coordinator.makeDetailPage(choice: direct, input: input)
        let labels = descendants(of: detail, as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains(balance.overviewLargeAmount))
        XCTAssertFalse(labels.contains(official.overviewLargeAmount))
        let overview = coordinator.makeOverviewPage(input: input)
        let overviewLabels = descendants(of: overview, as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(overviewLabels.contains(balance.overviewLargeAmount))
        XCTAssertFalse(overviewLabels.contains(official.overviewLargeAmount))
    }

    func testAggregationMissingProviderAndUnknownNormalOwnershipNeverBorrowGlobalQuota() {
        let input = DashboardProviderPageInput(choices: [ProviderChoice(id: "direct", name: "same", isCurrent: true)],
            selectedProviderID: nil, snapshot: .official("same", 94, "5h", nil, Date()),
            quickSwitchSummaries: ["direct": "$2.67"], refreshDate: Date(), revision: 1,
            snapshotProviderID: "route", aggregatedSnapshots: [:], isAggregationMode: true)
        XCTAssertNil(input.snapshot(for: "direct"))
        XCTAssertNil(input.refreshDate(for: "direct"))
        let normal = DashboardProviderPageInput(choices: input.choices, selectedProviderID: nil, snapshot: input.snapshot,
            quickSwitchSummaries: [:], refreshDate: Date(), revision: 2)
        XCTAssertNil(normal.snapshot(for: "direct"))
    }
}
