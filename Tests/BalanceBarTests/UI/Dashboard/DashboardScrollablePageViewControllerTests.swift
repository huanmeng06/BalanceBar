import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardScrollablePageViewControllerTests: XCTestCase {
    func testScrollablePageOwnsScrollChromeSignalsAndClipViewObserver() throws {
        let controller = makeTallScrollablePage()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let scrollView = try XCTUnwrap(controller.scrollViewForTesting)
        XCTAssertTrue(scrollView.contentView is NSClipView)
        XCTAssertFalse(scrollView.contentView is DashboardClipView)
        XCTAssertTrue(controller.documentViewForTesting is DashboardSettingsDocumentView)
        XCTAssertFalse(scrollView.automaticallyAdjustsContentInsets)
        XCTAssertEqual(scrollView.contentInsets.top, 0, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentInsets.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
        XCTAssertTrue(controller.clipViewObserverInstalledForTesting)
        XCTAssertTrue(try XCTUnwrap(controller.clipViewForTesting).postsBoundsChangedNotifications)
        XCTAssertTrue(controller.isAtTop)
        XCTAssertEqual(controller.scrollOffset, 0, accuracy: 1)

        let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: controller.view)
        XCTAssertEqual(
            viewportFrameInPage.minY - controller.view.bounds.minY,
            DashboardScrollablePageViewController.viewportTopInset,
            accuracy: 1
        )

        controller.restoreScrollOffset(140)
        window.layoutIfNeeded()
        XCTAssertFalse(controller.isAtTop)
        XCTAssertEqual(controller.scrollOffset, 140, accuracy: 2)
        XCTAssertEqual(
            DashboardPageScrollPosition.visualOffsetY(of: scrollView),
            140,
            accuracy: 2
        )
    }

    func testWindowControllerDelegatesScrollRestoreToThePageController() throws {
        let page = makeTallScrollablePage()
        let windowController = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in page },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { windowController.teardown() }

        windowController.open(initialSection: .advanced)
        let window = try XCTUnwrap(windowController.window)
        window.setContentSize(NSSize(width: 880, height: 620))
        window.layoutIfNeeded()
        windowController.contentHost.layoutSubtreeIfNeeded()

        let hostedPage = try XCTUnwrap(windowController.scrollablePageForTesting)
        XCTAssertTrue(hostedPage === page)
        XCTAssertTrue(windowController.pageContainerForTesting.currentPage === page)

        windowController.restorePageScrollOffsetY(160)
        XCTAssertEqual(hostedPage.scrollOffset, 160, accuracy: 2)
        XCTAssertEqual(windowController.pageScrollOffsetY(), 160, accuracy: 2)
        XCTAssertFalse(hostedPage.isAtTop)
        XCTAssertEqual(
            DashboardPageScrollPosition.visualOffsetY(in: windowController.contentHost),
            hostedPage.scrollOffset,
            accuracy: 2
        )
    }

    func testCompositionSettingsPagesUseScrollableControllerAndAboutDoesNot() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-389-scrollable-page.db")
            )
        )
        let composition = appDelegate.dashboardCompositionForTesting
        defer { composition.teardownForTesting() }

        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .advanced))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let advancedPage = try XCTUnwrap(composition.scrollablePageForTesting)
        XCTAssertTrue(
            composition.pageContainerForTesting.currentPage is DashboardScrollablePageViewController
        )
        XCTAssertTrue(advancedPage.clipViewObserverInstalledForTesting)
        let pageScroll = try XCTUnwrap(advancedPage.scrollViewForTesting)
        XCTAssertTrue(pageScroll === firstDescendant(of: advancedPage.view, as: NSScrollView.self))

        composition.showSection(.about)
        window.layoutIfNeeded()
        XCTAssertNil(composition.scrollablePageForTesting)
        XCTAssertTrue(
            composition.pageContainerForTesting.currentPage is DashboardHostedPageViewController
        )
        XCTAssertNil(
            firstDescendant(
                of: try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view),
                as: NSScrollView.self
            )
        )

        composition.showSection(.menuBar)
        window.setContentSize(NSSize(width: 880, height: 620))
        window.layoutIfNeeded()
        composition.contentHost.layoutSubtreeIfNeeded()
        let menuBarPage = try XCTUnwrap(composition.scrollablePageForTesting)
        composition.restorePageScrollOffsetY(96)
        XCTAssertEqual(composition.pageScrollOffsetY(), 96, accuracy: 2)
        XCTAssertEqual(menuBarPage.scrollOffset, 96, accuracy: 2)
        XCTAssertFalse(menuBarPage.isAtTop)
    }

    func testClipViewListeningLivesOnThePageNotTheWindow() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let windowSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        let pageSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardScrollablePageViewController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(windowSource.contains("boundsDidChangeNotification"))
        XCTAssertFalse(windowSource.contains("postsBoundsChangedNotifications"))
        XCTAssertFalse(windowSource.contains("visualOffsetY(in: contentHost)"))
        XCTAssertFalse(windowSource.contains("restore(visualOffsetY: offset, in: contentHost)"))
        XCTAssertTrue(windowSource.contains("currentScrollablePage?.scrollOffset"))
        XCTAssertTrue(windowSource.contains("currentScrollablePage?.restoreScrollOffset"))

        XCTAssertTrue(pageSource.contains("boundsDidChangeNotification"))
        XCTAssertTrue(pageSource.contains("postsBoundsChangedNotifications"))
        XCTAssertTrue(pageSource.contains("var isAtTop"))
        XCTAssertTrue(pageSource.contains("var scrollOffset"))
        XCTAssertFalse(pageSource.contains("NSGlassEffectView"))
        XCTAssertFalse(pageSource.contains("NSVisualEffectView"))
        XCTAssertFalse(pageSource.contains("shadowOpacity"))
        XCTAssertFalse(pageSource.contains("titlebarAccessory"))
    }

    private func makeTallScrollablePage() -> DashboardScrollablePageViewController {
        let filler = NSView()
        filler.translatesAutoresizingMaskIntoConstraints = false
        filler.heightAnchor.constraint(equalToConstant: 1800).isActive = true
        return DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPage([filler])
        )
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstDescendant(of: child, as: type) { return match }
        }
        return nil
    }
}
