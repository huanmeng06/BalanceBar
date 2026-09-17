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

        XCTAssertEqual(controller.layoutPolicy, DashboardPageScrollLayoutPolicy.current)
        XCTAssertEqual(
            controller.pageScrollView.automaticallyAdjustsContentInsets,
            controller.layoutPolicy.automaticallyAdjustsContentInsets
        )
        XCTAssertEqual(controller.pageScrollView.contentInsets.top, 0, accuracy: 0.001)
        XCTAssertEqual(controller.pageScrollView.contentInsets.bottom, 0, accuracy: 0.001)
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
            controller.layoutPolicy.viewportTopInset,
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
        XCTAssertTrue(windowSource.contains("applyTitlebarSeparators"))
        XCTAssertFalse(windowSource.contains("titlebarSeparatorStyle = .none"))
        XCTAssertFalse(windowSource.contains("allowedPocketEdges"))
        XCTAssertFalse(windowSource.contains("alwaysShownPocketEdges"))
        XCTAssertFalse(windowSource.contains("scrollPocketStyle"))
        XCTAssertFalse(windowSource.contains("topShadowTopInset"))
        XCTAssertFalse(windowSource.contains("NSScrollPocket"))
        XCTAssertFalse(windowSource.contains("preferredScrollEdgeEffectStyle"))
        XCTAssertFalse(windowSource.contains("dashboardPageScrollEdgeHairline"))

        XCTAssertTrue(pageSource.contains("boundsDidChangeNotification"))
        XCTAssertTrue(pageSource.contains("postsBoundsChangedNotifications"))
        XCTAssertTrue(pageSource.contains("let pageScrollView: NSScrollView"))
        XCTAssertTrue(pageSource.contains("var isAtTop"))
        XCTAssertTrue(pageSource.contains("var scrollOffset"))
        XCTAssertTrue(pageSource.contains("root.safeAreaLayoutGuide.leadingAnchor"))
        XCTAssertTrue(pageSource.contains("root.safeAreaLayoutGuide.trailingAnchor"))
        XCTAssertTrue(pageSource.contains("dashboardPageDocumentFill"))
        XCTAssertTrue(pageSource.contains("DashboardSettingsDocumentFillView"))
        XCTAssertTrue(pageSource.contains("DashboardSettingsContentHost"))
        XCTAssertTrue(pageSource.contains("greaterThanOrEqualTo: scrollView.safeAreaLayoutGuide.heightAnchor"))
        XCTAssertTrue(pageSource.contains("layoutPolicy.apply(to: scrollView)"))
        XCTAssertTrue(pageSource.contains("layoutPolicy.viewportTopInset"))
        XCTAssertTrue(pageSource.contains("documentView.addSubview(contentHost)"))
        XCTAssertTrue(pageSource.contains("documentView.addSubview(documentFill)"))
        XCTAssertTrue(pageSource.contains("contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)"))
        XCTAssertFalse(pageSource.contains("static let viewportTopInset: CGFloat = 0"))
        XCTAssertFalse(pageSource.contains("static let viewportTopInset: CGFloat = 52"))
        XCTAssertFalse(pageSource.contains("dashboardPageScrollEdgeHairline"))
        XCTAssertFalse(pageSource.contains("DashboardScrollEdgeHairline"))
        XCTAssertFalse(pageSource.contains("CAGradientLayer"))
        XCTAssertFalse(pageSource.contains("shadowRadius"))
        XCTAssertFalse(pageSource.contains("shadowOffset"))
        XCTAssertFalse(pageSource.contains("compressedContentHeight"))
        XCTAssertFalse(pageSource.contains("arrangedSubviews.filter"))
        XCTAssertFalse(pageSource.contains("content.fittingSize"))
        XCTAssertFalse(pageSource.contains("view.fittingSize.height"))
        XCTAssertFalse(pageSource.contains("content.intrinsicContentSize.height"))
        XCTAssertFalse(pageSource.contains("lastReportedHeight"))
        XCTAssertFalse(pageSource.contains("override func layout()"))
        XCTAssertFalse(pageSource.contains("greaterThanOrEqualTo: contentView.bottomAnchor"))
        XCTAssertFalse(pageSource.contains("lessThanOrEqualTo: contentHost.bottomAnchor"))
        XCTAssertFalse(pageSource.contains("NSStackView(views: [contentHost, documentFill])"))
        XCTAssertFalse(pageSource.contains("firstScrollView(in:"))
        XCTAssertFalse(pageSource.contains("allowedPocketEdges"))
        XCTAssertFalse(pageSource.contains("alwaysShownPocketEdges"))
        XCTAssertFalse(pageSource.contains("scrollPocketStyle"))
        XCTAssertFalse(pageSource.contains("topShadowTopInset"))
        XCTAssertFalse(pageSource.contains("NSScrollPocket"))
        XCTAssertFalse(pageSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(pageSource.contains("preferredSidebarThickness"))
        XCTAssertFalse(pageSource.contains("minimumSidebarThickness"))
        XCTAssertFalse(pageSource.contains("additionalSafeAreaInsets"))
        XCTAssertFalse(pageSource.contains("NSGlassEffectView"))
        XCTAssertFalse(pageSource.contains("NSVisualEffectView"))
        XCTAssertFalse(pageSource.contains("shadowOpacity"))
        XCTAssertFalse(pageSource.contains("titlebarAccessory"))

        XCTAssertTrue(settingsSource.contains("makeSettingsPageContent"))
        XCTAssertTrue(settingsSource.contains("addView(section, in: .top)"))
        XCTAssertTrue(settingsSource.contains("addView(heading, in: .top)"))
        XCTAssertFalse(settingsSource.contains("let viewportTopInset: CGFloat = 52"))
        XCTAssertFalse(settingsSource.contains("NSScrollView()"))
    }

    func testPreTahoeLayoutKeepsTitlebarClearanceWithoutSystemInsetAssumptions() throws {
        let shortPage = DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPageContent([tallFiller(height: 80)]),
            layoutPolicy: .titlebarClearance
        )
        let shortWindow = makeWindow(width: 480, height: 280, hosting: shortPage)
        defer { shortWindow.orderOut(nil) }
        shortWindow.setContentSize(NSSize(width: 480, height: 280))
        shortPage.view.frame = NSRect(x: 0, y: 0, width: 480, height: 280)
        shortWindow.layoutIfNeeded()
        shortPage.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(shortPage.layoutPolicy, .titlebarClearance)
        XCTAssertFalse(shortPage.pageScrollView.automaticallyAdjustsContentInsets)
        XCTAssertEqual(shortPage.pageScrollView.contentInsets.top, 0, accuracy: 0.001)
        XCTAssertEqual(shortPage.pageScrollView.contentInsets.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(shortPage.pageScrollView.scrollerInsets.top, 0, accuracy: 0.001)
        let shortViewport = shortPage.pageScrollView.convert(
            shortPage.pageScrollView.bounds,
            to: shortPage.view
        )
        XCTAssertEqual(
            shortViewport.minY - shortPage.view.bounds.minY,
            DashboardPageScrollLayoutPolicy.preTahoeTitlebarClearanceInset,
            accuracy: 1
        )
        XCTAssertTrue(shortPage.isAtTop)
        XCTAssertEqual(shortPage.scrollOffset, 0, accuracy: 1)
        let shortGeometry = DashboardScrollGeometry(scrollView: shortPage.pageScrollView)
        XCTAssertEqual(shortGeometry.topContentInset, 0, accuracy: 0.001)
        XCTAssertEqual(shortGeometry.restOriginY, shortPage.documentViewForTesting.bounds.minY, accuracy: 1)
        XCTAssertGreaterThan(shortPage.pageScrollView.bounds.height, 1)
        XCTAssertLessThanOrEqual(
            shortPage.documentViewForTesting.bounds.height - shortPage.pageScrollView.bounds.height,
            1
        )

        let tallPage = DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPageContent([tallFiller(height: 1800)]),
            layoutPolicy: .titlebarClearance
        )
        let tallWindow = makeWindow(width: 480, height: 280, hosting: tallPage)
        defer { tallWindow.orderOut(nil) }

        XCTAssertEqual(tallPage.scrollOffset, 0, accuracy: 1)
        XCTAssertTrue(tallPage.isAtTop)
        let tallViewport = tallPage.pageScrollView.convert(
            tallPage.pageScrollView.bounds,
            to: tallPage.view
        )
        XCTAssertEqual(
            tallViewport.minY - tallPage.view.bounds.minY,
            DashboardPageScrollLayoutPolicy.preTahoeTitlebarClearanceInset,
            accuracy: 1
        )
        let firstRow = tallPage.hostedContentForTesting
        let firstRowInPage = firstRow.convert(firstRow.bounds, to: tallPage.view)
        XCTAssertEqual(
            firstRowInPage.minY,
            DashboardPageScrollLayoutPolicy.preTahoeTitlebarClearanceInset,
            accuracy: 1
        )

        tallPage.restoreScrollOffset(140)
        tallWindow.layoutIfNeeded()
        XCTAssertFalse(tallPage.isAtTop)
        XCTAssertEqual(tallPage.scrollOffset, 140, accuracy: 2)

        let geometry = DashboardScrollGeometry(scrollView: tallPage.pageScrollView)
        XCTAssertGreaterThan(geometry.maximumOffset, 140)
        tallPage.restoreScrollOffset(geometry.maximumOffset)
        tallWindow.layoutIfNeeded()
        XCTAssertEqual(tallPage.scrollOffset, geometry.maximumOffset, accuracy: 2)

        let replacement = DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPageContent([tallFiller(height: 1800)]),
            layoutPolicy: .titlebarClearance
        )
        tallWindow.contentViewController = replacement
        tallWindow.layoutIfNeeded()
        replacement.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(replacement.isAtTop)
        XCTAssertEqual(replacement.scrollOffset, 0, accuracy: 1)
        XCTAssertFalse(replacement.pageScrollView.automaticallyAdjustsContentInsets)
    }

    func testDashboardWindowUsesSystemTitlebarInsetsWithoutCustomScrollEdgeOverlay() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
            "Requires macOS 26 AppKit titlebar content insets; 14/15 layout is covered by injected titlebarClearance tests"
        )
        let page = DashboardScrollablePageViewController(
            wrapping: DashboardSettingsComponents.makeSettingsPageContent([tallFiller(height: 1800)]),
            layoutPolicy: .systemScrollEdge
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
        window.displayIfNeeded()
        windowController.contentHost.layoutSubtreeIfNeeded()

        let hostedPage = try XCTUnwrap(windowController.scrollablePageForTesting)
        XCTAssertTrue(hostedPage === page)
        XCTAssertEqual(page.layoutPolicy, .systemScrollEdge)
        XCTAssertTrue(page.pageScrollView.automaticallyAdjustsContentInsets)
        XCTAssertEqual(page.layoutPolicy.viewportTopInset, 0, accuracy: 0.001)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .automatic)
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        XCTAssertEqual(splitController.splitViewItems[0].titlebarSeparatorStyle, .none)
        XCTAssertEqual(
            try XCTUnwrap(splitController.contentSplitViewItem).titlebarSeparatorStyle,
            .automatic
        )
        if #available(macOS 26.0, *) {
            XCTAssertEqual(
                try XCTUnwrap(splitController.contentSplitViewItem)
                    .topAlignedAccessoryViewControllers.count,
                0
            )
        }

        let viewportFrameInPage = page.pageScrollView.convert(
            page.pageScrollView.bounds,
            to: page.view
        )
        XCTAssertEqual(viewportFrameInPage.minY - page.view.bounds.minY, 0, accuracy: 1)

        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titlebarHeight, 1)
        XCTAssertEqual(page.pageScrollView.contentInsets.top, titlebarHeight, accuracy: 1)
        XCTAssertEqual(page.pageScrollView.contentInsets.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(page.clipViewForTesting.contentInsets.top, titlebarHeight, accuracy: 1)

        XCTAssertTrue(page.isAtTop)
        XCTAssertEqual(page.scrollOffset, 0, accuracy: 1)
        let restVisible = page.clipViewForTesting.convert(
            page.clipViewForTesting.bounds,
            to: page.documentViewForTesting
        )
        XCTAssertEqual(
            restVisible.minY,
            page.documentViewForTesting.bounds.minY - page.pageScrollView.contentInsets.top,
            accuracy: 1
        )

        page.restoreScrollOffset(140)
        window.layoutIfNeeded()
        XCTAssertFalse(page.isAtTop)
        XCTAssertEqual(page.scrollOffset, 140, accuracy: 2)

        window.setContentSize(NSSize(width: 880, height: 720))
        window.layoutIfNeeded()
        page.view.layoutSubtreeIfNeeded()
        let resizedGeometry = DashboardScrollGeometry(scrollView: page.pageScrollView)
        XCTAssertGreaterThan(page.pageScrollView.contentInsets.top, 0)
        XCTAssertGreaterThanOrEqual(page.scrollOffset, 0)
        XCTAssertLessThanOrEqual(
            page.scrollOffset,
            resizedGeometry.maximumOffset + 1
        )
        XCTAssertEqual(
            page.scrollOffset,
            resizedGeometry.clampedVisualOffset(page.scrollOffset),
            accuracy: 2
        )

        page.restoreScrollOffset(0)
        window.layoutIfNeeded()
        XCTAssertTrue(page.isAtTop)
        XCTAssertEqual(page.scrollOffset, 0, accuracy: 1)

        XCTAssertNil(firstDescendant(of: page.view, as: NSVisualEffectView.self))
        XCTAssertEqual(
            descendants(of: page.view).compactMap { $0 as? NSScrollView }.count,
            1
        )
        XCTAssertTrue(
            descendants(of: page.view).allSatisfy { view in
                view.layer?.shadowOpacity ?? 0 == 0
            }
        )
        XCTAssertTrue(windowController.accessoryHostForTesting.mountedKind == .none)
    }

    func testOfficialDashboardPagesDoNotPublishTopAccessory() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let dashboardRoot = repositoryRoot.appendingPathComponent("Sources/UI/Dashboard")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: dashboardRoot,
                includingPropertiesForKeys: nil
            )
        )
        var pageSources: [URL] = []
        var dashboardSources: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            dashboardSources.append(item)
            if item.path.contains("/Pages/") {
                pageSources.append(item)
            }
        }
        XCTAssertFalse(pageSources.isEmpty)

        for url in pageSources {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains("DashboardPageTopAccessoryProviding"),
                "Official page \(url.lastPathComponent) must not invent accessory ownership"
            )
            XCTAssertFalse(source.contains("dashboardPageTopAccessory"))
            XCTAssertFalse(source.contains("NSSplitViewItemAccessoryViewController"))
            XCTAssertFalse(source.contains("preferredScrollEdgeEffectStyle"))
            XCTAssertFalse(
                source.contains("NSSearchField("),
                "Official page \(url.lastPathComponent) has no floating search chrome"
            )
        }

        var protocolAdopters: [String] = []
        for url in dashboardSources {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            if name == "DashboardPageTopAccessory.swift" {
                XCTAssertTrue(source.contains("protocol DashboardPageTopAccessoryProviding"))
                continue
            }
            if source.contains("DashboardPageTopAccessoryProviding") {
                protocolAdopters.append(name)
            }
        }
        XCTAssertEqual(
            protocolAdopters,
            ["DashboardAccessoryHarnessController.swift"],
            "Only the non-production harness may adopt page top accessory ownership"
        )
    }

    func testPublicScrollEdgeTriggerConditionsOnMacOS26() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
            "Public scroll-edge style APIs and split-item accessories require macOS 26"
        )

        let chrome = ScrollEdgeProbeAccessoryController()
        var chromePage: ScrollEdgeChromePage?
        let dashboard = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { section in
                    let content = DashboardSettingsComponents.makeSettingsPageContent(
                        [self.tallFiller(height: 1800)]
                    )
                    if section == .menu {
                        let page = ScrollEdgeChromePage(
                            wrapping: content,
                            accessory: .contentSplitItem(viewController: chrome)
                        )
                        chromePage = page
                        return page
                    }
                    return DashboardScrollablePageViewController(
                        wrapping: content,
                        layoutPolicy: .systemScrollEdge
                    )
                },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { dashboard.teardown() }
        dashboard.open(initialSection: .general)
        let dashboardWindow = try XCTUnwrap(dashboard.window)
        dashboardWindow.setContentSize(NSSize(width: 880, height: 620))
        dashboardWindow.layoutIfNeeded()
        dashboardWindow.displayIfNeeded()

        let dashboardPage = try XCTUnwrap(dashboard.scrollablePageForTesting)
        let dashboardSplit = try XCTUnwrap(
            dashboardWindow.contentViewController as? DashboardSplitViewController
        )
        let dashboardContentItem = try XCTUnwrap(dashboardSplit.contentSplitViewItem)
        XCTAssertEqual(dashboard.accessoryHostForTesting.mountedKind, .none)
        XCTAssertTrue(dashboardWindow.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertEqual(
            DashboardToolbarController.defaultItemIdentifiers,
            [
                .flexibleSpace,
                .toggleSidebar,
                .sidebarTrackingSeparator,
                DashboardToolbarController.searchItemIdentifier
            ]
        )
        XCTAssertEqual(
            dashboardWindow.toolbar?.items.map(\.itemIdentifier),
            DashboardToolbarController.defaultItemIdentifiers
        )
        XCTAssertTrue(dashboardPage.pageScrollView.automaticallyAdjustsContentInsets)
        XCTAssertGreaterThan(dashboardPage.pageScrollView.contentInsets.top, 1)
        dashboardPage.restoreScrollOffset(120)
        dashboardWindow.layoutIfNeeded()
        XCTAssertGreaterThan(dashboardPage.scrollOffset, 1)
        XCTAssertEqual(dashboard.accessoryHostForTesting.mountedKind, .none)

        guard #available(macOS 26.0, *) else { return }
        XCTAssertEqual(dashboardContentItem.topAlignedAccessoryViewControllers.count, 0)

        dashboard.showSection(.menu)
        dashboardWindow.layoutIfNeeded()
        dashboardWindow.displayIfNeeded()
        XCTAssertEqual(dashboard.accessoryHostForTesting.mountedKind, .contentSplitItem)
        XCTAssertEqual(dashboardContentItem.topAlignedAccessoryViewControllers.count, 1)
        let accessory = try XCTUnwrap(
            dashboard.accessoryHostForTesting.contentSplitItemAccessoryForTesting
                as? NSSplitViewItemAccessoryViewController
        )
        XCTAssertTrue(dashboardContentItem.topAlignedAccessoryViewControllers.contains(accessory))
        XCTAssertGreaterThan(chrome.view.fittingSize.height, 1)
        let mountedChrome = try XCTUnwrap(chromePage)
        XCTAssertTrue(mountedChrome.scrollPage.pageScrollView.automaticallyAdjustsContentInsets)
        XCTAssertGreaterThan(mountedChrome.scrollPage.pageScrollView.contentInsets.top, 1)
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = NSScrollEdgeEffectStyle.hard
            XCTAssertIdentical(
                accessory.preferredScrollEdgeEffectStyle,
                NSScrollEdgeEffectStyle.hard
            )
        }
        mountedChrome.scrollPage.restoreScrollOffset(120)
        dashboardWindow.layoutIfNeeded()
        XCTAssertGreaterThan(mountedChrome.scrollPage.scrollOffset, 1)
        XCTAssertEqual(dashboardContentItem.topAlignedAccessoryViewControllers.count, 1)

        dashboard.showSection(.general)
        dashboardWindow.layoutIfNeeded()
        XCTAssertEqual(dashboard.accessoryHostForTesting.mountedKind, .none)
        XCTAssertTrue(dashboardContentItem.topAlignedAccessoryViewControllers.isEmpty)
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

private final class ScrollEdgeChromePage: NSViewController, DashboardPageTopAccessoryProviding {
    let dashboardPageTopAccessory: DashboardPageTopAccessory
    let scrollPage: DashboardScrollablePageViewController

    init(wrapping content: NSView, accessory: DashboardPageTopAccessory) {
        dashboardPageTopAccessory = accessory
        scrollPage = DashboardScrollablePageViewController(
            wrapping: content,
            layoutPolicy: .systemScrollEdge
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        addChild(scrollPage)
        view = scrollPage.view
    }
}

private final class ScrollEdgeProbeAccessoryController: NSViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let strip = ScrollEdgeProbeAccessoryView()
        let label = NSTextField(labelWithString: "Scroll-edge probe")
        label.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: strip.centerYAnchor)
        ])
        view = strip
    }
}

private final class ScrollEdgeProbeAccessoryView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }
}
