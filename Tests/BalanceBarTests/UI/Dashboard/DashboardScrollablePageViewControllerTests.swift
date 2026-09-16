import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardScrollablePageViewControllerTests: XCTestCase {
    func testControllerCreatesAndOwnsPageScrollChromeForOrdinaryContent() throws {
        let filler = tallFiller(height: 1800)
        let content = DashboardSettingsComponents.makeSettingsPageContent([filler])
        XCTAssertNil(firstDescendant(of: content, as: NSScrollView.self))

        let controller = DashboardScrollablePageViewController(wrapping: content)
        let window = makeWindow(width: 480, height: 280, hosting: controller)
        defer { window.orderOut(nil) }

        XCTAssertTrue(controller.pageScrollView === controller.scrollViewForTesting)
        XCTAssertTrue(controller.documentViewForTesting === controller.pageScrollView.documentView)
        XCTAssertTrue(controller.clipViewForTesting === controller.pageScrollView.contentView)
        XCTAssertTrue(controller.documentViewForTesting is DashboardSettingsDocumentView)
        XCTAssertTrue(controller.pageScrollView.contentView is NSClipView)
        XCTAssertFalse(controller.pageScrollView.contentView is DashboardClipView)
        XCTAssertTrue(content.isDescendant(of: controller.documentViewForTesting))
        XCTAssertFalse(content.superview === controller.documentViewForTesting)
        XCTAssertEqual(
            descendants(of: controller.view).compactMap { $0 as? NSScrollView }.count,
            1
        )

        XCTAssertFalse(controller.pageScrollView.automaticallyAdjustsContentInsets)
        XCTAssertEqual(controller.pageScrollView.contentInsets.top, 0, accuracy: 0.001)
        XCTAssertEqual(controller.pageScrollView.contentInsets.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(controller.pageScrollView.scrollerInsets.top, 0, accuracy: 0.001)
        XCTAssertEqual(controller.pageScrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(controller.pageScrollView.horizontalScrollElasticity, .none)
        XCTAssertTrue(controller.clipViewObserverInstalledForTesting)
        XCTAssertTrue(controller.clipViewForTesting.postsBoundsChangedNotifications)
        XCTAssertTrue(controller.isAtTop)
        XCTAssertEqual(controller.scrollOffset, 0, accuracy: 1)

        let viewportFrameInPage = controller.pageScrollView.convert(
            controller.pageScrollView.bounds,
            to: controller.view
        )
        XCTAssertEqual(
            viewportFrameInPage.minY - controller.view.bounds.minY,
            DashboardScrollablePageViewController.viewportTopInset,
            accuracy: 1
        )
        XCTAssertEqual(
            viewportFrameInPage.minX,
            controller.view.safeAreaRect.minX,
            accuracy: 1
        )
        XCTAssertEqual(
            viewportFrameInPage.maxX,
            controller.view.safeAreaRect.maxX,
            accuracy: 1
        )

        let document = try XCTUnwrap(controller.documentViewForTesting)
        XCTAssertEqual(
            content.frame.minX - document.bounds.minX,
            DashboardScrollablePageViewController.documentHorizontalInset,
            accuracy: 1
        )
        XCTAssertEqual(
            document.bounds.maxX - content.frame.maxX,
            DashboardScrollablePageViewController.documentHorizontalInset,
            accuracy: 1
        )
    }

    func testNestedScrollViewIsNotTreatedAsThePageScrollView() throws {
        let nestedScroll = NSScrollView()
        nestedScroll.identifier = NSUserInterfaceItemIdentifier("nested-page-content-scroll")
        nestedScroll.hasVerticalScroller = true
        nestedScroll.drawsBackground = false
        nestedScroll.translatesAutoresizingMaskIntoConstraints = false
        let nestedDocument = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 2400))
        nestedScroll.documentView = nestedDocument
        nestedScroll.contentView.postsBoundsChangedNotifications = true
        nestedScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let filler = tallFiller(height: 1800)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nestedScroll)
        content.addSubview(filler)
        NSLayoutConstraint.activate([
            nestedScroll.topAnchor.constraint(equalTo: content.topAnchor),
            nestedScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            nestedScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filler.topAnchor.constraint(equalTo: nestedScroll.bottomAnchor, constant: 8),
            filler.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filler.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filler.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let controller = DashboardScrollablePageViewController(wrapping: content)
        let window = makeWindow(width: 480, height: 280, hosting: controller)
        defer { window.orderOut(nil) }

        XCTAssertTrue(controller.pageScrollView !== nestedScroll)
        XCTAssertTrue(
            DashboardPageScrollPosition.firstScrollView(in: content) === nestedScroll
        )
        XCTAssertTrue(controller.clipViewForTesting !== nestedScroll.contentView)
        XCTAssertTrue(controller.clipViewObserverInstalledForTesting)

        nestedScroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        nestedScroll.reflectScrolledClipView(nestedScroll.contentView)
        XCTAssertTrue(controller.isAtTop)
        XCTAssertEqual(controller.scrollOffset, 0, accuracy: 1)

        nestedScroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        nestedScroll.reflectScrolledClipView(nestedScroll.contentView)

        var observedPageClipChanges = 0
        var observedNestedClipChanges = 0
        let pageObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: controller.clipViewForTesting,
            queue: nil
        ) { _ in
            observedPageClipChanges += 1
        }
        let nestedObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nestedScroll.contentView,
            queue: nil
        ) { _ in
            observedNestedClipChanges += 1
        }
        defer {
            NotificationCenter.default.removeObserver(pageObserver)
            NotificationCenter.default.removeObserver(nestedObserver)
        }

        nestedScroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        nestedScroll.reflectScrolledClipView(nestedScroll.contentView)
        XCTAssertEqual(controller.scrollOffset, 0, accuracy: 1)
        XCTAssertGreaterThan(observedNestedClipChanges, 0)
        XCTAssertEqual(observedPageClipChanges, 0)

        controller.restoreScrollOffset(140)
        window.layoutIfNeeded()
        XCTAssertFalse(controller.isAtTop)
        XCTAssertEqual(controller.scrollOffset, 140, accuracy: 2)
        XCTAssertEqual(
            DashboardPageScrollPosition.visualOffsetY(of: controller.pageScrollView),
            140,
            accuracy: 2
        )
        XCTAssertNotEqual(
            DashboardPageScrollPosition.visualOffsetY(of: nestedScroll),
            controller.scrollOffset,
            accuracy: 1
        )
        XCTAssertGreaterThan(observedPageClipChanges, 0)
    }

    func testScrollRestoreClampsAndSurvivesResizeOnFlippedDocument() throws {
        let controller = DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPageContent([tallFiller(height: 1800)])
        )
        let window = makeWindow(width: 480, height: 280, hosting: controller)
        defer { window.orderOut(nil) }

        XCTAssertTrue(try XCTUnwrap(controller.documentViewForTesting).isFlipped)
        XCTAssertTrue(controller.isAtTop)
        XCTAssertEqual(controller.scrollOffset, 0, accuracy: 1)

        controller.restoreScrollOffset(0)
        XCTAssertEqual(controller.scrollOffset, 0, accuracy: 1)
        XCTAssertTrue(controller.isAtTop)

        controller.restoreScrollOffset(140)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.scrollOffset, 140, accuracy: 2)
        XCTAssertFalse(controller.isAtTop)

        let geometry = DashboardScrollGeometry(
            documentBounds: try XCTUnwrap(controller.documentViewForTesting).bounds,
            viewportHeight: controller.clipViewForTesting.bounds.height,
            isDocumentFlipped: true
        )
        XCTAssertGreaterThan(geometry.maximumOffset, 140)

        controller.restoreScrollOffset(geometry.maximumOffset + 400)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.scrollOffset, geometry.maximumOffset, accuracy: 2)

        window.setContentSize(NSSize(width: 480, height: 520))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let resizedGeometry = DashboardScrollGeometry(
            documentBounds: try XCTUnwrap(controller.documentViewForTesting).bounds,
            viewportHeight: controller.clipViewForTesting.bounds.height,
            isDocumentFlipped: true
        )
        XCTAssertGreaterThanOrEqual(controller.scrollOffset, 0)
        XCTAssertLessThanOrEqual(
            controller.scrollOffset,
            resizedGeometry.maximumOffset + 1
        )
        XCTAssertEqual(
            controller.scrollOffset,
            resizedGeometry.clampedVisualOffset(controller.scrollOffset),
            accuracy: 2
        )
    }

    func testWindowControllerDelegatesScrollRestoreToThePageController() throws {
        let page = DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPageContent([tallFiller(height: 1800)])
        )
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
        XCTAssertTrue(hostedPage.pageScrollView === page.pageScrollView)

        windowController.restorePageScrollOffsetY(160)
        XCTAssertEqual(hostedPage.scrollOffset, 160, accuracy: 2)
        XCTAssertEqual(windowController.pageScrollOffsetY(), 160, accuracy: 2)
        XCTAssertFalse(hostedPage.isAtTop)
        XCTAssertEqual(
            DashboardPageScrollPosition.visualOffsetY(of: hostedPage.pageScrollView),
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
        XCTAssertTrue(advancedPage.pageScrollView === advancedPage.scrollViewForTesting)
        let nestedScrollViews = descendants(of: advancedPage.hostedContentForTesting)
            .compactMap { $0 as? NSScrollView }
        if let nestedScroll = nestedScrollViews.first {
            XCTAssertTrue(advancedPage.pageScrollView !== nestedScroll)
        }

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
        XCTAssertTrue(menuBarPage.pageScrollView === menuBarPage.scrollViewForTesting)
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
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/Components/DashboardSettingsComponents.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(windowSource.contains("boundsDidChangeNotification"))
        XCTAssertFalse(windowSource.contains("postsBoundsChangedNotifications"))
        XCTAssertFalse(windowSource.contains("visualOffsetY(in: contentHost)"))
        XCTAssertFalse(windowSource.contains("restore(visualOffsetY: offset, in: contentHost)"))
        XCTAssertFalse(windowSource.contains("firstScrollView(in: contentHost)"))
        XCTAssertTrue(windowSource.contains("currentScrollablePage?.scrollOffset"))
        XCTAssertTrue(windowSource.contains("currentScrollablePage?.restoreScrollOffset"))

        XCTAssertTrue(pageSource.contains("boundsDidChangeNotification"))
        XCTAssertTrue(pageSource.contains("postsBoundsChangedNotifications"))
        XCTAssertTrue(pageSource.contains("let pageScrollView: NSScrollView"))
        XCTAssertTrue(pageSource.contains("var isAtTop"))
        XCTAssertTrue(pageSource.contains("var scrollOffset"))
        XCTAssertTrue(pageSource.contains("root.safeAreaLayoutGuide.leadingAnchor"))
        XCTAssertTrue(pageSource.contains("root.safeAreaLayoutGuide.trailingAnchor"))
        XCTAssertTrue(pageSource.contains("dashboardPageDocumentFill"))
        XCTAssertTrue(pageSource.contains("DashboardSettingsDocumentFillView"))
        XCTAssertTrue(pageSource.contains("greaterThanOrEqualTo: scrollView.contentView.heightAnchor"))
        XCTAssertTrue(pageSource.contains("documentView.addSubview(contentHost)"))
        XCTAssertTrue(pageSource.contains("documentView.addSubview(documentFill)"))
        XCTAssertFalse(pageSource.contains("NSStackView(views: [contentHost, documentFill])"))
        XCTAssertFalse(pageSource.contains("firstScrollView(in:"))
        XCTAssertFalse(pageSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(pageSource.contains("preferredSidebarThickness"))
        XCTAssertFalse(pageSource.contains("minimumSidebarThickness"))
        XCTAssertFalse(pageSource.contains("additionalSafeAreaInsets"))
        XCTAssertFalse(pageSource.contains("NSGlassEffectView"))
        XCTAssertFalse(pageSource.contains("NSVisualEffectView"))
        XCTAssertFalse(pageSource.contains("shadowOpacity"))
        XCTAssertFalse(pageSource.contains("titlebarAccessory"))

        XCTAssertTrue(settingsSource.contains("makeSettingsPageContent"))
        XCTAssertFalse(settingsSource.contains("let viewportTopInset: CGFloat = 52"))
        XCTAssertFalse(settingsSource.contains("NSScrollView()"))
    }

    private func makeWindow(
        width: CGFloat,
        height: CGFloat,
        hosting controller: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func tallFiller(height: CGFloat) -> NSView {
        let filler = NSView()
        filler.translatesAutoresizingMaskIntoConstraints = false
        filler.heightAnchor.constraint(equalToConstant: height).isActive = true
        return filler
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstDescendant(of: child, as: type) { return match }
        }
        return nil
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
