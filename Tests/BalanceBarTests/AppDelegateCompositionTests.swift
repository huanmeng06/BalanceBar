import XCTest
@testable import BalanceBar

final class AppDelegateCompositionTests: XCTestCase {
    func testAppDelegateBoundaryContainsOnlyCompositionResponsibilities() throws {
        let source = try balanceBarSource()
        let appDelegateStart = try XCTUnwrap(
            source.range(of: "final class AppDelegate: NSObject, NSApplicationDelegate")
        )
        let appDelegateEnd = try XCTUnwrap(
            source.range(of: "@main", range: appDelegateStart.upperBound..<source.endIndex)
        )
        let appDelegateSource = String(source[appDelegateStart.lowerBound..<appDelegateEnd.lowerBound])

        XCTAssertFalse(appDelegateSource.contains("sqlite3"))
        XCTAssertFalse(appDelegateSource.contains("URLSession"))
        XCTAssertFalse(appDelegateSource.contains("NSView("))
        XCTAssertFalse(appDelegateSource.contains("NSWindow("))
        XCTAssertFalse(appDelegateSource.contains("makeDashboardPage"))
        XCTAssertFalse(appDelegateSource.contains("fetchBalance"))
        XCTAssertFalse(appDelegateSource.contains("refreshCodexActivity"))
        XCTAssertLessThanOrEqual(appDelegateSource.components(separatedBy: "\n").count, 90)
    }

    func testLifecycleGateInstallsAndTearsDownExactlyOnce() {
        let lifecycle = ApplicationLifecycleState()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertFalse(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.beginTerminate())
        XCTAssertFalse(lifecycle.beginTerminate())
        XCTAssertFalse(lifecycle.beginStart())
        XCTAssertEqual(
            lifecycle.stats,
            ApplicationLifecycleStats(startCount: 1, terminateCount: 1)
        )
    }

    @MainActor
    func testStatusItemStartIsIdempotentAndTeardownIsSafe() {
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
        let input = StatusItemController.MenuInput(
            openCodexCards: [],
            openCodexState: nil,
            openCodexSwitchInFlight: false,
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            statusLinks: [],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showOpenCodexMenu: true,
            showStatusMenu: true
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )

        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings
        )
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: input,
            settings: settings
        )
        XCTAssertEqual(controller.statusItemInstallCount, 1)

        controller.teardown()
        controller.teardown()
    }

    private func balanceBarSource(file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: String(describing: file))
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot
            .appendingPathComponent("work/balance-bar/BalanceBar.swift"), encoding: .utf8)
    }
}
