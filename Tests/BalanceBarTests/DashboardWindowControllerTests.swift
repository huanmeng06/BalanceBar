import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardWindowControllerTests: XCTestCase {
    func testRepeatedStartAndOpenKeepOneObserverMonitorAndWindow() {
        var shownPageCount = 0
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { choices },
                prepareForPageReplacement: {},
                didShowPage: { shownPageCount += 1 },
                didClose: {},
                didResize: {}
            )
        )

        controller.start()
        controller.start()
        controller.open()
        let firstWindow = controller.window
        controller.open()
        firstWindow?.close()
        controller.open()

        XCTAssertNotNil(firstWindow)
        XCTAssertTrue(controller.window === firstWindow)
        XCTAssertEqual(controller.windowCreationCount, 1)
        XCTAssertEqual(controller.appearanceObserverInstallCount, 1)
        XCTAssertEqual(controller.mouseMonitorInstallCount, 1)
        XCTAssertEqual(shownPageCount, 1)

        controller.teardown()
        controller.teardown()
    }

    func testNavigationAndProviderSelectionSurviveShellRebuild() {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        var preparedPageCount = 0
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { choices },
                prepareForPageReplacement: { preparedPageCount += 1 },
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )

        controller.open()
        controller.showSection(.menu)
        XCTAssertEqual(controller.section, .menu)
        XCTAssertNil(controller.selectedProviderID)

        controller.showProvider("other")
        XCTAssertEqual(controller.selectedProviderID, "other")
        controller.rebuild()

        XCTAssertEqual(controller.selectedProviderID, "other")
        XCTAssertEqual(controller.section, .menu)
        XCTAssertGreaterThanOrEqual(preparedPageCount, 3)
        XCTAssertEqual(controller.windowCreationCount, 1)
        XCTAssertEqual(controller.mouseMonitorInstallCount, 1)

        controller.teardown()
    }

    func testTeardownIsIdempotentAndStopsWindowDelegateOwnership() {
        var closeCount = 0
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: { closeCount += 1 },
                didResize: {}
            )
        )

        controller.open()
        controller.teardown()
        controller.teardown()

        XCTAssertNil(controller.window)
        XCTAssertEqual(closeCount, 0)
    }
}

@MainActor
final class DashboardProductionPathRegressionTests: XCTestCase {
    func testMenuPageKeepsStatusLinksEditorWhenMenuDisplayIsDisabled() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
        }
        defaults.set(false, forKey: "showStatusMenu")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26.db"))
        )
        let page = appDelegate.dashboardPageForTesting(.menu)

        XCTAssertNotNil(findStatusLinksEditor(in: page))
    }

    func testOpenCodexMenuItemActivatesOnceForSelectedAndUnselectedStates() throws {
        for openCodexIsCurrent in [true, false] {
            var activationCount = 0
            let controller = StatusItemController(
                actions: StatusItemController.Actions(
                    manualRefresh: {},
                    openDashboard: {},
                    openChatGPT: {},
                    openCCSwitch: {},
                    openOpenCodex: { activationCount += 1 },
                    quit: {},
                    switchProvider: { _ in },
                    switchOpenCodexPreference: { _ in },
                    openProviderWebsite: {},
                    openStatusLink: { _ in },
                    iconChanged: { _ in }
                )
            )
            defer { controller.teardown() }

            let choices = [
                ProviderChoice(
                    id: "opencodex",
                    name: "OpenCodex",
                    isCurrent: openCodexIsCurrent
                ),
                ProviderChoice(
                    id: "other",
                    name: "Other Provider",
                    isCurrent: !openCodexIsCurrent
                )
            ]
            controller.start(
                snapshot: .placeholder,
                refreshDate: nil,
                menuInput: StatusItemController.MenuInput(
                    openCodexCards: [],
                    openCodexState: nil,
                    openCodexSwitchInFlight: false,
                    choices: choices,
                    quickSwitchSummaries: [:],
                    activeClient: .claude,
                    statusLinks: [
                        StatusLink(title: "Status", url: "https://status.example")
                    ],
                    showQuickSwitchMenu: true,
                    showOpenChatGPTMenu: true,
                    showOpenCCSwitchMenu: true,
                    showStatusMenu: true
                ),
                settings: StatusItemController.MenuBarSettings(
                    showIcon: true,
                    showAmount: true,
                    showReset: true,
                    horizontalPadding: 6,
                    keepMenuOpenAfterRefresh: true
                )
            )

            let openItem = try XCTUnwrap(
                controller.menuItemsForTesting.first {
                    $0.title.contains("OpenCodex")
                }
            )
            XCTAssertTrue(openItem.isEnabled)
            let target = try XCTUnwrap(openItem.target as? NSObject)
            _ = target.perform(openItem.action, with: openItem)
            XCTAssertEqual(activationCount, 1)
            XCTAssertEqual(
                controller.menuItemsForTesting.filter { $0.title.contains("OpenCodex") }.count,
                1
            )

            let statusMenuItem = try XCTUnwrap(
                controller.menuItemsForTesting.first {
                    $0.title == "查看状态" || $0.title == "View Status"
                }
            )
            XCTAssertEqual(statusMenuItem.submenu?.items.map(\.title), ["Status"])
        }
    }

    private func findStatusLinksEditor(in view: NSView) -> StatusLinksEditorHostingView? {
        if let editor = view as? StatusLinksEditorHostingView {
            return editor
        }
        for child in view.subviews {
            if let editor = findStatusLinksEditor(in: child) {
                return editor
            }
        }
        return nil
    }
}
