import AppKit
import XCTest
@testable import BalanceBar

final class DashboardProviderPagesTests: XCTestCase {
    func testSearchMatchesNamesAndSortPreservesStableTies() {
        let choices = [
            ProviderChoice(id: "zeta", name: "Zeta", isCurrent: false),
            ProviderChoice(id: "alpha-1", name: "Alpha", isCurrent: false),
            ProviderChoice(id: "alpha-2", name: "alpha", isCurrent: false),
            ProviderChoice(id: "relay", name: "Relay Service", isCurrent: true)
        ]

        XCTAssertEqual(
            DashboardProviderListModel.filteredAndSorted(
                choices: choices,
                query: "  service ",
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

    func testEmptyListAndNoSearchResultsRemainEmpty() {
        let choices = [ProviderChoice(id: "one", name: "One", isCurrent: true)]

        XCTAssertTrue(
            DashboardProviderListModel.filteredAndSorted(
                choices: [],
                query: "",
                sortAlphabetically: true
            ).isEmpty
        )
        XCTAssertTrue(
            DashboardProviderListModel.filteredAndSorted(
                choices: choices,
                query: "missing",
                sortAlphabetically: false
            ).isEmpty
        )
    }

    func testSelectionIsRejectedAndClearedWhenProviderDisappears() {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        var state = DashboardProviderSelectionState()

        XCTAssertTrue(state.select(providerID: "other", from: choices))
        XCTAssertEqual(state.selectedProviderID, "other")
        XCTAssertFalse(state.select(providerID: "gone", from: choices))

        state.reconcile(with: [choices[0]])
        XCTAssertNil(state.selectedProviderID)
    }

    func testOlderAsynchronousRevisionCannotReplaceNewerData() {
        var gate = DashboardProviderRevisionGate()

        XCTAssertTrue(gate.accepts(12))
        XCTAssertFalse(gate.accepts(11))
        XCTAssertTrue(gate.accepts(12))
        XCTAssertTrue(gate.accepts(13))
        XCTAssertEqual(gate.latestRevision, 13)
    }

    @MainActor
    func testRelayRoutesEachProviderActionExactlyOnce() {
        let relay = DashboardProviderPageRelay()
        var refreshCount = 0
        var switched: [String] = []
        var opened: [String] = []
        var selected: [String] = []
        relay.onRefresh = { refreshCount += 1 }
        relay.onSwitchProvider = { switched.append($0) }
        relay.onOpenProvider = { opened.append($0) }
        relay.onSelectProvider = { selected.append($0) }

        let providerButton = NSButton()
        providerButton.identifier = NSUserInterfaceItemIdentifier("provider-1")
        relay.refresh(providerButton)
        relay.switchProvider(providerButton)
        relay.openProvider(providerButton)
        relay.selectProvider(providerButton)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(switched, ["provider-1"])
        XCTAssertEqual(opened, ["provider-1"])
        XCTAssertEqual(selected, ["provider-1"])
    }

    @MainActor
    func testTeardownRemovesProviderPageContentAndBlocksLaterRefresh() {
        let pages = DashboardProviderPages(actions: .testDefaults)
        let input = DashboardProviderPageInput(
            choices: [ProviderChoice(id: "current", name: "Current", isCurrent: true)],
            selectedProviderID: "current",
            snapshot: .placeholder,
            quickSwitchSummaries: [:],
            refreshDate: nil,
            revision: 1
        )
        _ = pages.makeOverviewPage(input: input)
        pages.teardown()

        XCTAssertFalse(pages.refreshOverview(input: input))
        XCTAssertTrue(pages.makeOverviewPage(input: input).subviews.isEmpty)
    }
}

private extension DashboardProviderPageActions {
    static var testDefaults: Self {
        Self(
            onRefresh: {},
            onSwitchProvider: { _ in },
            onOpenProvider: { _ in },
            onSelectProvider: { _ in },
            isSortAlphabetically: { false },
            setSortAlphabetically: { _ in }
        )
    }
}
