import AppKit
import XCTest
@testable import BalanceBar

final class QuickSwitchTitleLayoutTests: XCTestCase {
    func testShortNamesKeepLegacySharedTab() {
        let layout = QuickSwitchTitleLayout.make(
            nameWidths: [48, 62],
            summaryWidths: [50, 36]
        )

        XCTAssertEqual(layout.tabLocation, QuickSwitchTitleLayout.minimumTabLocation)
        XCTAssertEqual(
            layout.minimumMenuWidth,
            QuickSwitchTitleLayout.minimumTabLocation + QuickSwitchTitleLayout.menuChromeWidth
        )
        XCTAssertFalse(layout.shouldTruncateName(width: 62))
    }

    func testMixedLongNameRaisesOneSharedTabForQuotaAndBalance() {
        let layout = QuickSwitchTitleLayout.make(
            nameWidths: [62, 220, 70],
            summaryWidths: [80, 80, 44]
        )

        let expectedTab = 220 + QuickSwitchTitleLayout.nameSummaryGap + 80
        XCTAssertEqual(layout.tabLocation, expectedTab)
        XCTAssertEqual(layout.minimumMenuWidth, expectedTab + QuickSwitchTitleLayout.menuChromeWidth)
        XCTAssertEqual(layout.nameColumnWidth, 220)
        XCTAssertFalse(layout.shouldTruncateName(width: 62))
        XCTAssertFalse(layout.shouldTruncateName(width: 220))
        XCTAssertGreaterThan(layout.tabLocation, QuickSwitchTitleLayout.minimumTabLocation)
    }

    func testLoadingEllipsisUsesTheSameTabAsRenderedSummaries() {
        let layout = QuickSwitchTitleLayout.make(
            nameWidths: [50, 180],
            summaryWidths: [12, 80]
        )

        XCTAssertEqual(
            layout.tabLocation,
            180 + QuickSwitchTitleLayout.nameSummaryGap + 80
        )
        XCTAssertEqual(layout.nameColumnWidth, 180)
    }

    func testExtremelyLongNameCapsTheSharedTabAndNameColumn() {
        let layout = QuickSwitchTitleLayout.make(
            nameWidths: [40, 800],
            summaryWidths: [80, 50]
        )

        XCTAssertEqual(layout.tabLocation, QuickSwitchTitleLayout.maximumTabLocation)
        XCTAssertEqual(
            layout.minimumMenuWidth,
            QuickSwitchTitleLayout.maximumTabLocation + QuickSwitchTitleLayout.menuChromeWidth
        )
        XCTAssertEqual(
            layout.nameColumnWidth,
            QuickSwitchTitleLayout.maximumTabLocation
                - QuickSwitchTitleLayout.nameSummaryGap
                - 80
        )
        XCTAssertTrue(layout.shouldTruncateName(width: 800))
        XCTAssertFalse(layout.shouldTruncateName(width: 40))
    }

    func testTruncatedNameFitsTheInjectedNameColumn() {
        let font = NSFont.menuFont(ofSize: 0)
        let name = "OpenAI Official (very-long-account@example.com)"
        let layout = QuickSwitchTitleLayout.make(
            names: ["Right Code", name, "Mini"],
            summaries: ["100% / 7日", "100% / 7日", "$6.54"],
            font: font
        )
        let displayed = QuickSwitchTitleLayout.truncatedName(
            name,
            fitting: layout.nameColumnWidth,
            font: font
        )

        XCTAssertLessThanOrEqual(
            QuickSwitchTitleLayout.width(of: displayed, font: font),
            layout.nameColumnWidth
        )
        if layout.shouldTruncateName(width: QuickSwitchTitleLayout.width(of: name, font: font)) {
            XCTAssertTrue(displayed.hasSuffix("…"))
            XCTAssertNotEqual(displayed, name)
        } else {
            XCTAssertEqual(displayed, name)
        }
    }

    func testEmptyRowsKeepTheLegacyMinimumMenuWidth() {
        let layout = QuickSwitchTitleLayout.make(nameWidths: [], summaryWidths: [])
        XCTAssertEqual(layout.tabLocation, QuickSwitchTitleLayout.minimumTabLocation)
        XCTAssertEqual(layout.minimumMenuWidth, 210)
    }

    @MainActor
    func testQuickSwitchMenuItemsShareOneRightAlignedTab() {
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                openOpenCodex: {},
                quit: {},
                switchProvider: { _ in },
                switchOpenCodexPreference: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let longName = "OpenAI Official (very-long-account@example.com)"
        let input = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [
                ProviderChoice(id: "short-official", name: "Right Code", isCurrent: true),
                ProviderChoice(id: "long-official", name: longName, isCurrent: false),
                ProviderChoice(id: "short-balance", name: "Mini", isCurrent: false)
            ],
            quickSwitchSummaries: [
                "short-official": "100% / 7日",
                "long-official": "100% / 7日",
                "short-balance": "$6.54"
            ],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showOpenCodexMenu: false,
            showStatusMenu: false
        )
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: StatusItemController.MenuBarSettings(
                showIcon: true,
                showAmount: true,
                showReset: true,
                horizontalPadding: 6,
                keepMenuOpenAfterRefresh: true
            )
        )
        controller.menuWillOpen(controller.statusMenuForTesting)
        defer { controller.menuDidClose(controller.statusMenuForTesting) }

        guard let submenu = controller.menuItemsForTesting.compactMap(\.submenu).first else {
            XCTFail("quick switch submenu missing")
            return
        }
        XCTAssertEqual(submenu.items.count, 3)
        XCTAssertEqual(submenu.items[0].state, .on)
        XCTAssertEqual(submenu.items[1].state, .off)
        XCTAssertEqual(submenu.items[2].state, .off)

        let tabLocations = submenu.items.map { item -> CGFloat in
            guard let attributedTitle = item.attributedTitle else {
                XCTFail("quick switch item missing attributedTitle")
                return -1
            }
            let style = attributedTitle.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
            XCTAssertEqual(style?.tabStops.count, 1)
            XCTAssertEqual(style?.tabStops.first?.alignment, .right)
            return style?.tabStops.first?.location ?? -1
        }
        XCTAssertEqual(Set(tabLocations).count, 1, "every row must share one right edge")
        XCTAssertEqual(submenu.minimumWidth, tabLocations[0] + QuickSwitchTitleLayout.menuChromeWidth)

        let titles = submenu.items.map(\.title)
        XCTAssertTrue(titles[0].contains("Right Code"))
        XCTAssertTrue(titles[0].contains("100% / 7日"))
        XCTAssertTrue(titles[1].contains("100% / 7日"))
        XCTAssertTrue(titles[2].hasSuffix("$6.54"))
        XCTAssertFalse(titles.contains { $0.contains("\n") })
        XCTAssertEqual(
            submenu.items.map { $0.action.map(NSStringFromSelector) },
            Array(repeating: "switchProvider:", count: 3)
        )
    }
}
