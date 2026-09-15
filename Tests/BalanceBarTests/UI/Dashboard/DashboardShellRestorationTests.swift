import AppKit
import XCTest
@testable import BalanceBar

final class DashboardShellRestorationTests: XCTestCase {
    private let defaultFrame = NSRect(x: 120, y: 80, width: 880, height: 620)
    private let mainScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let externalScreen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testEncodeDecodeRoundTripPreservesWindowedFrameAndSidebarState() {
        let state = DashboardShellRestorationState(
            windowedFrame: NSRect(x: 40, y: 60, width: 1000, height: 700),
            sidebarWidth: 280,
            isSidebarCollapsed: true
        )
        let encoded = DashboardShellRestoration.propertyList(from: state)
        let decoded = DashboardShellRestoration.decode(encoded)

        XCTAssertEqual(decoded?.windowedFrame, state.windowedFrame)
        XCTAssertEqual(decoded?.sidebarWidth, 280)
        XCTAssertEqual(decoded?.isSidebarCollapsed, true)
        XCTAssertNil(encoded["section"])
        XCTAssertNil(encoded["selectedProviderID"])
        XCTAssertNil(encoded["page"])
        XCTAssertNil(encoded["initialSection"])
        XCTAssertEqual(
            Array(encoded.keys).sorted(),
            ["isSidebarCollapsed", "sidebarWidth", "windowedFrame"]
        )
    }

    func testDecodeIgnoresUnknownKeysAndPartialRecords() {
        let partial = DashboardShellRestoration.decode([
            "sidebarWidth": 300,
            "section": 3,
            "selectedProviderID": "codex"
        ])
        XCTAssertNil(partial?.windowedFrame)
        XCTAssertEqual(partial?.sidebarWidth, 300)
        XCTAssertNil(partial?.isSidebarCollapsed)

        XCTAssertNil(DashboardShellRestoration.decode("not-a-dictionary"))
        XCTAssertNil(DashboardShellRestoration.decode([:]))
        XCTAssertNil(
            DashboardShellRestoration.decode([
                "windowedFrame": [0, 0, Double.nan, 620]
            ])
        )
    }

    func testClampRejectsHistoricalIllegalSidebarWidths() {
        XCTAssertEqual(
            DashboardShellRestoration.clampSidebarWidth(100),
            DashboardSplitViewController.minimumSidebarThickness
        )
        XCTAssertEqual(
            DashboardShellRestoration.clampSidebarWidth(500),
            DashboardSplitViewController.maximumSidebarThickness
        )
        XCTAssertEqual(
            DashboardShellRestoration.clampSidebarWidth(280),
            280
        )
        XCTAssertEqual(
            DashboardShellRestoration.clampSidebarWidth(.nan),
            DashboardSplitViewController.preferredSidebarThickness
        )
        XCTAssertEqual(
            DashboardSplitViewController.minimumSidebarThickness,
            212,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardSplitViewController.maximumSidebarThickness,
            320,
            accuracy: 0.001
        )
    }

    func testPlanPriorityPrefersSavedGeometryThenClampThenVisibility() {
        XCTAssertLessThan(
            DashboardShellRestorationFieldPriority.defaultGeometry,
            .savedWindowedFrame
        )
        XCTAssertLessThan(
            DashboardShellRestorationFieldPriority.savedWindowedFrame,
            .sidebarClamp
        )
        XCTAssertLessThan(
            DashboardShellRestorationFieldPriority.sidebarClamp,
            .visibleScreenCorrection
        )
        XCTAssertLessThan(
            DashboardShellRestorationFieldPriority.visibleScreenCorrection,
            .fullscreenIsolation
        )

        let savedFrame = NSRect(x: 200, y: 140, width: 1100, height: 740)
        let planned = DashboardShellRestoration.plan(
            saved: DashboardShellRestorationRecord(
                windowedFrame: savedFrame,
                sidebarWidth: 500,
                isSidebarCollapsed: true
            ),
            defaultFrame: defaultFrame,
            screens: [mainScreen]
        )
        XCTAssertEqual(planned.windowedFrame, savedFrame)
        XCTAssertEqual(planned.sidebarWidth, DashboardSplitViewController.maximumSidebarThickness)
        XCTAssertTrue(planned.isSidebarCollapsed)

        let defaults = DashboardShellRestoration.plan(
            saved: nil,
            defaultFrame: defaultFrame,
            screens: [mainScreen]
        )
        XCTAssertEqual(defaults.windowedFrame, defaultFrame)
        XCTAssertEqual(defaults.sidebarWidth, DashboardSplitViewController.preferredSidebarThickness)
        XCTAssertFalse(defaults.isSidebarCollapsed)
    }

    func testFullscreenFrameDoesNotOverwriteSavedWindowedFrame() {
        let windowed = NSRect(x: 80, y: 90, width: 960, height: 640)
        let fullscreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        XCTAssertEqual(
            DashboardShellRestoration.persistedWindowedFrame(
                currentFrame: fullscreen,
                isFullScreen: true,
                previouslySavedFrame: windowed
            ),
            windowed
        )
        XCTAssertNil(
            DashboardShellRestoration.persistedWindowedFrame(
                currentFrame: fullscreen,
                isFullScreen: true,
                previouslySavedFrame: nil
            )
        )
        XCTAssertEqual(
            DashboardShellRestoration.persistedWindowedFrame(
                currentFrame: windowed,
                isFullScreen: false,
                previouslySavedFrame: fullscreen
            ),
            windowed
        )
    }

    func testOffScreenAndRemovedDisplayFramesAreMovedOntoAVisibleScreen() {
        let offScreen = NSRect(x: -2000, y: 40, width: 900, height: 620)
        let corrected = DashboardShellRestoration.visibleFrame(
            offScreen,
            screens: [mainScreen],
            minSize: DashboardShellRestoration.minimumWindowSize,
            fallback: defaultFrame
        )
        XCTAssertTrue(mainScreen.contains(NSPoint(x: corrected.midX, y: corrected.midY)))
        XCTAssertGreaterThanOrEqual(corrected.width, DashboardShellRestoration.minimumWindowSize.width)
        XCTAssertGreaterThanOrEqual(corrected.height, DashboardShellRestoration.minimumWindowSize.height)

        let onRemovedDisplay = NSRect(x: 1600, y: 80, width: 1000, height: 700)
        let afterUnplug = DashboardShellRestoration.plan(
            saved: DashboardShellRestorationRecord(
                windowedFrame: onRemovedDisplay,
                sidebarWidth: 240,
                isSidebarCollapsed: false
            ),
            defaultFrame: defaultFrame,
            screens: [mainScreen]
        )
        XCTAssertTrue(mainScreen.intersects(afterUnplug.windowedFrame))
        XCTAssertGreaterThanOrEqual(
            afterUnplug.windowedFrame.intersection(mainScreen).width,
            DashboardShellRestoration.minimumVisibleWidth
        )
        XCTAssertFalse(externalScreen.intersects(afterUnplug.windowedFrame))
        XCTAssertEqual(afterUnplug.sidebarWidth, 240)
    }

    func testUserDefaultsStoreRoundTripUsesDedicatedIdentityKey() throws {
        let suiteName = "BalanceBar.DashboardShellRestorationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsDashboardShellRestorationStore(defaults: defaults)
        let state = DashboardShellRestorationState(
            windowedFrame: NSRect(x: 16, y: 24, width: 1020, height: 680),
            sidebarWidth: 260,
            isSidebarCollapsed: false
        )
        store.save(state)
        XCTAssertNotNil(defaults.object(forKey: DashboardShellRestoration.userDefaultsKey))
        XCTAssertEqual(store.load()?.windowedFrame, state.windowedFrame)
        XCTAssertEqual(store.load()?.sidebarWidth, 260)
        XCTAssertEqual(store.load()?.isSidebarCollapsed, false)
        XCTAssertEqual(DashboardShellRestoration.identity, "BalanceBar.Dashboard")
        XCTAssertEqual(
            DashboardShellRestoration.frameAutosaveName,
            NSWindow.FrameAutosaveName("BalanceBar.Dashboard")
        )
    }

    func testRestorationHelperDoesNotFakeSplitGeometry() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardShellRestoration.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("setPosition"))
        XCTAssertFalse(source.contains("requiredThickness"))
        XCTAssertFalse(source.contains("minimumThickness = maximumThickness"))
        XCTAssertFalse(source.contains("DashboardSection"))
        XCTAssertFalse(source.contains("selectedProviderID"))
        XCTAssertTrue(source.contains("frameAutosaveName"))
    }
}

@MainActor
final class DashboardShellRestorationWindowTests: XCTestCase {
    func testRestoredSidebarWidthAndCollapseSurviveCloseAndReopen() throws {
        let store = MemoryDashboardShellRestorationStore(
            record: DashboardShellRestorationRecord(
                windowedFrame: NSRect(x: 80, y: 60, width: 1020, height: 700),
                sidebarWidth: 280,
                isSidebarCollapsed: true
            )
        )
        let first = makeController(store: store)
        first.open(initialSection: .menuBar)
        let firstWindow = try XCTUnwrap(first.window)
        firstWindow.layoutIfNeeded()
        firstWindow.displayIfNeeded()
        XCTAssertEqual(firstWindow.frame.size.width, 1020, accuracy: 2)
        XCTAssertEqual(firstWindow.frame.size.height, 700, accuracy: 2)
        XCTAssertTrue(
            try XCTUnwrap(
                (firstWindow.contentViewController as? DashboardSplitViewController)?
                    .splitViewItems.first?.isCollapsed
            )
        )
        first.teardown()

        let controller = makeController(store: store)
        defer { controller.teardown() }
        controller.open(initialSection: .menuBar)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertEqual(window.identifier?.rawValue, DashboardShellRestoration.identity)
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertEqual(window.frame.size.width, 1020, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, 700, accuracy: 2)

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let sidebarItem = splitController.splitViewItems[0]
        XCTAssertTrue(sidebarItem.isCollapsed)
        XCTAssertEqual(controller.sourceListForTesting?.selectedSection(), .menuBar)

        splitController.toggleSidebar(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(sidebarItem.isCollapsed)
        XCTAssertEqual(
            sidebarItem.viewController.view.frame.width,
            280,
            accuracy: 2
        )
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertEqual(controller.sourceListForTesting?.selectedSection(), .menuBar)
        XCTAssertTrue(window.contentViewController is DashboardSplitViewController)
    }

    func testExplicitInitialSectionIsNotReplacedByRestoredGeometry() throws {
        let store = MemoryDashboardShellRestorationStore(
            record: DashboardShellRestorationRecord(
                windowedFrame: NSRect(x: 40, y: 40, width: 960, height: 640),
                sidebarWidth: 240,
                isSidebarCollapsed: false
            )
        )
        let controller = makeController(store: store)
        defer { controller.teardown() }

        controller.open(initialSection: .about)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.section, .about)
        XCTAssertEqual(controller.sourceListForTesting?.selectedSection(), .about)
        XCTAssertEqual(
            try XCTUnwrap(sidebarWidth(in: window)),
            240,
            accuracy: 2
        )
    }

    func testPersistedSidebarWidthIsClampedAndRebuildKeepsUserWidth() throws {
        let store = MemoryDashboardShellRestorationStore(
            record: DashboardShellRestorationRecord(
                windowedFrame: NSRect(x: 30, y: 30, width: 900, height: 620),
                sidebarWidth: 180,
                isSidebarCollapsed: false
            )
        )
        let controller = makeController(store: store)
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(
            try XCTUnwrap(sidebarWidth(in: window)),
            DashboardSplitViewController.minimumSidebarThickness,
            accuracy: 2
        )

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        splitController.splitView.setPosition(300, ofDividerAt: 0)
        window.layoutIfNeeded()
        let resized = try XCTUnwrap(sidebarWidth(in: window))
        XCTAssertGreaterThan(resized, DashboardSplitViewController.minimumSidebarThickness + 8)
        XCTAssertLessThanOrEqual(resized, DashboardSplitViewController.maximumSidebarThickness + 1)

        controller.rebuild()
        window.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(sidebarWidth(in: window)), resized, accuracy: 2)
        XCTAssertEqual(
            splitController.splitViewItems[0].holdingPriority,
            DashboardSplitViewController.sidebarHoldingPriority
        )
    }

    func testEmptyStoreKeepsDefaultWindowAndSidebarGeometry() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.width ?? -1, 880, accuracy: 1)
        XCTAssertEqual(window.contentView?.bounds.height ?? -1, 620, accuracy: 1)
        XCTAssertEqual(
            try XCTUnwrap(sidebarWidth(in: window)),
            DashboardSplitViewController.preferredSidebarThickness,
            accuracy: 1
        )
        XCTAssertFalse(
            try XCTUnwrap(
                (window.contentViewController as? DashboardSplitViewController)?
                    .splitViewItems.first?.isCollapsed
            )
        )
    }

    func testWindowCreationUsesDedicatedFrameAutosaveIdentity() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("setFrameAutosaveName"))
        XCTAssertTrue(source.contains("DashboardShellRestoration.frameAutosaveName"))
        XCTAssertTrue(source.contains("DashboardShellRestoration.identity"))
        XCTAssertFalse(source.contains("autosaveName ="))
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.identifier?.rawValue, DashboardShellRestoration.identity)
        XCTAssertFalse(window.toolbar?.autosavesConfiguration ?? true)
    }

    private func makeController(
        store: DashboardShellRestorationStoring = MemoryDashboardShellRestorationStore()
    ) -> DashboardWindowController {
        DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            ),
            restorationStore: store
        )
    }

    private func sidebarWidth(in window: NSWindow) -> CGFloat? {
        guard let splitController = window.contentViewController as? DashboardSplitViewController,
              let sidebarItem = splitController.splitViewItems.first
        else { return nil }
        return sidebarItem.viewController.view.frame.width
    }
}
