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
