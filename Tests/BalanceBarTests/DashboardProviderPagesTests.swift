import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardProviderPagesTests: XCTestCase {
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

    func testAppDelegateWiringKeepsRealSidebarButtonsResponsiveAfterPageReplacement() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-29-provider-pages.db"))
        )
        defer { appDelegate.teardownDashboardForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        for section in DashboardSection.allCases.dropFirst() {
            let button = try XCTUnwrap(
                descendants(of: window.contentView!, as: NSButton.self).first { $0.tag == section.rawValue }
            )
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil)
            XCTAssertEqual(window.title, section.title)
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
            revision: 1
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
            revision: 1
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
            revision: 2
        )
        XCTAssertTrue(coordinator.refreshMountedPage(input: newerInput))
        XCTAssertFalse(coordinator.refreshMountedPage(input: input))
        refreshButton.performClick(nil)
        XCTAssertEqual(refreshCount, 1)

        coordinator.unmount()
        XCTAssertFalse(coordinator.refreshMountedPage(input: input))
        XCTAssertNil(refreshButton.target)
    }
}

private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    root.subviews.flatMap { child in
        ([child].compactMap { $0 as? T }) + descendants(of: child, as: type)
    }
}
