import AppKit
import XCTest
@testable import BalanceBar

final class AppDelegateCompositionTests: XCTestCase {
    func testAppDelegateBoundaryContainsOnlyCompositionResponsibilities() throws {
        let source = try balanceBarSource()
        let appDelegateStart = try XCTUnwrap(
            source.range(of: "final class AppDelegate: NSObject, NSApplicationDelegate")
        )
        let appDelegateEnd = try XCTUnwrap(
            source.range(of: "struct ApplicationLifecycleStats", range: appDelegateStart.upperBound..<source.endIndex)
        )
        let appDelegateSource = String(source[appDelegateStart.lowerBound..<appDelegateEnd.lowerBound])

        XCTAssertFalse(appDelegateSource.contains("sqlite3"))
        XCTAssertFalse(appDelegateSource.contains("URLSession"))
        XCTAssertFalse(appDelegateSource.contains("NSView("))
        XCTAssertFalse(appDelegateSource.contains("NSWindow("))
        XCTAssertFalse(appDelegateSource.contains("NSView"))
        XCTAssertFalse(appDelegateSource.contains("DispatchSource"))
        XCTAssertFalse(appDelegateSource.contains("CodexActivityMonitor"))
        XCTAssertFalse(appDelegateSource.contains("ClaudeCodeActivityMonitor"))
        XCTAssertFalse(appDelegateSource.contains("fetchBalance"))
        XCTAssertFalse(appDelegateSource.contains("fetchQuota"))
        XCTAssertFalse(appDelegateSource.contains("makeDashboardPage"))
        XCTAssertFalse(appDelegateSource.contains("makeSectionPage"))
        XCTAssertFalse(appDelegateSource.contains("fetchBalance"))
        XCTAssertFalse(appDelegateSource.contains("refreshCodexActivity"))
        XCTAssertFalse(source.contains("BalanceBarApplicationCoordinator"))
    }

    func testCompositionLayerOwnsConcreteResponsibilitiesByModule() throws {
        let sources = try compositionSources()
        let dashboard = try XCTUnwrap(sources["DashboardCompositionController.swift"])
        XCTAssertTrue(dashboard.contains("DashboardWindowController"))
        XCTAssertTrue(dashboard.contains("DashboardPreferencePages"))
        XCTAssertTrue(dashboard.contains("DashboardProviderPageCoordinator"))
        XCTAssertTrue(dashboard.contains("makeSectionPage"))
        XCTAssertTrue(dashboard.contains("StatusLinksEditorHostingView"))

        let provider = try XCTUnwrap(sources["ProviderRefreshCoordinator.swift"])
        XCTAssertTrue(provider.contains("BalanceAPIClient"))
        XCTAssertTrue(provider.contains("OfficialQuotaClient"))
        XCTAssertTrue(provider.contains("fetchBalance"))

        let openCodex = try XCTUnwrap(sources["OpenCodexRefreshCoordinator.swift"])
        XCTAssertTrue(openCodex.contains("OpenCodexRepository"))
        XCTAssertTrue(openCodex.contains("OpenCodexCardPlanner"))
        XCTAssertTrue(openCodex.contains("fetchOfficialCard"))

        let activity = try XCTUnwrap(sources["ActivityCoordinator.swift"])
        XCTAssertTrue(activity.contains("CodexActivityMonitor"))
        XCTAssertTrue(activity.contains("ClaudeCodeActivityMonitor"))
        XCTAssertTrue(activity.contains("NSWorkspace"))

        let watcher = try XCTUnwrap(sources["CCSwitchDatabaseWatcher.swift"])
        XCTAssertTrue(watcher.contains("DispatchSource"))
        XCTAssertTrue(watcher.contains("O_EVTONLY"))

        let switching = try XCTUnwrap(sources["ProviderSwitchCoordinator.swift"])
        XCTAssertTrue(switching.contains("switchCurrent"))
        XCTAssertTrue(switching.contains("com.ccswitch.desktop"))
    }

    @MainActor
    func testMenuBarWidthCoalescerFlushesLatestValueAndCancelsPendingWork() {
        var applied: [CGFloat] = []
        let coalescer = MenuBarWidthDisplayCoalescer { applied.append($0) }

        coalescer.submit(3.1)
        coalescer.submit(7.4)
        coalescer.flush()

        XCTAssertEqual(applied, [7.4])

        coalescer.submit(12.6)
        coalescer.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(applied, [7.4])
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
    func testStatusItemStartIsIdempotentAndTeardownIsSafe() throws {
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
            openAIAccount: nil,
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

        let initialLength = try XCTUnwrap(controller.statusItemLengthForTesting)
        let menuItemIdentities = controller.menuItemsForTesting.map { ObjectIdentifier($0) }
        controller.updateWidthAdjustment(10)
        controller.updateWidthAdjustment(20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            controller.statusItemLengthForTesting ?? .nan,
            initialLength + 20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.menuItemsForTesting.map { ObjectIdentifier($0) },
            menuItemIdentities,
            "continuous width updates must not rebuild the status menu"
        )

        controller.teardown()
        controller.teardown()
    }

    func testDatabaseWatcherStartAndStopAreIdempotent() {
        let watcher = CCSwitchDatabaseWatcher(
            databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-watcher.db"),
            onChange: {}
        )
        watcher.start()
        watcher.start()
        XCTAssertEqual(watcher.startCount, 1)
        watcher.stop()
        watcher.stop()
    }

    @MainActor
    func testActivityCoordinatorInstallsOneTimerAndObserverPerLifecycle() {
        let coordinator = ActivityCoordinator(
            actions: ActivityCoordinatorActions(
                activeClient: { .codex },
                claudeProcessAvailable: { false },
                setClaudeProcessAvailable: { _ in },
                setActiveClient: { _ in },
                setCodexTaskRunning: { _ in },
                setClaudeTaskRunning: { _ in }
            )
        )
        coordinator.start(interval: 60)
        coordinator.start(interval: 60)
        XCTAssertEqual(coordinator.startCount, 1)
        coordinator.stop()
        coordinator.stop()
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

    private func compositionSources(file: StaticString = #filePath) throws -> [String: String] {
        let testFile = URL(fileURLWithPath: String(describing: file))
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "DashboardCompositionController.swift": "work/balance-bar/Sources/UI/Dashboard/DashboardCompositionController.swift",
            "ProviderRefreshCoordinator.swift": "work/balance-bar/Sources/Services/ProviderRefreshCoordinator.swift",
            "OpenCodexRefreshCoordinator.swift": "work/balance-bar/Sources/Services/OpenCodexRefreshCoordinator.swift",
            "ActivityCoordinator.swift": "work/balance-bar/Sources/Monitoring/ActivityCoordinator.swift",
            "CCSwitchDatabaseWatcher.swift": "work/balance-bar/Sources/Services/CCSwitchDatabaseWatcher.swift",
            "ProviderSwitchCoordinator.swift": "work/balance-bar/Sources/Services/ProviderSwitchCoordinator.swift"
        ]
        return try Dictionary(uniqueKeysWithValues: files.map { name, path in
            (name, try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8))
        })
    }
}

@MainActor
final class ApplicationMenuConfigurationTests: XCTestCase {
    func testWindowMenuRestoresStandardCommandsAndResponderRouting() throws {
        let configuration = ApplicationMenuConfiguration.make()
        let windowMenu = configuration.windowMenu

        let close = try XCTUnwrap(item(in: windowMenu, action: #selector(NSWindow.performClose(_:))))
        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(close.keyEquivalentModifierMask, [.command])
        XCTAssertNil(close.target)

        let minimize = try XCTUnwrap(item(in: windowMenu, action: #selector(NSWindow.performMiniaturize(_:))))
        XCTAssertEqual(minimize.keyEquivalent, "m")
        XCTAssertEqual(minimize.keyEquivalentModifierMask, [.command])
        XCTAssertNil(minimize.target)

        let zoom = try XCTUnwrap(item(in: windowMenu, action: #selector(NSWindow.performZoom(_:))))
        XCTAssertTrue(zoom.keyEquivalent.isEmpty)
        XCTAssertNil(zoom.target)

        let arrange = try XCTUnwrap(item(in: windowMenu, action: #selector(NSApplication.arrangeInFront(_:))))
        XCTAssertTrue(arrange.keyEquivalent.isEmpty)
        XCTAssertNil(arrange.target)
        XCTAssertTrue(configuration.mainMenu.items.contains { $0.submenu === windowMenu })
    }

    func testApplicationAndEditMenusPreserveDefaultShortcutCommands() throws {
        let configuration = ApplicationMenuConfiguration.make()
        let applicationMenu = try XCTUnwrap(configuration.mainMenu.items.first?.submenu)
        let editMenu = try XCTUnwrap(configuration.mainMenu.items.dropFirst().first?.submenu)

        let hide = try XCTUnwrap(item(in: applicationMenu, action: #selector(NSApplication.hide(_:))))
        XCTAssertEqual(hide.keyEquivalent, "h")
        XCTAssertEqual(hide.keyEquivalentModifierMask, [.command])

        let hideOthers = try XCTUnwrap(item(in: applicationMenu, action: #selector(NSApplication.hideOtherApplications(_:))))
        XCTAssertEqual(hideOthers.keyEquivalent, "h")
        XCTAssertEqual(hideOthers.keyEquivalentModifierMask, [.command, .option])

        let quit = try XCTUnwrap(item(in: applicationMenu, action: #selector(NSApplication.terminate(_:))))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(quit.target === NSApp)

        let expectedEditCommands: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(UndoManager.undo), "z", [.command]),
            (#selector(UndoManager.redo), "z", [.command, .shift]),
            (#selector(NSText.cut(_:)), "x", [.command]),
            (#selector(NSText.copy(_:)), "c", [.command]),
            (#selector(NSText.paste(_:)), "v", [.command]),
            (#selector(NSText.selectAll(_:)), "a", [.command])
        ]
        for (action, keyEquivalent, modifiers) in expectedEditCommands {
            let item = try XCTUnwrap(item(in: editMenu, action: action))
            XCTAssertEqual(item.keyEquivalent, keyEquivalent)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
        }
    }

    func testDashboardWindowKeepsMiniaturizableStyleForWindowCommandRouting() throws {
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in NSView() },
                makeProviderPage: { _ in NSView() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        let minimize = try XCTUnwrap(
            item(in: ApplicationMenuConfiguration.make().windowMenu, action: #selector(NSWindow.performMiniaturize(_:)))
        )

        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.responds(to: try XCTUnwrap(minimize.action)))
        XCTAssertNil(minimize.target)
    }

    private func item(in menu: NSMenu, action: Selector) -> NSMenuItem? {
        menu.items.first { $0.action == action }
    }
}
