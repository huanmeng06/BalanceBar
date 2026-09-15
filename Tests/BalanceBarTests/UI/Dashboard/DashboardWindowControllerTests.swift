import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardWindowControllerTests: XCTestCase {
    func testSidebarChromeSourceDoesNotInstallCustomGlassPanel() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func makeSidebar(titlebarHeight: CGFloat) -> NSView {"))
        let end = try XCTUnwrap(
            source.range(of: "var sourceListForTesting: DashboardSourceListController? { sourceListController }")
        )
        let makeSidebarSource = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(makeSidebarSource.contains("DashboardSourceListController"))
        XCTAssertFalse(makeSidebarSource.contains("NSGlassEffectView"))
        XCTAssertFalse(makeSidebarSource.contains("NSClassFromString"))
        XCTAssertFalse(makeSidebarSource.contains("makeDashboardGlassEffectView"))
        XCTAssertFalse(makeSidebarSource.contains("panelShadow"))
        XCTAssertFalse(makeSidebarSource.contains("NSVisualEffectView"))
        XCTAssertFalse(makeSidebarSource.contains("cornerRadius"))
        XCTAssertFalse(makeSidebarSource.contains("shadowOpacity"))
        XCTAssertFalse(makeSidebarSource.contains("material = .sidebar"))
    }

    func testToolbarControllerUsesPublicSystemSidebarItems() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardToolbarController.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".flexibleSpace"))
        XCTAssertTrue(source.contains(".toggleSidebar"))
        XCTAssertTrue(source.contains(".sidebarTrackingSeparator"))
        XCTAssertTrue(source.contains("allowsUserCustomization = false"))
        XCTAssertTrue(source.contains("autosavesConfiguration = false"))
        XCTAssertFalse(source.contains("toolbarNavigationalItemIdentifiers"))
        XCTAssertFalse(source.contains("isNavigational"))
        XCTAssertFalse(source.contains("item.isHidden"))
        XCTAssertFalse(source.contains("sidebarCollapseObservation"))
        XCTAssertFalse(source.contains("toolbarWillAddItem"))
        XCTAssertFalse(source.contains("#selector("))
        XCTAssertFalse(source.contains("setValue("))
        XCTAssertFalse(source.contains("forKey:"))
        XCTAssertFalse(source.contains("NSClassFromString"))
        XCTAssertFalse(source.contains("NSGlassEffectView"))
        XCTAssertFalse(source.contains("NSView("))
    }

    func testWindowEnablesNativeZoomAndStaysResizable() throws {
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
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
        XCTAssertTrue(window.standardWindowButton(.zoomButton)?.isEnabled ?? false)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
    }

    func testGeneralNavigationShowsAndHidesUpdateBadgeWithUpdateState() throws {
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }

        _ = NSApplication.shared
        controller.setShowsUpdateAvailableBadge(true)
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let generalRow = try XCTUnwrap(sourceList.row(for: .general))
        let cell = try XCTUnwrap(
            sourceList.outlineView.view(atColumn: 0, row: generalRow, makeIfNecessary: true)
                as? DashboardSourceListCellView
        )
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(cell.updateBadgeView.isHidden)
        let titleLabel = try XCTUnwrap(cell.textField)
        XCTAssertGreaterThan(cell.updateBadgeView.frame.minX, titleLabel.frame.maxX)
        XCTAssertLessThanOrEqual(cell.updateBadgeView.frame.maxX, cell.bounds.maxX)

        controller.setShowsUpdateAvailableBadge(false)
        XCTAssertTrue(cell.updateBadgeView.isHidden)

        controller.setShowsUpdateAvailableBadge(true)
        controller.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let rebuilt = try XCTUnwrap(controller.sourceListForTesting)
        let rebuiltRow = try XCTUnwrap(rebuilt.row(for: .general))
        let rebuiltCell = try XCTUnwrap(
            rebuilt.outlineView.view(atColumn: 0, row: rebuiltRow, makeIfNecessary: true)
                as? DashboardSourceListCellView
        )
        XCTAssertFalse(rebuiltCell.updateBadgeView.isHidden)
        XCTAssertTrue(rebuilt.outlineView !== sourceList.outlineView)
    }

    func testMenuBarSettingsFittingWidthFollowsLocalization() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        var fittingWidths: [AppLanguage: CGFloat] = [:]
        for language in [
            AppLanguage.simplifiedChinese,
            .english,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese
        ] {
            AppLanguage.selected = language
            let appDelegate = AppDelegate(
                repository: CCSwitchRepository(
                    databaseURL: URL(fileURLWithPath: "/nonexistent/issue-165-\(language.rawValue).db")
                )
            )
            defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

            let window = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menuBar)
            )
            window.setContentSize(NSSize(width: 800, height: 540))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let page = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.pageContainerForTesting.currentPage?.view
            )
            XCTAssertTrue(
                page === appDelegate.dashboardCompositionForTesting.contentHost.subviews.first
            )
            fittingWidths[language] = page.fittingSize.width
        }

        let simplifiedChineseFittingWidth = try XCTUnwrap(fittingWidths[.simplifiedChinese])
        let englishFittingWidth = try XCTUnwrap(fittingWidths[.english])
        let japaneseFittingWidth = try XCTUnwrap(fittingWidths[.japanese])
        XCTAssertGreaterThan(
            englishFittingWidth,
            simplifiedChineseFittingWidth + 1,
            "English should retain enough fitting width for its localized copy"
        )
        XCTAssertGreaterThan(
            japaneseFittingWidth,
            simplifiedChineseFittingWidth + 1,
            "Japanese should retain enough fitting width for its localized copy"
        )
    }

    func testOpenRestoresInitialSectionAndScrollThenAFreshOpenStaysOnGeneral() throws {
        func textFields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { child -> [NSTextField] in
                ([child].compactMap { $0 as? NSTextField }) + textFields(in: child)
            }
        }
        func makeTallPage() -> NSView {
            let filler = NSView()
            filler.translatesAutoresizingMaskIntoConstraints = false
            filler.heightAnchor.constraint(equalToConstant: 1800).isActive = true
            let fpsField = NSTextField()
            fpsField.translatesAutoresizingMaskIntoConstraints = false
            fpsField.identifier = NSUserInterfaceItemIdentifier(
                DashboardMenuBarPage.animationFrameRateIdentifier
            )
            fpsField.isEditable = true
            fpsField.isSelectable = true
            fpsField.stringValue = "30"
            fpsField.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return DashboardSettingsComponents.makeSettingsPageContent([
                DashboardSettingsComponents.makeSettingsSection("Tall", rows: [filler, fpsField])
            ])
        }

        let restoring = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardScrollablePageViewController(wrapping: makeTallPage()) },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer {
            restoring.teardown()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        restoring.open(initialSection: .menuBar, scrollOffsetY: 160)
        let window = try XCTUnwrap(restoring.window)
        window.setContentSize(NSSize(width: 880, height: 620))
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        restoring.contentHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        restoring.restorePageScrollOffsetY(160)

        XCTAssertEqual(restoring.section, .menuBar)
        XCTAssertEqual(restoring.pageScrollOffsetY(), 160, accuracy: 2)
        let fpsField = try XCTUnwrap(
            textFields(in: restoring.contentHost).first {
                $0.identifier?.rawValue == DashboardMenuBarPage.animationFrameRateIdentifier
            }
        )
        XCTAssertTrue(fpsField.isEditable)
        XCTAssertNil(
            fpsField.currentEditor(),
            "restore-open must not leave the FPS field selected"
        )
        XCTAssertFalse(
            window.firstResponder === fpsField,
            "restore-open must not make the FPS field first responder"
        )
        if window.makeFirstResponder(fpsField) {
            restoring.restorePageScrollOffsetY(160)
            XCTAssertNil(fpsField.currentEditor())
            XCTAssertFalse(window.firstResponder === fpsField)
        }
        XCTAssertTrue(fpsField.isEditable)

        let fresh = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardScrollablePageViewController(wrapping: makeTallPage()) },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer {
            fresh.teardown()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        fresh.open()
        XCTAssertEqual(fresh.section, .general)
    }

    func testRepeatedStartAndOpenKeepOneObserverMonitorAndWindow() {
        var shownPageCount = 0
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
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
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
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
        XCTAssertNil(controller.sourceListForTesting?.selectedSection())
        XCTAssertEqual(controller.sourceListForTesting?.outlineView.selectedRow, -1)
        XCTAssertGreaterThanOrEqual(preparedPageCount, 3)
        XCTAssertEqual(controller.windowCreationCount, 1)
        XCTAssertEqual(controller.mouseMonitorInstallCount, 1)

        controller.teardown()
    }

    func testTeardownIsIdempotentAndStopsWindowDelegateOwnership() {
        var closeCount = 0
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
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

    func testReplacePageSourceUsesChildControllerContainment() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "private func replacePage(makePage: () -> NSViewController) {")
        )
        let end = try XCTUnwrap(source.range(of: "private func installMouseMonitor()"))
        let replacePageSource = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(replacePageSource.contains("pageContainer.replacePage"))
        XCTAssertFalse(replacePageSource.contains("contentHost.subviews.forEach"))
        XCTAssertFalse(replacePageSource.contains("removeFromSuperview()"))
        XCTAssertFalse(replacePageSource.contains("addSubview"))
    }

    func testSectionAndProviderNavigationOwnsOneChildController() throws {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true)
        ]
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { section in
                    let page = DashboardHostedPageViewController()
                    page.view.identifier = NSUserInterfaceItemIdentifier("section-\(section.rawValue)")
                    return page
                },
                makeProviderPage: { choice in
                    let page = DashboardHostedPageViewController()
                    page.view.identifier = NSUserInterfaceItemIdentifier("provider-\(choice.id)")
                    return page
                },
                providerChoices: { choices },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let container = controller.pageContainerForTesting
        XCTAssertTrue(splitController.contentController === container)

        let generalPage = try XCTUnwrap(container.currentPage)
        XCTAssertTrue(generalPage.parent === container)
        XCTAssertEqual(container.children.count, 1)
        XCTAssertTrue(container.children.first === generalPage)
        XCTAssertTrue(generalPage.view === container.view.subviews.first)
        XCTAssertEqual(generalPage.view.identifier?.rawValue, "section-\(DashboardSection.general.rawValue)")

        controller.showSection(.menu)
        let menuPage = try XCTUnwrap(container.currentPage)
        XCTAssertFalse(menuPage === generalPage)
        XCTAssertNil(generalPage.parent)
        XCTAssertNil(generalPage.view.superview)
        XCTAssertTrue(menuPage.parent === container)
        XCTAssertEqual(container.children.count, 1)
        XCTAssertTrue(container.children.first === menuPage)
        XCTAssertEqual(menuPage.view.identifier?.rawValue, "section-\(DashboardSection.menu.rawValue)")

        controller.showProvider("current")
        let providerPage = try XCTUnwrap(container.currentPage)
        XCTAssertNil(menuPage.parent)
        XCTAssertNil(menuPage.view.superview)
        XCTAssertTrue(providerPage.parent === container)
        XCTAssertEqual(container.children.count, 1)
        XCTAssertEqual(providerPage.view.identifier?.rawValue, "provider-current")

        controller.teardown()
        XCTAssertNil(container.currentPage)
        XCTAssertTrue(container.children.isEmpty)
        XCTAssertNil(providerPage.parent)
        XCTAssertNil(providerPage.view.superview)
    }
}

@MainActor
final class DashboardNativeUIBaselineTests: XCTestCase {
    func testWindowChromeMatchesCurrentNativeBaseline() throws {
        let controller = makeController()
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let contentView = try XCTUnwrap(window.contentView)
        XCTAssertEqual(contentView.bounds.width, 880, accuracy: 1)
        XCTAssertEqual(contentView.bounds.height, 620, accuracy: 1)
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        XCTAssertTrue(window.contentViewController is NSSplitViewController)
        XCTAssertEqual(splitController.splitViewItems.count, 2)
        let sidebarItem = splitController.splitViewItems[0]
        let contentItem = splitController.splitViewItems[1]
        XCTAssertTrue(sidebarItem.viewController === splitController.sidebarController)
        XCTAssertTrue(contentItem.viewController === splitController.contentController)
        XCTAssertTrue(splitController.contentController is DashboardPageContainerViewController)
        XCTAssertTrue(splitController.contentController === controller.pageContainerForTesting)
        XCTAssertEqual(sidebarItem.behavior, .sidebar)
        XCTAssertNotEqual(contentItem.behavior, .sidebar)
        XCTAssertTrue(splitController.splitView.isVertical)
        XCTAssertEqual(splitController.splitView.dividerStyle, .thin)
        XCTAssertTrue(sidebarItem.canCollapse)
        XCTAssertFalse(sidebarItem.canCollapseFromWindowResize)
        XCTAssertTrue(sidebarItem.allowsFullHeightLayout)
        XCTAssertGreaterThanOrEqual(
            sidebarItem.minimumThickness,
            DashboardSplitViewController.minimumSidebarThickness
        )
        XCTAssertLessThan(
            sidebarItem.minimumThickness,
            DashboardSplitViewController.preferredSidebarThickness
        )
        XCTAssertEqual(
            sidebarItem.maximumThickness,
            DashboardSplitViewController.maximumSidebarThickness,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            sidebarItem.maximumThickness,
            DashboardSplitViewController.preferredSidebarThickness
        )
        XCTAssertFalse(
            abs(sidebarItem.minimumThickness - 216) < 0.001
                && abs(sidebarItem.maximumThickness - 216) < 0.001,
            "Sidebar thickness must not remain locked at min=max=216"
        )
        XCTAssertGreaterThan(sidebarItem.holdingPriority.rawValue, contentItem.holdingPriority.rawValue)
        XCTAssertLessThan(sidebarItem.holdingPriority.rawValue, 900)
        XCTAssertEqual(contentItem.holdingPriority, .defaultLow)
        XCTAssertEqual(sidebarItem.viewController.view.frame.width, 216, accuracy: 1)
        XCTAssertGreaterThan(contentItem.viewController.view.frame.width, 0)
        XCTAssertTrue(sidebarItem.viewController.view.isDescendant(of: splitController.splitView))
        XCTAssertTrue(contentItem.viewController.view.isDescendant(of: splitController.splitView))
        XCTAssertGreaterThan(
            splitController.splitView.dividerThickness,
            0,
            "A 0pt divider makes AppKit propose a window-wide hit rect; use native split-view geometry"
        )
        XCTAssertTrue(
            splitController.splitView(
                splitController.splitView,
                additionalEffectiveRectOfDividerAt: 0
            ).isEmpty,
            "Do not add a custom extra divider hit rect"
        )

        let backdrop = try XCTUnwrap(splitController.view as? DashboardContentRootView)
        XCTAssertTrue(contentView === backdrop)
        XCTAssertEqual(backdrop.material, .underWindowBackground)
        XCTAssertEqual(backdrop.blendingMode, .behindWindow)
        XCTAssertEqual(backdrop.state, .active)
        XCTAssertTrue(splitController.view.subviews.contains(splitController.contentSurface))
        XCTAssertTrue(splitController.view.subviews.contains(splitController.splitView))
        XCTAssertLessThan(
            try XCTUnwrap(splitController.view.subviews.firstIndex(of: splitController.contentSurface)),
            try XCTUnwrap(splitController.view.subviews.firstIndex(of: splitController.splitView))
        )
        XCTAssertEqual(
            splitController.contentSurface.identifier,
            DashboardSplitViewController.contentSurfaceIdentifier
        )
        XCTAssertEqual(
            splitController.contentSurface.layer?.backgroundColor?.alpha ?? -1,
            dashboardUsesDarkAppearance ? 0.20 : 0.82,
            accuracy: 0.01
        )
        XCTAssertFalse(
            sidebarItem.viewController.view.constraints.contains {
                $0.firstAttribute == .width && $0.constant == 216
            },
            "Sidebar width must come from NSSplitViewItem thickness, not a leftover widthAnchor"
        )
        XCTAssertEqual(window.minSize.width, 800, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 540)
        XCTAssertEqual(
            window.minSize.height,
            560,
            accuracy: 1,
            "Unified toolbar currently raises the coded 540pt frame minimum to 560pt"
        )
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.toolbarStyle, .unified)
        try assertNativeDashboardToolbar(window)
        XCTAssertNil(window.appearance)
        XCTAssertFalse(window.isMovableByWindowBackground)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let miniaturizeButton = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let zoomButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        XCTAssertFalse(closeButton.isHidden)
        XCTAssertFalse(miniaturizeButton.isHidden)
        XCTAssertFalse(zoomButton.isHidden)
        XCTAssertTrue(closeButton.isEnabled)
        XCTAssertTrue(miniaturizeButton.isEnabled)
        XCTAssertTrue(zoomButton.isEnabled)
        XCTAssertLessThan(closeButton.frame.minX, miniaturizeButton.frame.minX)
        XCTAssertLessThan(miniaturizeButton.frame.minX, zoomButton.frame.minX)

        XCTAssertEqual(try XCTUnwrap(sidebarWidth(in: window)), 216, accuracy: 1)
        XCTAssertEqual(contentView.subviews, [splitController.contentSurface, splitController.splitView])
        XCTAssertTrue(contentView is DashboardContentRootView)
        XCTAssertFalse(contentView.mouseDownCanMoveWindow)
        assertSidebarHostsSourceListWithoutCustomMaterialWrapper(in: window)
    }

    func testSidebarUsesSplitItemChromeInsteadOfCustomGlassOrVisualEffectWrapper() throws {
        let controller = makeController()
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        assertSidebarHostsSourceListWithoutCustomMaterialWrapper(in: window)
        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertEqual(sourceList.outlineView.style, .sourceList)
        XCTAssertEqual(sourceList.selectedSection(), .general)
        XCTAssertEqual(sourceList.outlineView.backgroundColor, .clear)
        XCTAssertFalse(sourceList.scrollView.drawsBackground)
    }

    func testContentSurfaceTintFollowsBaselineAppearancesWithoutDarkCompensation() throws {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)

        let cases: [(NSAppearance.Name, CGFloat)] = [
            (.aqua, 0.82),
            (.darkAqua, 0.20)
        ]
        for (name, expectedAlpha) in cases {
            let appearance = NSAppearance(named: name)
            NSApp.appearance = appearance
            window.appearance = appearance
            controller.rebuild()
            window.layoutIfNeeded()

            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController
            )
            let backdrop = try XCTUnwrap(splitController.view as? DashboardContentRootView)
            XCTAssertEqual(backdrop.material, .underWindowBackground)
            XCTAssertEqual(backdrop.blendingMode, .behindWindow)
            XCTAssertEqual(
                splitController.contentSurface.layer?.backgroundColor?.alpha ?? -1,
                expectedAlpha,
                accuracy: 0.01,
                "Content surface alpha mismatch for \(name.rawValue)"
            )
            XCTAssertEqual(try XCTUnwrap(sidebarWidth(in: window)), 216, accuracy: 1)
            XCTAssertTrue(splitController.splitViewItems[0].canCollapse)
            XCTAssertEqual(
                try XCTUnwrap(sidebarWidth(in: window)),
                DashboardSplitViewController.preferredSidebarThickness,
                accuracy: 1
            )
        }
    }

    func testSidebarSplitItemUsesNativeSizingInsteadOfLockedThickness() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let sidebarItem = splitController.splitViewItems[0]
        let contentItem = splitController.splitViewItems[1]
        XCTAssertEqual(sidebarItem.behavior, .sidebar)
        XCTAssertNotEqual(contentItem.behavior, .sidebar)
        XCTAssertTrue(splitController.splitView.isVertical)
        XCTAssertEqual(splitController.splitView.dividerStyle, .thin)
        XCTAssertFalse(contentItem.canCollapse)
        XCTAssertFalse(
            hasFixedWidthConstraint(in: sidebarItem.viewController.view, constant: 216),
            "Sidebar width must come from NSSplitViewItem thickness, not a leftover widthAnchor"
        )
        XCTAssertGreaterThan(
            sidebarItem.holdingPriority.rawValue,
            contentItem.holdingPriority.rawValue
        )
        XCTAssertEqual(contentItem.holdingPriority, .defaultLow)

        let originalWidth = try XCTUnwrap(sidebarWidth(in: window))
        let requestedThickness = originalWidth + 24
        splitController.splitView.setPosition(requestedThickness, ofDividerAt: 0)
        window.layoutIfNeeded()
        let resizedWidth = try XCTUnwrap(sidebarWidth(in: window))
        XCTAssertGreaterThan(
            abs(resizedWidth - originalWidth),
            1,
            "Native divider positioning must be able to change sidebar thickness (was \(originalWidth), requested \(requestedThickness), got \(resizedWidth))"
        )
        XCTAssertGreaterThanOrEqual(resizedWidth, sidebarItem.minimumThickness - 1)
        XCTAssertLessThanOrEqual(resizedWidth, sidebarItem.maximumThickness + 1)
        assertSplitPanesDoNotOverlap(in: window)

        let splitView = splitController.splitView
        let sidebarInSplit = sidebarItem.viewController.view.convert(
            sidebarItem.viewController.view.bounds,
            to: splitView
        )
        let additional = splitController.splitView(splitView, additionalEffectiveRectOfDividerAt: 0)
        XCTAssertTrue(additional.isEmpty)
        XCTAssertGreaterThan(splitView.dividerThickness, 0)
        XCTAssertLessThan(
            sidebarInSplit.maxX + 20,
            splitView.bounds.maxX - 40,
            "Divider geometry must stay at the sidebar/content boundary, not the window trailing edge"
        )

        let originalContentSize = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: 1100, height: originalContentSize.height))
        window.layoutIfNeeded()
        XCTAssertEqual(
            try XCTUnwrap(sidebarWidth(in: window)),
            resizedWidth,
            accuracy: 2,
            "Window resize should keep the user-adjusted sidebar width"
        )
        XCTAssertGreaterThan(contentItem.viewController.view.frame.width, 0)
        assertSplitPanesDoNotOverlap(in: window)
    }

    func testSidebarAndContentFramesStayValidAcrossWindowSizes() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        let originalHeight = window.contentRect(forFrameRect: window.frame).height

        for width in [800, 880, 1100, 800, 1100, 880] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: originalHeight))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            XCTAssertEqual(window.contentView?.bounds.width ?? -1, width, accuracy: 1)
            XCTAssertEqual(
                try XCTUnwrap(sidebarWidth(in: window)),
                DashboardSplitViewController.preferredSidebarThickness,
                accuracy: 2,
                "Default sidebar width should hold near 216pt at content width \(width)"
            )
            assertSplitPanesDoNotOverlap(in: window)
        }
    }

    func testSidebarNativeCollapsePreservesNavigationAndSelection() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let sidebarItem = splitController.splitViewItems[0]
        XCTAssertTrue(splitController.splitView.isVertical)
        XCTAssertTrue(sidebarItem.canCollapse)
        XCTAssertFalse(sidebarItem.isCollapsed)

        controller.showSection(.menuBar)
        window.layoutIfNeeded()
        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)

        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()
        XCTAssertTrue(sidebarItem.isCollapsed)
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertTrue(
            controller.sourceListForTesting === sourceList,
            "Collapse must not rebuild sidebar navigation controls"
        )
        XCTAssertTrue(controller.sourceListForTesting?.outlineView === outline)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)

        splitController.toggleSidebar(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(
            sidebarItem.isCollapsed,
            "NSSplitViewController.toggleSidebar(_:) must expand a collapsed sidebar"
        )
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertTrue(controller.sourceListForTesting === sourceList)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)

        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        XCTAssertFalse(sidebarItem.isCollapsed)
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertTrue(controller.sourceListForTesting === sourceList)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        assertSidebarSelection(in: window, selected: .menuBar)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(sidebarWidth(in: window)),
            sidebarItem.minimumThickness - 1
        )
        assertSplitPanesDoNotOverlap(in: window)
    }

    func testNativeToolbarUsesSystemSidebarItemsWithoutCustomFillers() throws {
        let controller = makeController()
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try assertNativeDashboardToolbar(window)

        controller.showSection(.menuBar)
        window.layoutIfNeeded()
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let sidebarItem = splitController.splitViewItems[0]
        XCTAssertFalse(sidebarItem.isCollapsed)
        XCTAssertEqual(controller.sourceListForTesting?.selectedSection(), .menuBar)

        XCTAssertNotNil(
            window.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }
        )

        splitController.toggleSidebar(nil)
        window.layoutIfNeeded()
        XCTAssertTrue(sidebarItem.isCollapsed)
        XCTAssertEqual(controller.section, .menuBar)
        XCTAssertEqual(controller.sourceListForTesting?.selectedSection(), .menuBar)

        splitController.toggleSidebar(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(sidebarItem.isCollapsed)
        XCTAssertEqual(controller.sourceListForTesting?.selectedSection(), .menuBar)
        try assertNativeDashboardToolbar(window)

        controller.rebuild()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try assertNativeDashboardToolbar(window)
        XCTAssertTrue(window.contentViewController is DashboardSplitViewController)
        XCTAssertTrue(
            window.toolbar?.delegate is DashboardToolbarController,
            "rebuild must keep DashboardToolbarController as the single toolbar owner"
        )
    }

    func testSidebarSelectionAndProviderClearingMatchCurrentNativeBaseline() throws {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let controller = makeController(providerChoices: choices)
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.section, .general)
        XCTAssertNil(controller.selectedProviderID)
        assertSidebarSelection(in: window, selected: .general)

        for section in DashboardSection.allCases {
            controller.showSection(section)
            XCTAssertEqual(controller.section, section)
            XCTAssertNil(controller.selectedProviderID)
            XCTAssertEqual(window.title, section.title)
            assertSidebarSelection(in: window, selected: section)
        }

        controller.showProvider("other")
        XCTAssertEqual(controller.selectedProviderID, "other")
        XCTAssertEqual(window.title, "Other")
        assertSidebarSelection(in: window, selected: nil)
    }

    func testRefreshIsAGeneralCardRatherThanASidebarDestination() throws {
        XCTAssertEqual(
            DashboardSection.allCases,
            [.general, .menuBar, .menu, .advanced, .about]
        )
        XCTAssertNil(DashboardSection(rawValue: 5))

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-383-refresh-card.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let labels = textFields(in: try XCTUnwrap(window.contentView)).map(\.stringValue)
        XCTAssertTrue(labels.contains(tr(.keyDashboardGeneralAndRefreshPagesRefresh)))
        XCTAssertFalse(labels.contains(tr(.keyDashboardGeneralAndRefreshPagesRefreshSettings)))
        let outline = try XCTUnwrap(sourceListOutline(in: window))
        let sections = sidebarSections(in: outline)
        XCTAssertEqual(sections, DashboardSection.allCases)
        XCTAssertFalse(sections.contains { $0.rawValue == 5 })
        XCTAssertFalse(
            (0..<outline.numberOfRows).contains { row in
                guard let node = outline.item(atRow: row) as? DashboardSidebarNode else { return false }
                return node.title == tr(.keyDashboardGeneralAndRefreshPagesRefresh)
                    || node.title == tr(.keyDashboardGeneralAndRefreshPagesRefreshSettings)
            }
        )
    }

    func testRepresentativePagesKeepCurrentScrollHostsAndAboutFocusContract() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-383-pages.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )

        for section in [DashboardSection.general, .menuBar, .menu, .advanced] {
            appDelegate.dashboardCompositionForTesting.showSection(section)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let page = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.pageContainerForTesting.currentPage?.view
            )
            XCTAssertTrue(
                page === appDelegate.dashboardCompositionForTesting.contentHost.subviews.first
            )
            let scrollView = try XCTUnwrap(
                firstDescendant(of: page, as: NSScrollView.self),
                "Missing settings scroll view for \(section)"
            )
            XCTAssertTrue(scrollView.hasVerticalScroller)
            XCTAssertFalse(scrollView.hasHorizontalScroller)
            XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
            XCTAssertEqual(scrollView.contentInsets.top, 0, accuracy: 0.001)
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)
            XCTAssertEqual(viewportFrameInPage.minY - page.bounds.minY, 52, accuracy: 1)
        }

        appDelegate.dashboardCompositionForTesting.showSection(.about)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let aboutPage = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.pageContainerForTesting.currentPage?.view
        )
        XCTAssertNil(
            firstDescendant(of: aboutPage, as: NSScrollView.self),
            "About is a centered identity page, not a settings scroll host"
        )
        let githubButton = try XCTUnwrap(
            firstDescendant(of: aboutPage, as: DashboardAboutGitHubButton.self)
        )
        XCTAssertEqual(githubButton.focusRingType, .none)
        XCTAssertEqual(githubButton.accessibilityRole(), .button)

        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true)
        ]
        let providerController = makeController(providerChoices: choices)
        defer { providerController.teardown() }
        providerController.open()
        providerController.showProvider("current")
        let providerWindow = try XCTUnwrap(providerController.window)
        providerWindow.layoutIfNeeded()
        let providerPage = try XCTUnwrap(providerController.pageContainerForTesting.currentPage?.view)
        XCTAssertNotNil(firstDescendant(of: providerPage, as: NSScrollView.self))
        XCTAssertEqual(providerWindow.title, "Current")
        assertSidebarSelection(in: providerWindow, selected: nil)
    }

    func testReplacedPagesKeepAccessibilityDescendants() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(
                databaseURL: URL(fileURLWithPath: "/nonexistent/issue-388-page-containment.db")
            )
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let composition = appDelegate.dashboardCompositionForTesting
        let window = try XCTUnwrap(composition.makeWindowForTesting(showing: .general))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let generalPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        XCTAssertTrue(generalPage.superview === composition.pageContainerForTesting.view)
        let generalSwitch = try XCTUnwrap(firstDescendant(of: generalPage, as: NSSwitch.self))
        XCTAssertNotNil(generalSwitch.accessibilityRole())

        composition.showSection(.about)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let aboutPage = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        XCTAssertFalse(aboutPage === generalPage)
        XCTAssertNil(generalPage.superview)
        let githubButton = try XCTUnwrap(
            firstDescendant(of: aboutPage, as: DashboardAboutGitHubButton.self)
        )
        XCTAssertEqual(githubButton.accessibilityRole(), .button)

        composition.showSection(.general)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let restoredGeneral = try XCTUnwrap(composition.pageContainerForTesting.currentPage?.view)
        XCTAssertNotNil(firstDescendant(of: restoredGeneral, as: NSSwitch.self))
        XCTAssertEqual(
            composition.pageContainerForTesting.children.count,
            1
        )
        XCTAssertTrue(
            composition.pageContainerForTesting.currentPage?.parent
                === composition.pageContainerForTesting
        )
    }

    private func makeController(
        providerChoices: [ProviderChoice] = []
    ) -> DashboardWindowController {
        DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in
                    DashboardScrollablePageViewController(
                        wrapping: DashboardSettingsComponents.makeSettingsPageContent([
                            DashboardSettingsComponents.makeSettingsSection(
                                "Usage",
                                rows: [DashboardSettingsComponents.makeSettingsRow("Remaining")]
                            )
                        ])
                    )
                },
                providerChoices: { providerChoices },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
    }

    private func assertNativeDashboardToolbar(
        _ window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let toolbar = try XCTUnwrap(window.toolbar, file: file, line: line)
        XCTAssertFalse(toolbar.items.isEmpty, "Dashboard toolbar must not be an empty unified placeholder", file: file, line: line)
        XCTAssertEqual(toolbar.identifier, DashboardToolbarController.identifier, file: file, line: line)
        XCTAssertEqual(toolbar.displayMode, .iconOnly, file: file, line: line)
        XCTAssertFalse(toolbar.allowsUserCustomization, file: file, line: line)
        XCTAssertFalse(toolbar.autosavesConfiguration, file: file, line: line)
        XCTAssertTrue(toolbar.delegate is DashboardToolbarController, file: file, line: line)
        XCTAssertEqual(
            DashboardToolbarController.defaultItemIdentifiers,
            [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator],
            file: file,
            line: line
        )

        let identifiers = toolbar.items.map(\.itemIdentifier)
        XCTAssertEqual(
            identifiers,
            [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator],
            "System flexibleSpace should precede the sidebar toggle so AppKit can push it to the tracking separator",
            file: file,
            line: line
        )
        let customIdentifiers = identifiers.filter {
            $0 != .flexibleSpace && $0 != .toggleSidebar && $0 != .sidebarTrackingSeparator
        }
        XCTAssertTrue(
            customIdentifiers.isEmpty,
            "Do not add unrelated or spacer toolbar items: \(customIdentifiers)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            toolbar.items.contains { $0.itemIdentifier == .sidebarTrackingSeparator && $0 is NSTrackingSeparatorToolbarItem },
            "Tracking separator must be NSTrackingSeparatorToolbarItem, not a fake NSView spacer",
            file: file,
            line: line
        )
        XCTAssertNotNil(
            toolbar.items.first { $0.itemIdentifier == .toggleSidebar },
            file: file,
            line: line
        )
    }

    private func sidebarWidth(in window: NSWindow) -> CGFloat? {
        guard let splitController = window.contentViewController as? DashboardSplitViewController,
              let sidebarItem = splitController.splitViewItems.first
        else { return nil }
        return sidebarItem.viewController.view.frame.width
    }

    private func hasFixedWidthConstraint(in view: NSView, constant: CGFloat) -> Bool {
        if view is NSScrollView || view is NSOutlineView {
            return false
        }
        if view.constraints.contains(where: { constraint in
            constraint.firstAttribute == .width
                && constraint.secondItem == nil
                && constraint.relation == .equal
                && abs(constraint.constant - constant) < 0.001
                && constraint.priority == .required
        }) {
            return true
        }
        return view.subviews.contains { hasFixedWidthConstraint(in: $0, constant: constant) }
    }

    private func assertSplitPanesDoNotOverlap(
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let splitController = window.contentViewController as? DashboardSplitViewController,
              splitController.splitViewItems.count == 2
        else {
            XCTFail("Missing split view panes", file: file, line: line)
            return
        }
        let sidebar = splitController.splitViewItems[0].viewController.view
        let content = splitController.splitViewItems[1].viewController.view
        XCTAssertGreaterThan(content.frame.width, 0, file: file, line: line)
        if splitController.splitViewItems[0].isCollapsed {
            return
        }
        XCTAssertGreaterThan(sidebar.frame.width, 0, file: file, line: line)
        let sidebarInSplit = sidebar.convert(sidebar.bounds, to: splitController.splitView)
        let contentInSplit = content.convert(content.bounds, to: splitController.splitView)
        XCTAssertFalse(
            sidebarInSplit.insetBy(dx: 0.5, dy: 0.5).intersects(contentInSplit.insetBy(dx: 0.5, dy: 0.5)),
            "Sidebar and content frames overlap: \(sidebarInSplit) vs \(contentInSplit)",
            file: file,
            line: line
        )
    }

    private func sourceListOutline(in window: NSWindow) -> NSOutlineView? {
        guard let contentView = window.contentView else { return nil }
        return firstDescendant(of: contentView, as: NSOutlineView.self)
    }

    private func sidebarSections(in outline: NSOutlineView) -> [DashboardSection] {
        (0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? DashboardSidebarNode)?.section
        }
    }

    private func assertSidebarSelection(
        in window: NSWindow,
        selected: DashboardSection?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let outline = sourceListOutline(in: window) else {
            XCTFail("Dashboard sidebar is missing NSOutlineView", file: file, line: line)
            return
        }
        XCTAssertEqual(outline.style, .sourceList, file: file, line: line)
        XCTAssertEqual(sidebarSections(in: outline), DashboardSection.allCases, file: file, line: line)

        var foundSelected: DashboardSection?
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? DashboardSidebarNode else {
                XCTFail("Unexpected outline item at row \(row)", file: file, line: line)
                return
            }
            if node.isGroup {
                XCTAssertFalse(
                    outline.isRowSelected(row),
                    "Group \(node.title) must not be selected",
                    file: file,
                    line: line
                )
                continue
            }
            guard let section = node.section else { continue }
            let shouldSelect = section == selected
            XCTAssertEqual(
                outline.isRowSelected(row),
                shouldSelect,
                "Sidebar \(section) selection mismatch",
                file: file,
                line: line
            )
            if shouldSelect {
                foundSelected = section
            }
        }
        XCTAssertEqual(foundSelected, selected, file: file, line: line)
        if selected == nil {
            XCTAssertEqual(outline.selectedRow, -1, file: file, line: line)
            XCTAssertTrue(outline.selectedRowIndexes.isEmpty, file: file, line: line)
        }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var matches: [NSTextField] = []
        if let field = view as? NSTextField {
            matches.append(field)
        }
        for child in view.subviews {
            matches.append(contentsOf: textFields(in: child))
        }
        return matches
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for child in view.subviews {
            if let match = child as? T {
                return match
            }
            if let match = firstDescendant(of: child, as: type) {
                return match
            }
        }
        return nil
    }

    private func firstDescendant(of view: NSView, kindOf classType: AnyClass) -> NSView? {
        for child in view.subviews {
            if child.isKind(of: classType) {
                return child
            }
            if let match = firstDescendant(of: child, kindOf: classType) {
                return match
            }
        }
        return nil
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        for child in view.subviews {
            if let match = child as? T {
                matches.append(match)
            }
            matches.append(contentsOf: descendants(of: child, as: type))
        }
        return matches
    }

    private func hasCustomRoundedPanelShadow(_ view: NSView) -> Bool {
        if let layer = view.layer,
           abs(layer.cornerRadius - 22) < 0.001,
           layer.shadowOpacity > 0 {
            return true
        }
        return view.subviews.contains { hasCustomRoundedPanelShadow($0) }
    }

    private func assertSidebarHostsSourceListWithoutCustomMaterialWrapper(
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let splitController = window.contentViewController as? DashboardSplitViewController,
              let sidebarItem = splitController.splitViewItems.first
        else {
            XCTFail("Missing sidebar split item", file: file, line: line)
            return
        }
        XCTAssertEqual(sidebarItem.behavior, .sidebar, file: file, line: line)
        XCTAssertTrue(sidebarItem.allowsFullHeightLayout, file: file, line: line)

        let sidebarView = sidebarItem.viewController.view
        XCTAssertFalse(
            sidebarView is NSVisualEffectView,
            "Sidebar root must not be an app-drawn visual-effect wrapper",
            file: file,
            line: line
        )
        if let glassViewClass = NSClassFromString("NSGlassEffectView") {
            XCTAssertFalse(
                sidebarView.isKind(of: glassViewClass),
                "Sidebar root must not be NSGlassEffectView",
                file: file,
                line: line
            )
            XCTAssertNil(
                firstDescendant(of: sidebarView, kindOf: glassViewClass),
                "Sidebar path must not host NSGlassEffectView",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            descendants(of: sidebarView, as: NSVisualEffectView.self)
                .filter { $0.material == .sidebar }
                .isEmpty,
            "Do not replace the deleted glass panel with NSVisualEffectView(.sidebar)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            hasCustomRoundedPanelShadow(sidebarView),
            "Sidebar chrome must not keep a rounded panelShadow wrapper",
            file: file,
            line: line
        )
        let outline = firstDescendant(of: sidebarView, as: DashboardSourceListOutlineView.self)
        XCTAssertNotNil(outline, "Sidebar must still host the #386 source-list", file: file, line: line)
        XCTAssertEqual(outline?.style, .sourceList, file: file, line: line)
    }
}

@MainActor
final class DashboardSourceListContractTests: XCTestCase {
    func testNativeSourceListOwnsSelectionAndOmitsParallelButtonState() throws {
        var pageShows = 0
        let controller = makeController(didShowPage: { pageShows += 1 })
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertTrue(outline.isDescendant(of: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(outline.style, .sourceList)
        XCTAssertTrue(outline.acceptsFirstResponder)
        XCTAssertTrue(outline.canBecomeKeyView)
        XCTAssertEqual(sourceList.selectedSection(), .general)
        XCTAssertEqual(controller.section, .general)

        let sidebar = try XCTUnwrap(
            (window.contentViewController as? DashboardSplitViewController)?
                .splitViewItems.first?.viewController.view
        )
        XCTAssertTrue(
            buttons(in: sidebar).filter { DashboardSection(rawValue: $0.tag) != nil }.isEmpty
        )

        let afterOpen = pageShows
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertEqual(controller.section, section)
            XCTAssertEqual(window.title, section.title)
            XCTAssertEqual(sourceList.selectedSection(), section)
            XCTAssertNil(controller.selectedProviderID)
        }
        XCTAssertEqual(pageShows, afterOpen + DashboardSection.allCases.count - 1)

        controller.showSection(.about)
        XCTAssertEqual(sourceList.selectedSection(), .about)
        XCTAssertEqual(pageShows, afterOpen + DashboardSection.allCases.count)
    }

    func testProviderPageClearsNativeSelectionWithoutAddingProviderRows() throws {
        let choices = [
            ProviderChoice(id: "current", name: "Current", isCurrent: true),
            ProviderChoice(id: "other", name: "Other", isCurrent: false)
        ]
        let controller = makeController(providerChoices: choices)
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertEqual(
            (0..<sourceList.outlineView.numberOfRows).compactMap { row in
                (sourceList.outlineView.item(atRow: row) as? DashboardSidebarNode)?.section
            },
            DashboardSection.allCases
        )
        controller.showProvider("other")
        XCTAssertNil(sourceList.selectedSection())
        XCTAssertEqual(sourceList.outlineView.selectedRow, -1)
        XCTAssertEqual(window.title, "Other")
        XCTAssertFalse(
            (0..<sourceList.outlineView.numberOfRows).contains { row in
                (sourceList.outlineView.item(atRow: row) as? DashboardSidebarNode)?.title == "Other"
            }
        )
    }

    func testMouseClickOnGroupHeaderDoesNotChangeSelectionOrNavigate() throws {
        var pageShows = 0
        let controller = makeController(didShowPage: { pageShows += 1 })
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        let system = try XCTUnwrap(sourceList.roots.first { $0.group == .system })
        XCTAssertTrue(sourceList.outlineView(outline, isGroupItem: appearance))
        XCTAssertFalse(sourceList.outlineView(outline, shouldSelectItem: appearance))
        XCTAssertFalse(sourceList.outlineView(outline, shouldSelectItem: system))
        XCTAssertTrue(
            sourceList.outlineView(outline, shouldSelectItem: try XCTUnwrap(sourceList.node(for: .general)))
        )

        let appearanceRow = outline.row(forItem: appearance)
        let systemRow = outline.row(forItem: system)
        let generalRow = try XCTUnwrap(sourceList.row(for: .general))
        XCTAssertGreaterThanOrEqual(appearanceRow, 0)
        XCTAssertGreaterThan(try XCTUnwrap(sourceList.row(for: .menuBar)), appearanceRow)
        XCTAssertGreaterThan(outline.rect(ofRow: appearanceRow).width, 0)
        XCTAssertGreaterThan(outline.rect(ofRow: appearanceRow).height, 0)
        XCTAssertGreaterThan(outline.rect(ofRow: systemRow).width, 0)

        sourceList.applySelection(.general)
        let afterGeneral = pageShows
        XCTAssertEqual(
            sourceList.outlineView(outline, selectionIndexesForProposedSelection: IndexSet(integer: appearanceRow)),
            IndexSet(integer: generalRow)
        )
        XCTAssertEqual(
            sourceList.outlineView(outline, selectionIndexesForProposedSelection: IndexSet(integer: systemRow)),
            IndexSet(integer: generalRow)
        )
        XCTAssertEqual(
            sourceList.outlineView(outline, selectionIndexesForProposedSelection: IndexSet()),
            IndexSet(integer: generalRow)
        )

        clickTrailingBlank(of: appearanceRow, in: outline)
        XCTAssertEqual(sourceList.selectedSection(), .general)
        XCTAssertEqual(controller.section, .general)
        XCTAssertFalse(outline.isRowSelected(appearanceRow))
        XCTAssertEqual(pageShows, afterGeneral)

        controller.showSection(.menu)
        let afterMenu = pageShows
        let menuRow = try XCTUnwrap(sourceList.row(for: .menu))
        XCTAssertEqual(sourceList.selectedSection(), .menu)
        XCTAssertEqual(
            sourceList.outlineView(outline, selectionIndexesForProposedSelection: IndexSet(integer: systemRow)),
            IndexSet(integer: menuRow)
        )
        clickTrailingBlank(of: systemRow, in: outline)
        XCTAssertEqual(sourceList.selectedSection(), .menu)
        XCTAssertEqual(controller.section, .menu)
        XCTAssertFalse(outline.isRowSelected(systemRow))
        XCTAssertEqual(pageShows, afterMenu)
    }

    func testKeyboardArrowsSkipGroupHeaders() throws {
        var pageShows = 0
        let controller = makeController(didShowPage: { pageShows += 1 })
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        XCTAssertTrue(window.makeFirstResponder(outline))
        sourceList.applySelection(.general)
        let afterGeneral = pageShows

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        XCTAssertEqual(controller.section, .menuBar)

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menu)
        XCTAssertEqual(controller.section, .menu)

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .advanced)
        XCTAssertEqual(controller.section, .advanced)

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .about)
        XCTAssertEqual(controller.section, .about)

        outline.moveDown(nil)
        XCTAssertEqual(sourceList.selectedSection(), .about)
        XCTAssertEqual(controller.section, .about)

        outline.moveUp(nil)
        XCTAssertEqual(sourceList.selectedSection(), .advanced)
        outline.moveUp(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menu)
        outline.moveUp(nil)
        XCTAssertEqual(sourceList.selectedSection(), .menuBar)
        outline.moveUp(nil)
        XCTAssertEqual(sourceList.selectedSection(), .general)
        outline.moveUp(nil)
        XCTAssertEqual(sourceList.selectedSection(), .general)
        XCTAssertEqual(controller.section, .general)
        XCTAssertEqual(pageShows, afterGeneral + 8)
    }

    func testSourceListAccessibilityUsesNativeLabelsWithoutDuplicateIcons() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let outline = sourceList.outlineView
        for section in DashboardSection.allCases {
            let row = try XCTUnwrap(sourceList.row(for: section))
            let cell = try XCTUnwrap(
                outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? DashboardSourceListCellView
            )
            XCTAssertEqual(cell.textField?.stringValue, section.title)
            XCTAssertEqual(cell.accessibilityLabel(), section.title)
            XCTAssertEqual(cell.imageView?.isAccessibilityElement(), false)
            XCTAssertNotNil(cell.imageView?.image)
        }

        let appearance = try XCTUnwrap(sourceList.roots.first { $0.group == .appearance })
        let groupRow = outline.row(forItem: appearance)
        let groupCell = try XCTUnwrap(
            outline.view(atColumn: 0, row: groupRow, makeIfNecessary: true) as? DashboardSourceListGroupCellView
        )
        XCTAssertEqual(groupCell.textField?.stringValue, appearance.title)
        XCTAssertEqual(groupCell.accessibilityLabel(), appearance.title)
    }

    func testRebuildAndTeardownDropOldSourceListOwnership() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let first = try XCTUnwrap(controller.sourceListForTesting)
        let firstOutline = first.outlineView
        XCTAssertTrue(firstOutline.dataSource === first)
        XCTAssertTrue(firstOutline.delegate === first)

        controller.showSection(.menu)
        controller.rebuild()
        XCTAssertNil(firstOutline.dataSource)
        XCTAssertNil(firstOutline.delegate)
        XCTAssertNil(first.onSelectSection)

        let second = try XCTUnwrap(controller.sourceListForTesting)
        XCTAssertFalse(second === first)
        XCTAssertTrue(second.outlineView !== firstOutline)
        XCTAssertEqual(second.selectedSection(), .menu)
        XCTAssertTrue(second.outlineView.dataSource === second)

        let survivingOutline = second.outlineView
        controller.teardown()
        XCTAssertNil(survivingOutline.dataSource)
        XCTAssertNil(survivingOutline.delegate)
        XCTAssertNil(controller.sourceListForTesting)
    }

    private func makeController(
        providerChoices: [ProviderChoice] = [],
        didShowPage: @escaping () -> Void = {}
    ) -> DashboardWindowController {
        DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { providerChoices },
                prepareForPageReplacement: {},
                didShowPage: didShowPage,
                didClose: {},
                didResize: {}
            )
        )
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var matches: [NSButton] = []
        if let button = view as? NSButton {
            matches.append(button)
        }
        for child in view.subviews {
            matches.append(contentsOf: buttons(in: child))
        }
        return matches
    }

    private func clickTrailingBlank(of row: Int, in outline: NSOutlineView) {
        let rowRect = outline.rect(ofRow: row)
        let local = NSPoint(x: max(rowRect.maxX - 8, rowRect.midX), y: rowRect.midY)
        let locationInWindow = outline.convert(local, to: nil)
        let windowNumber = outline.window?.windowNumber ?? 0
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        if let down {
            outline.mouseDown(with: down)
        }
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )
        if let up {
            outline.mouseUp(with: up)
        }
    }
}

@MainActor
final class DashboardProductionPathRegressionTests: XCTestCase {
    func testMenuPageHidesStatusLinksEditorWhenMenuDisplayIsDisabled() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }
        defaults.set(false, forKey: "showStatusMenu")
        defaults.removeObject(forKey: "statusLinks")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(.menu)

        let editor = findStatusLinksEditor(in: page)
        XCTAssertNotNil(editor, "The Status Links editor stays in the page so it can animate in place")
        XCTAssertFalse(editor?.isVisible ?? true)
    }

    func testMenuPageLaysOutReachableStatusLinksEditorWhenMenuDisplayIsEnabled() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        defaults.set(true, forKey: "showStatusMenu")
        defaults.removeObject(forKey: "statusLinks")
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-layout.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let page = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: window.contentView!)

        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        let documentView = try XCTUnwrap(scrollView.documentView)
        let editor = try XCTUnwrap(findStatusLinksEditor(in: page))
        let card = try XCTUnwrap(
            ancestors(of: editor).first { $0.layer?.cornerRadius == 18 }
        )

        XCTAssertFalse(editor.isHidden)
        XCTAssertGreaterThan(editor.frame.width, 0)
        XCTAssertEqual(editor.frame.height, editor.layoutHeight, accuracy: 1)
        XCTAssertTrue(editor.clipsToBounds)
        XCTAssertTrue(editor.scrollViewForTesting.documentView === editor.tableViewForTesting)
        XCTAssertNil(editor.tableViewForTesting.headerView)
        XCTAssertEqual(editor.tableViewForTesting.tableColumns.count, 2)
        XCTAssertGreaterThan(editor.scrollViewForTesting.frame.width, 0)
        XCTAssertGreaterThan(editor.scrollViewForTesting.frame.height, 0)

        let editorRectInCard = editor.convert(editor.bounds, to: card)
        XCTAssertTrue(
            card.bounds.insetBy(dx: -1, dy: -1).contains(editorRectInCard),
            "Status Links editor is clipped by its card: editor=\(editorRectInCard), card=\(card.bounds)"
        )

        let editorRectInDocument = editor.convert(editor.bounds, to: documentView)
        XCTAssertTrue(
            documentView.bounds.insetBy(dx: -1, dy: -1).contains(editorRectInDocument),
            "Status Links editor is outside the scroll document: editor=\(editorRectInDocument), document=\(documentView.bounds)"
        )
        XCTAssertGreaterThan(
            documentView.bounds.height,
            scrollView.contentView.bounds.height,
            "Status Links editor must be reachable by scrolling"
        )

        let scrollFrame = editor.scrollViewForTesting.frame
        XCTAssertTrue(
            editor.bounds.insetBy(dx: -1, dy: -1).contains(scrollFrame),
            "Native Status Links table viewport must stay inside its clipped editor bounds"
        )
    }

    func testProductionMenuAddKeepsStatusLinksCardHeightFixedAndUsesTableScrolling() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        defaults.set(true, forKey: "showStatusMenu")
        let configuredLinks = (0..<6).map {
            StatusLink(title: "Link \($0)", url: "https://\($0).example")
        }
        defaults.set(try JSONEncoder().encode(configuredLinks), forKey: "statusLinks")
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-add-anchor.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.setContentSize(NSSize(width: 800, height: 540))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let page = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: page)
        let scrollView = try XCTUnwrap(firstDescendant(of: page, as: NSScrollView.self))
        let documentView = try XCTUnwrap(scrollView.documentView)
        let editor = try XCTUnwrap(findStatusLinksEditor(in: page))
        let card = try XCTUnwrap(ancestors(of: editor).first { $0.layer?.cornerRadius == 18 })

        let initialEditorHeight = editor.frame.height
        let initialCardHeight = card.frame.height
        let initialDocumentHeight = documentView.bounds.height

        appDelegate.dashboardCompositionForTesting.addStatusLinkForTesting()

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertEqual(editor.rowCount, 7)
        XCTAssertEqual(editor.layoutHeight, StatusLinksEditorHostingView.fixedHeight, accuracy: 0.001)
        XCTAssertEqual(editor.frame.height, initialEditorHeight, accuracy: 1)
        XCTAssertEqual(card.frame.height, initialCardHeight, accuracy: 1)
        XCTAssertEqual(documentView.bounds.height, initialDocumentHeight, accuracy: 1)
        XCTAssertGreaterThan(
            editor.tableViewForTesting.frame.height,
            editor.scrollViewForTesting.contentView.bounds.height,
            "Additional rows should be handled by the native table viewport"
        )
    }

    func testStatusMenuToggleUpdatesDashboardImmediatelyAndPreservesConfiguredLinks() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        let customLinks = [
            StatusLink(title: "Status A", url: "https://status-a.example"),
            StatusLink(title: "Status B", url: "https://status-b.example")
        ]
        defaults.set(true, forKey: "showStatusMenu")
        defaults.set(try JSONEncoder().encode(customLinks), forKey: "statusLinks")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-toggle.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        layoutDescendants(of: window.contentView!)

        let visibleEditor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        XCTAssertEqual(visibleEditor.rowCount, customLinks.count)
        XCTAssertFalse(visibleEditor.isHidden)

        let toggleOff = try XCTUnwrap(
            firstControl(of: window.contentView!, as: NSSwitch.self) {
                $0.identifier?.rawValue == "showStatusMenu"
            }
        )
        toggleOff.state = .off
        _ = NSApp.sendAction(toggleOff.action!, to: toggleOff.target, from: toggleOff)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let hiddenPage = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: window.contentView!)
        XCTAssertEqual(findStatusLinksEditors(in: hiddenPage).count, 1)
        let hiddenEditor = try XCTUnwrap(findStatusLinksEditor(in: hiddenPage))
        XCTAssertFalse(hiddenEditor.isVisible)
        XCTAssertTrue(hiddenEditor === visibleEditor, "Toggle must not recreate the native editor")
        XCTAssertTrue(hiddenEditor.scrollViewForTesting.documentView === hiddenEditor.tableViewForTesting)
        XCTAssertFalse(defaults.bool(forKey: "showStatusMenu"))
        let persistedAfterHide = try JSONDecoder().decode(
            [StatusLink].self,
            from: try XCTUnwrap(defaults.data(forKey: "statusLinks"))
        )
        XCTAssertEqual(persistedAfterHide, customLinks)

        let toggleOn = try XCTUnwrap(
            firstControl(of: window.contentView!, as: NSSwitch.self) {
                $0.identifier?.rawValue == "showStatusMenu"
            }
        )
        toggleOn.state = .on
        _ = NSApp.sendAction(toggleOn.action!, to: toggleOn.target, from: toggleOn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let restoredPage = try XCTUnwrap(menuPage(in: window))
        layoutDescendants(of: window.contentView!)
        XCTAssertEqual(findStatusLinksEditors(in: restoredPage).count, 1)
        let restoredEditor = try XCTUnwrap(findStatusLinksEditor(in: restoredPage))
        XCTAssertTrue(restoredEditor.isVisible)
        XCTAssertTrue(restoredEditor === visibleEditor, "Toggle must not recreate the native editor")
        XCTAssertTrue(restoredEditor.scrollViewForTesting.documentView === restoredEditor.tableViewForTesting)
        XCTAssertEqual(restoredEditor.rowCount, customLinks.count)
        XCTAssertEqual(restoredEditor.frame.height, restoredEditor.layoutHeight, accuracy: 1)
        let persistedAfterRestore = try JSONDecoder().decode(
            [StatusLink].self,
            from: try XCTUnwrap(defaults.data(forKey: "statusLinks"))
        )
        XCTAssertEqual(persistedAfterRestore, customLinks)
    }

    func testRapidStatusMenuTogglesKeepSingleNativeEditorAndStableFinalFrames() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: "showStatusMenu")
        let previousLinks = defaults.object(forKey: "statusLinks")
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
            if let previousLinks {
                defaults.set(previousLinks, forKey: "statusLinks")
            } else {
                defaults.removeObject(forKey: "statusLinks")
            }
        }

        let customLinks = [
            StatusLink(title: "Status A", url: "https://status-a.example"),
            StatusLink(title: "Status B", url: "https://status-b.example")
        ]
        defaults.set(true, forKey: "showStatusMenu")
        defaults.set(try JSONEncoder().encode(customLinks), forKey: "statusLinks")

        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-26-rapid.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .menu))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        layoutDescendants(of: window.contentView!)

        let editor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        for index in 0..<6 {
            let shouldShow = index % 2 == 0
            let toggle = try XCTUnwrap(
                firstControl(of: window.contentView!, as: NSSwitch.self) {
                    $0.identifier?.rawValue == "showStatusMenu"
                }
            )
            toggle.state = shouldShow ? .on : .off
            _ = NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))

            let page = try XCTUnwrap(menuPage(in: window))
            let editors = findStatusLinksEditors(in: page)
            XCTAssertEqual(editors.count, 1, "Rapid toggles must keep exactly one editor")
            XCTAssertTrue(editors.first === editor, "Rapid toggles must not recreate the native editor")
            XCTAssertTrue(editors.first?.scrollViewForTesting.documentView === editors.first?.tableViewForTesting)
            XCTAssertEqual(editors.first?.isVisible, shouldShow)
        }

        let finalToggle = try XCTUnwrap(
            firstControl(of: window.contentView!, as: NSSwitch.self) {
                $0.identifier?.rawValue == "showStatusMenu"
            }
        )
        finalToggle.state = .on
        _ = NSApp.sendAction(finalToggle.action!, to: finalToggle.target, from: finalToggle)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        layoutDescendants(of: window.contentView!)
        let visibleEditor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        XCTAssertTrue(visibleEditor.isVisible)
        XCTAssertEqual(visibleEditor.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(visibleEditor.frame.height, visibleEditor.layoutHeight, accuracy: 1)
        XCTAssertEqual(visibleEditor.rowCount, customLinks.count)
        XCTAssertTrue(visibleEditor.scrollViewForTesting.documentView === visibleEditor.tableViewForTesting)

        finalToggle.state = .off
        _ = NSApp.sendAction(finalToggle.action!, to: finalToggle.target, from: finalToggle)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        layoutDescendants(of: window.contentView!)
        let hiddenEditor = try XCTUnwrap(findStatusLinksEditor(in: try XCTUnwrap(menuPage(in: window))))
        XCTAssertFalse(hiddenEditor.isVisible)
        XCTAssertEqual(hiddenEditor.frame.height, 0, accuracy: 1)
        XCTAssertEqual(hiddenEditor.alphaValue, 0, accuracy: 0.01)
        XCTAssertEqual(hiddenEditor.rowCount, customLinks.count)

        finalToggle.state = .on
        let statusRow = try XCTUnwrap(finalToggle.superview)
        let editorCard = try XCTUnwrap(
            ancestors(of: hiddenEditor).first { $0.layer?.cornerRadius == 18 }
        )
        _ = NSApp.sendAction(finalToggle.action!, to: finalToggle.target, from: finalToggle)
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            layoutDescendants(of: window.contentView!)
            let editorRect = hiddenEditor.convert(hiddenEditor.bounds, to: editorCard)
            let statusRowRect = statusRow.convert(statusRow.bounds, to: editorCard)
            XCTAssertFalse(
                editorRect.intersects(statusRowRect),
                "The editor must never animate through the View Status sibling row"
            )
            XCTAssertTrue(hiddenEditor.clipsToBounds)
        }
    }

    func testMenuPageDoesNotExposeOpenCodexSwitchAndKeepsCCSwitchIndependent() throws {
        let defaults = UserDefaults.standard
        let previousCCSwitchValue = defaults.object(forKey: "showOpenCCSwitchMenu")
        defer {
            if let previousCCSwitchValue {
                defaults.set(previousCCSwitchValue, forKey: "showOpenCCSwitchMenu")
            } else {
                defaults.removeObject(forKey: "showOpenCCSwitchMenu")
            }
        }

        defaults.set(true, forKey: "showOpenCCSwitchMenu")
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-109-menu.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

        let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(.menu)
        layoutDescendants(of: page)
        XCTAssertTrue(
            allControls(of: page, as: NSSwitch.self)
                .filter { $0.identifier?.rawValue == "showOpenCodexMenu" }
                .isEmpty
        )
        XCTAssertFalse(
            allControls(of: page, as: NSTextField.self)
                .contains { $0.stringValue.localizedCaseInsensitiveContains("OpenCodex") }
        )
        let ccSwitchSwitches = allControls(of: page, as: NSSwitch.self).filter {
            $0.identifier?.rawValue == "showOpenCCSwitchMenu"
        }
        XCTAssertEqual(ccSwitchSwitches.count, 1)
        XCTAssertEqual(ccSwitchSwitches.first?.state, .on)
        XCTAssertTrue(AppPreferences(defaults: defaults).showOpenCCSwitchMenu)
    }

    func testProductionSettingsPagesPreserveSectionRowGeometryAndNativeActions() throws {
        let defaults = UserDefaults.standard
        let previousStatusMenu = defaults.object(forKey: "showStatusMenu")
        defaults.set(true, forKey: "showStatusMenu")
        defer {
            if let previousStatusMenu {
                defaults.set(previousStatusMenu, forKey: "showStatusMenu")
            } else {
                defaults.removeObject(forKey: "showStatusMenu")
            }
        }
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-27-pages.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

        for section in [DashboardSection.general, .menuBar, .menu, .advanced] {
            let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(section)
            layoutDescendants(of: page)

            let scrollView = try XCTUnwrap(
                firstDescendant(of: page, as: NSScrollView.self),
                "Missing production settings scroll view for \(section)"
            )
            XCTAssertTrue(scrollView.hasVerticalScroller)
            XCTAssertFalse(scrollView.hasHorizontalScroller)
            let documentView = try XCTUnwrap(scrollView.documentView)
            let pageStack = try XCTUnwrap(
                firstDescendant(of: documentView, as: NSStackView.self),
                "Missing settings page stack for \(section)"
            )
            XCTAssertFalse(pageStack.arrangedSubviews.isEmpty)

            for sectionView in pageStack.arrangedSubviews {
                let sectionStack = try XCTUnwrap(sectionView as? NSStackView)
                XCTAssertEqual(sectionStack.arrangedSubviews.count, 2)
                let heading = try XCTUnwrap(sectionStack.arrangedSubviews.first as? NSTextField)
                XCTAssertEqual(heading.font?.pointSize ?? -1, 17, accuracy: 0.01)
                let card = sectionStack.arrangedSubviews[1]
                XCTAssertEqual(card.layer?.cornerRadius ?? -1, 18, accuracy: 0.01)
                let rowsStack = try XCTUnwrap(
                    firstDescendant(of: card, as: NSStackView.self)
                )
                XCTAssertFalse(rowsStack.arrangedSubviews.isEmpty)
                for row in rowsStack.arrangedSubviews where !(row is NSBox) && !row.isHidden {
                    XCTAssertGreaterThanOrEqual(row.frame.height, 62)
                }
            }

            for control in allControls(of: page, as: NSSwitch.self) {
                XCTAssertNotNil(control.target, "Switch lost its target on \(section)")
                XCTAssertNotNil(control.action, "Switch lost its action on \(section)")
            }
            for control in allControls(of: page, as: NSPopUpButton.self) {
                XCTAssertNotNil(control.target, "Popup lost its target on \(section)")
                XCTAssertNotNil(control.action, "Popup lost its action on \(section)")
            }
        }
    }

    func testMenuBarAndAdvancedFirstMountStartAtNativeTopWithoutBlankRegion() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-top-blank.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }

        for section in [DashboardSection.general, .menuBar, .advanced] {
            let page = appDelegate.dashboardCompositionForTesting.makePageForTesting(section)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = page
            window.layoutIfNeeded()
            layoutDescendants(of: page)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            defer { window.orderOut(nil) }

            let scrollView = try XCTUnwrap(
                firstDescendant(of: page, as: NSScrollView.self),
                "Missing settings scroll view for \(section)"
            )
            let documentView = try XCTUnwrap(scrollView.documentView)
            let pageStack = try XCTUnwrap(
                firstDescendant(of: documentView, as: NSStackView.self)
            )
            let firstSection = try XCTUnwrap(pageStack.arrangedSubviews.first)
            let firstHeading = try XCTUnwrap(
                firstDescendant(of: firstSection, as: NSTextField.self)
            )
            let visibleRect = scrollView.contentView.convert(
                scrollView.contentView.bounds,
                to: documentView
            )
            let firstHeadingRect = firstHeading.convert(
                firstHeading.bounds,
                to: documentView
            )
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)

            XCTAssertTrue(documentView.isFlipped)
            XCTAssertEqual(viewportFrameInPage.minY - page.bounds.minY, 52, accuracy: 1)
            XCTAssertEqual(visibleRect.minY, documentView.bounds.minY, accuracy: 1)
            XCTAssertEqual(
                pageStack.frame.minY,
                documentView.bounds.minY,
                accuracy: 1
            )
            XCTAssertLessThanOrEqual(
                visibleRect.maxY,
                documentView.bounds.maxY + 1
            )
            XCTAssertTrue(
                visibleRect.intersects(firstHeadingRect),
                "First heading is not visible on initial mount for \(section): visible=\(visibleRect), heading=\(firstHeadingRect)"
            )
            let headingInPage = firstHeading.convert(firstHeading.bounds, to: page)
            XCTAssertGreaterThanOrEqual(headingInPage.minY, viewportFrameInPage.minY - 1)
            XCTAssertLessThanOrEqual(headingInPage.maxY, viewportFrameInPage.maxY + 1)
        }
    }

    func testGeneralMenuBarAndAdvancedPageReplacementResetsNativeTop() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-page-replacement.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )

        for section in [DashboardSection.general, .menuBar, .advanced] {
            appDelegate.dashboardCompositionForTesting.showSection(section)
            window.displayIfNeeded()
            layoutDescendants(of: window.contentView!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))

            let scrollView = try XCTUnwrap(
                firstDescendant(of: window.contentView!, as: NSScrollView.self),
                "Missing replaced settings scroll view for \(section)"
            )
            let document = try XCTUnwrap(scrollView.documentView)
            let visible = scrollView.contentView.convert(
                scrollView.contentView.bounds,
                to: document
            )
            let stack = try XCTUnwrap(firstDescendant(of: document, as: NSStackView.self))
            let firstSection = try XCTUnwrap(stack.arrangedSubviews.first)
            let firstHeading = try XCTUnwrap(
                firstDescendant(of: firstSection, as: NSTextField.self)
            )
            let firstHeadingRect = firstHeading.convert(firstHeading.bounds, to: document)
            let page = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.pageContainerForTesting.currentPage?.view
            )
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)
            XCTAssertTrue(document.isFlipped)
            XCTAssertEqual(
                viewportFrameInPage.minY - page.bounds.minY,
                52,
                accuracy: 1,
                "Settings scroll viewport lost its measured non-document top inset for \(section)"
            )
            XCTAssertEqual(
                visible.minY,
                document.bounds.minY,
                accuracy: 1,
                "Initial visible origin mismatch for \(section): visible=\(visible), document=\(document.bounds), clipBounds=\(scrollView.contentView.bounds), contentInsets=\(scrollView.contentInsets)"
            )
            XCTAssertEqual(stack.frame.minY, document.bounds.minY, accuracy: 1)
            XCTAssertTrue(
                visible.intersects(firstHeadingRect),
                "Replaced \(section) first heading is not visible: visible=\(visible), heading=\(firstHeadingRect)"
            )
            let headingInPage = firstHeading.convert(firstHeading.bounds, to: page)
            XCTAssertGreaterThanOrEqual(headingInPage.minY, viewportFrameInPage.minY - 1)
            XCTAssertLessThanOrEqual(headingInPage.maxY, viewportFrameInPage.maxY + 1)
        }
    }

    func testProductionSettingsScrollHostsKeepNativeElasticityAndLegalEndpointFrames() throws {
        let appDelegate = AppDelegate(
            repository: CCSwitchRepository(databaseURL: URL(fileURLWithPath: "/nonexistent/issue-30-endpoint.db"))
        )
        defer { appDelegate.dashboardCompositionForTesting.teardownForTesting() }
        let window = try XCTUnwrap(
            appDelegate.dashboardCompositionForTesting.makeWindowForTesting(showing: .general)
        )

        for section in [DashboardSection.general, .menuBar, .advanced] {
            appDelegate.dashboardCompositionForTesting.showSection(section)
            window.displayIfNeeded()
            layoutDescendants(of: window.contentView!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))

            let scrollView = try XCTUnwrap(
                firstDescendant(of: window.contentView!, as: NSScrollView.self),
                "Missing settings scroll view for \(section)"
            )
            let contentView = scrollView.contentView
            let document = try XCTUnwrap(scrollView.documentView)
            let page = try XCTUnwrap(
                appDelegate.dashboardCompositionForTesting.pageContainerForTesting.currentPage?.view
            )
            let viewportFrameInPage = scrollView.convert(scrollView.bounds, to: page)
            let stack = try XCTUnwrap(firstDescendant(of: document, as: NSStackView.self))
            let firstHeading = try XCTUnwrap(
                firstDescendant(of: stack.arrangedSubviews.first!, as: NSTextField.self)
            )
            let geometry = DashboardScrollGeometry(
                documentBounds: document.bounds,
                viewportHeight: contentView.bounds.height,
                isDocumentFlipped: document.isFlipped
            )

            XCTAssertFalse(scrollView.automaticallyAdjustsContentInsets)
            XCTAssertEqual(scrollView.contentInsets.top, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.contentInsets.bottom, 0, accuracy: 0.001)
            XCTAssertEqual(scrollView.verticalScrollElasticity, .none)
            XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
            XCTAssertTrue(document.isFlipped)
            XCTAssertEqual(viewportFrameInPage.minY - page.bounds.minY, 52, accuracy: 1)
            XCTAssertEqual(viewportFrameInPage.maxY, page.bounds.maxY, accuracy: 1)

            let proposals = geometry.maximumOffset > 1
                ? [CGFloat(0), geometry.maximumOffset, geometry.maximumOffset * 0.72, geometry.maximumOffset, CGFloat(0)]
                : [CGFloat(0)]
            var bottomVisible: NSRect?
            for proposal in proposals {
                let targetRect = geometry.visibleDocumentRect(forVisualOffset: proposal)
                let targetDocumentY = geometry.contentOriginDocumentY(
                    for: targetRect,
                    contentViewIsFlipped: contentView.isFlipped
                )
                let targetContentY = document.convert(
                    NSPoint(x: document.bounds.minX, y: targetDocumentY),
                    to: contentView
                ).y
                contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: targetContentY))
                scrollView.reflectScrolledClipView(contentView)

                let visible = contentView.convert(contentView.bounds, to: document)
                let actual = geometry.visualOffset(for: visible)
                XCTAssertEqual(actual, proposal, accuracy: 1, "Native endpoint replay moved \(section) unexpectedly")
                XCTAssertGreaterThanOrEqual(visible.minY, document.bounds.minY - 1)
                XCTAssertLessThanOrEqual(visible.maxY, document.bounds.maxY + 1)
                if abs(proposal - geometry.maximumOffset) < 0.001 {
                    bottomVisible = visible
                }
            }

            let visibleAtTop = contentView.convert(contentView.bounds, to: document)
            let firstHeadingRect = firstHeading.convert(firstHeading.bounds, to: document)
            let visibleAtBottom = try XCTUnwrap(bottomVisible)
            XCTAssertEqual(visibleAtBottom.maxY, document.bounds.maxY, accuracy: 1)
            XCTAssertEqual(geometry.clampedVisualOffset(for: visibleAtTop), 0, accuracy: 1)
            XCTAssertTrue(visibleAtTop.intersects(firstHeadingRect))
            XCTAssertEqual(stack.frame.minY, document.bounds.minY, accuracy: 1)
        }
    }

    func testDashboardSettingsFactoryPreservesNativeControlValuesAndActions() throws {
        final class ActionTarget: NSObject {
            var switchActionCount = 0
            var popupActionCount = 0

            @objc func switchChanged(_ sender: NSSwitch) {
                switchActionCount += 1
            }

            @objc func popupChanged(_ sender: NSPopUpButton) {
                popupActionCount += 1
            }
        }

        let target = ActionTarget()
        let control = DashboardSettingsComponents.makeSwitch(
            identifier: "factory.switch",
            isOn: true,
            target: target,
            action: #selector(ActionTarget.switchChanged(_:))
        )
        XCTAssertEqual(control.identifier?.rawValue, "factory.switch")
        XCTAssertEqual(control.state, .on)
        _ = target.perform(control.action, with: control)
        XCTAssertEqual(target.switchActionCount, 1)

        let popup = DashboardSettingsComponents.makePopUpButton(
            identifier: "factory.popup",
            items: [
                .init(title: "First", representedObject: "first"),
                .init(title: "Second", representedObject: "second")
            ],
            selectedIndex: 1,
            target: target,
            action: #selector(ActionTarget.popupChanged(_:))
        )
        XCTAssertEqual(popup.identifier?.rawValue, "factory.popup")
        XCTAssertEqual(popup.indexOfSelectedItem, 1)
        XCTAssertEqual(popup.item(at: 1)?.representedObject as? String, "second")
        XCTAssertEqual(target.popupActionCount, 0)
        _ = target.perform(popup.action, with: popup)
        XCTAssertEqual(target.popupActionCount, 1)
    }

    func testRebuildDisconnectsExistingPopUpButtonActions() {
        final class ActionTarget: NSObject {
            var popupActionCount = 0

            @objc func popupChanged(_ sender: NSPopUpButton) {
                popupActionCount += 1
            }
        }

        let target = ActionTarget()
        let popup = DashboardSettingsComponents.makePopUpButton(
            items: [
                .init(title: "Spanish", representedObject: AppLanguage.spanish.rawValue),
                .init(title: "Chinese", representedObject: AppLanguage.simplifiedChinese.rawValue)
            ],
            selectedIndex: 0,
            target: target,
            action: #selector(ActionTarget.popupChanged(_:))
        )
        let controller = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in DashboardHostedPageViewController() },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        controller.open()
        defer { controller.teardown() }
        controller.contentHost.addSubview(popup)
        XCTAssertTrue(popup.target === target)
        XCTAssertEqual(popup.action, #selector(ActionTarget.popupChanged(_:)))

        controller.rebuild()
        XCTAssertNil(popup.target)
        XCTAssertNil(popup.action)
        XCTAssertEqual(target.popupActionCount, 0)
    }

    func testStatusMenuEntryFollowsShowStatusMenuPreferenceInMainMenu() {
        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let baseInput = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [
                StatusLink(title: "Status", url: "https://status.example")
            ],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showStatusMenu: false
        )
        controller.start(
            snapshot: .placeholder,
            refreshDate: nil,
            menuInput: baseInput,
            settings: settings
        )
        XCTAssertNil(
            controller.menuItemsForTesting.first {
                $0.title == "查看状态" || $0.title == "View Status"
            }
        )

        let visibleInput = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: nil,
            statusLinks: [
                StatusLink(title: "Status", url: "https://status.example")
            ],
            showQuickSwitchMenu: true,
            showOpenChatGPTMenu: true,
            showOpenCCSwitchMenu: true,
            showStatusMenu: true
        )
        controller.updateMenu(input: visibleInput)
        let statusItem = try? XCTUnwrap(
            controller.menuItemsForTesting.first {
                $0.title == "查看状态" || $0.title == "View Status"
            }
        )
        XCTAssertEqual(statusItem?.submenu?.items.map(\.title), ["Status"])

        controller.updateMenu(input: baseInput)
        XCTAssertNil(
            controller.menuItemsForTesting.first {
                $0.title == "查看状态" || $0.title == "View Status"
            }
        )
    }

    func testOpenAIAccountSubtitleUsesStaticMiddleTruncationAndHidesOutsideOfficialCodex() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        func input(account: OpenAIAccountPresentation?) -> StatusItemController.MenuInput {
            StatusItemController.MenuInput(
                choices: [],
                quickSwitchSummaries: [:],
                activeClient: .codex,
                openAIAccount: account,
                statusLinks: [],
                showQuickSwitchMenu: false,
                showOpenChatGPTMenu: false,
                showOpenCCSwitchMenu: false,
                showStatusMenu: false
            )
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let longEmail = "account-alpha-20260827-singapore-long-identifier-beta-usage-quota-gamma-openai-official-delta-window-resize-epsilon-manual-check@gmail.com"
        controller.start(
            snapshot: .official("OpenAI Official", 83, "7-Day Quota", "2 hours", date),
            refreshDate: date,
            menuInput: input(account: OpenAIAccountPresentation(email: longEmail, subscription: .proFiveX)),
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let accountView = try XCTUnwrap(
            overview.subviews.compactMap { $0 as? AccountEmailView }.first
        )
        let accountLabel = accountView.emailLabel
        XCTAssertEqual(accountLabel.font?.pointSize, 13)
        XCTAssertEqual(accountLabel.textColor, .secondaryLabelColor)
        XCTAssertEqual(accountLabel.lineBreakMode, .byClipping)
        XCTAssertEqual(AccountEmailTextField.tooltipDelay, 0.15, accuracy: 0.001)
        XCTAssertFalse(accountLabel.isTooltipScheduled)
        XCTAssertFalse(accountLabel.isTooltipVisible)
        let tooltipEmail = "huanmeng2048609305@163.com"
        let tooltipFont = NSFont.toolTipsFont(ofSize: NSFont.smallSystemFontSize)
        let tooltipLayout = AccountEmailTooltipLayout.make(
            for: tooltipEmail,
            font: tooltipFont
        )
        XCTAssertGreaterThanOrEqual(
            tooltipLayout.textWidth,
            AccountMarqueeView.textWidth(of: tooltipEmail, font: tooltipFont)
                + AccountEmailTooltipLayout.textMeasurementSlack
        )
        let wrappedTooltipEmail = "huanmeng2048609305137151358071145141919810@gmail.com"
        let wrappedTooltipLayout = AccountEmailTooltipLayout.make(
            for: wrappedTooltipEmail,
            font: tooltipFont
        )
        let minimumSingleLineHeight = ceil(tooltipFont.ascender - tooltipFont.descender + 2)
        XCTAssertGreaterThan(wrappedTooltipLayout.textHeight, minimumSingleLineHeight)
        XCTAssertLessThanOrEqual(
            wrappedTooltipLayout.textWidth,
            AccountEmailTooltipLayout.maximumTextWidth
        )
        XCTAssertEqual(
            wrappedTooltipLayout.contentSize.height,
            wrappedTooltipLayout.textHeight + AccountEmailTooltipLayout.verticalInset * 2
        )
        let threeLineTooltipEmail = String(repeating: "x", count: 110) + "@gmail.com"
        let threeLineTooltipLayout = AccountEmailTooltipLayout.make(
            for: threeLineTooltipEmail,
            font: tooltipFont
        )
        XCTAssertGreaterThan(threeLineTooltipLayout.textHeight, wrappedTooltipLayout.textHeight)
        XCTAssertGreaterThan(
            threeLineTooltipLayout.textHeight,
            minimumSingleLineHeight * 2
        )
        XCTAssertGreaterThan(tooltipLayout.textHeight, 0)
        XCTAssertFalse(accountView.isMarqueeEnabled)
        XCTAssertEqual(accountView.fullEmail, longEmail)
        XCTAssertTrue(accountView.textLayout.isTruncated)
        XCTAssertTrue(accountView.displayedEmail.contains(AccountEmailTextLayout.ellipsis))
        XCTAssertTrue(accountView.displayedEmail.hasPrefix(accountView.textLayout.prefix))
        XCTAssertTrue(accountView.displayedEmail.hasSuffix("@gmail.com"))
        XCTAssertGreaterThan(accountView.textLayout.prefix.count, 0)
        XCTAssertLessThanOrEqual(
            accountView.textLayout.measuredTextWidth,
            accountView.bounds.width + 0.001
        )
        XCTAssertEqual(accountView.emailLabel.frame, accountView.bounds)
        XCTAssertEqual(accountView.emailLabel.toolTip, longEmail)
        XCTAssertEqual(accountView.emailLabel.accessibilityLabel(), longEmail)
        XCTAssertEqual(accountView.emailLabel.accessibilityValue() as? String, longEmail)
        XCTAssertFalse(accountLabel.isEmailHovered)
        XCTAssertFalse(accountLabel.isUnderlined)
        accountLabel.setHoveringForTesting(true)
        XCTAssertTrue(accountLabel.isEmailHovered)
        XCTAssertTrue(accountLabel.isUnderlined)
        XCTAssertEqual(accountLabel.toolTip, longEmail)
        accountLabel.setHoveringForTesting(false)
        XCTAssertFalse(accountLabel.isEmailHovered)
        XCTAssertFalse(accountLabel.isUnderlined)
        XCTAssertEqual(
            accountView.tooltipText(at: NSPoint(x: 1, y: accountView.bounds.midY)),
            longEmail
        )
        XCTAssertNil(accountView.tooltipText(at: NSPoint(x: -1, y: accountView.bounds.midY)))
        XCTAssertNil(accountView.emailLabel.target)
        XCTAssertNil(accountView.emailLabel.action)
        XCTAssertNil(accountView.layer?.animation(forKey: AccountMarqueeView.animationKey))
        XCTAssertNil(accountView.emailLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))
        XCTAssertLessThanOrEqual(accountView.frame.maxX, overview.bounds.maxX)
        let subscriptionLabel = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == "Pro · 5x"
            }
        )
        XCTAssertEqual(subscriptionLabel.font?.pointSize, 13)
        XCTAssertEqual(subscriptionLabel.textColor, .secondaryLabelColor)
        XCTAssertEqual(subscriptionLabel.alignment, .right)
        XCTAssertEqual(subscriptionLabel.lineBreakMode, .byTruncatingTail)
        let subscriptionTextWidth = AccountMarqueeView.textWidth(
            of: subscriptionLabel.stringValue,
            font: try XCTUnwrap(subscriptionLabel.font)
        )
        let expectedAccountFrame = try XCTUnwrap(
            OpenCodexCardLayout.frames(
                for: .quota,
                includesAccount: true,
                includesSubscription: true,
                subscriptionTextWidth: subscriptionTextWidth
            ).account
        )
        XCTAssertEqual(accountView.frame, expectedAccountFrame)
        let subscriptionFrame = try XCTUnwrap(
            OpenCodexCardLayout.frames(
                for: .quota,
                includesAccount: true,
                includesSubscription: true
            ).subscription
        )
        XCTAssertEqual(subscriptionLabel.frame, subscriptionFrame)
        XCTAssertTrue(subscriptionLabel.superview === overview)
        XCTAssertEqual(accountView.frame.minY, subscriptionLabel.frame.minY)
        XCTAssertEqual(accountView.frame.height, subscriptionLabel.frame.height)
        XCTAssertEqual(
            accountView.frame.maxX,
            subscriptionLabel.frame.maxX
                - subscriptionTextWidth
                - OpenCodexCardLayout.subscriptionTextSafetyGap,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            subscriptionLabel.frame.maxX - subscriptionTextWidth - accountView.frame.maxX,
            OpenCodexCardLayout.subscriptionTextSafetyGap - 0.001
        )
        XCTAssertGreaterThanOrEqual(
            OpenCodexCardLayout.subscriptionTextSafetyGap,
            8
        )
        XCTAssertGreaterThan(accountView.frame.maxX, subscriptionLabel.frame.minX)
        XCTAssertEqual(subscriptionLabel.frame.maxX, overview.bounds.width - 14)
        XCTAssertNotNil(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == "83%"
            }
        )

        controller.updateMenu(
            input: input(account: OpenAIAccountPresentation(email: "person@example.com", subscription: .proTwentyX))
        )
        let switchedOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let switchedAccountView = try XCTUnwrap(
            switchedOverview.subviews.compactMap { $0 as? AccountEmailView }.first
        )
        let switchedSubscriptionLabel = try XCTUnwrap(
            allControls(of: switchedOverview, as: NSTextField.self).first {
                $0.stringValue == "Pro · 20x"
            }
        )
        let switchedSubscriptionTextWidth = AccountMarqueeView.textWidth(
            of: switchedSubscriptionLabel.stringValue,
            font: try XCTUnwrap(switchedSubscriptionLabel.font)
        )
        XCTAssertFalse(switchedAccountView.textLayout.isTruncated)
        XCTAssertFalse(switchedAccountView.isMarqueeEnabled)
        XCTAssertEqual(switchedAccountView.emailLabel.frame.width, switchedAccountView.bounds.width)
        XCTAssertEqual(switchedAccountView.displayedEmail, "person@example.com")
        XCTAssertEqual(switchedAccountView.emailLabel.toolTip, "person@example.com")
        XCTAssertEqual(
            switchedAccountView.emailLabel.accessibilityValue() as? String,
            "person@example.com"
        )
        XCTAssertEqual(
            switchedAccountView.frame.maxX,
            switchedSubscriptionLabel.frame.maxX
                - switchedSubscriptionTextWidth
                - OpenCodexCardLayout.subscriptionTextSafetyGap,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(switchedAccountView.frame.maxX, switchedSubscriptionLabel.frame.minX)
        XCTAssertNil(
            allControls(of: switchedOverview, as: NSTextField.self).first {
                $0.stringValue.contains(longEmail)
            }
        )
        XCTAssertNil(
            allControls(of: switchedOverview, as: NSTextField.self).first {
                $0.stringValue == "Pro · 5x"
            }
        )

        controller.updateMenu(
            input: input(account: OpenAIAccountPresentation(email: nil))
        )
        let unavailableOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertNotNil(
            allControls(of: unavailableOverview, as: NSTextField.self).first {
                $0.stringValue == "Account unavailable"
            }
        )

        controller.update(
            snapshot: .balance(
                "Relay",
                12.34,
                "USD",
                URL(string: "https://relay.example"),
                date
            ),
            refreshDate: date,
            menuInput: input(account: nil),
            settings: settings
        )
        let nonOfficialOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertFalse(
            allControls(of: nonOfficialOverview, as: NSTextField.self).contains {
                $0.stringValue.contains("Account") || $0.stringValue.contains("account-")
            }
        )
        XCTAssertTrue(
            allControls(of: nonOfficialOverview, as: AccountEmailView.self).isEmpty
        )
    }

    func testAccountEmailTextLayoutPreservesDomainsAndUnicodeWithoutOverflow() {
        let font = NSFont.systemFont(ofSize: 13)
        let short = "person@example.com"
        let shortLayout = AccountEmailTextLayout.make(
            for: short,
            font: font,
            availableWidth: AccountMarqueeView.textWidth(of: short, font: font) + 1
        )
        XCTAssertFalse(shortLayout.isTruncated)
        XCTAssertEqual(shortLayout.displayText, short)

        let long = "前缀用户-非常长的标识-東京と한글@gmail.com"
        let longLayout = AccountEmailTextLayout.make(
            for: long,
            font: font,
            availableWidth: 150
        )
        XCTAssertTrue(longLayout.isTruncated)
        XCTAssertTrue(longLayout.displayText.contains(AccountEmailTextLayout.ellipsis))
        XCTAssertTrue(longLayout.displayText.hasSuffix("@gmail.com"))
        XCTAssertTrue(longLayout.prefix.hasPrefix("前"))
        XCTAssertLessThanOrEqual(longLayout.measuredTextWidth, 150.001)

        let longDomain = "local-part-with-unicode-👩‍💻-and-graphemes@subdomain-with-a-very-long-name.example"
        let longDomainLayout = AccountEmailTextLayout.make(
            for: longDomain,
            font: font,
            availableWidth: 118
        )
        XCTAssertTrue(longDomainLayout.isTruncated)
        XCTAssertTrue(longDomainLayout.displayText.contains(AccountEmailTextLayout.ellipsis))
        XCTAssertTrue(longDomainLayout.displayText.hasSuffix("example"))
        if longDomainLayout.displayText.contains("👩") {
            XCTAssertTrue(longDomainLayout.displayText.contains("👩‍💻"))
        }
        XCTAssertLessThanOrEqual(longDomainLayout.measuredTextWidth, 118.001)

        let languages = [
            "account-with-a-long-name@example.com",
            "账号-非常长@example.cn",
            "帳號-非常長@example.tw",
            "帳號-非常長@example.hk",
            "アカウント-とても長い@example.jp",
            "계정-매우긴이름@example.kr",
            "cuenta-muy-larga@example.es",
            "konto-sehr-lang@example.de",
            "compte-très-long@example.fr"
        ]
        for email in languages {
            let layout = AccountEmailTextLayout.make(
                for: email,
                font: font,
                availableWidth: 100
            )
            XCTAssertLessThanOrEqual(
                layout.measuredTextWidth,
                100.001,
                "display overflowed for \(email)"
            )
            XCTAssertTrue(layout.displayText.contains(AccountEmailTextLayout.ellipsis))
        }
    }

    func testAccountEmailViewRecomputesStaticDisplayForDynamicTextAndResize() throws {
        let email = "resize-sensitive-account@example.com"
        let view = AccountEmailView(
            email: email,
            font: .systemFont(ofSize: 13),
            textColor: .secondaryLabelColor,
            frame: NSRect(x: 14, y: 75, width: 110, height: 18)
        )
        let initialFrame = view.frame
        XCTAssertTrue(view.textLayout.isTruncated)
        XCTAssertEqual(view.emailLabel.toolTip, email)
        XCTAssertNil(view.emailLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))

        view.setFrameSize(NSSize(width: 260, height: 18))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.textLayout.isTruncated)
        XCTAssertEqual(view.displayedEmail, email)
        XCTAssertEqual(view.emailLabel.frame, view.bounds)

        let updatedEmail = "动态更新-長い-アカウント@example.example"
        view.updateText(updatedEmail)
        XCTAssertEqual(view.fullEmail, updatedEmail)
        XCTAssertEqual(view.emailLabel.toolTip, updatedEmail)
        XCTAssertEqual(view.emailLabel.accessibilityValue() as? String, updatedEmail)
        XCTAssertEqual(
            view.tooltipText(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)),
            updatedEmail
        )

        view.emailLabel.setHoveringForTesting(true)
        XCTAssertTrue(view.emailLabel.isUnderlined)

        view.setFrameSize(NSSize(width: 92, height: 18))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.textLayout.isTruncated)
        XCTAssertTrue(view.emailLabel.isUnderlined)
        XCTAssertLessThanOrEqual(
            view.textLayout.measuredTextWidth,
            view.bounds.width + 0.001
        )
        XCTAssertEqual(view.frame.minX, initialFrame.minX)
        XCTAssertEqual(view.frame.minY, initialFrame.minY)
        XCTAssertEqual(view.frame.height, initialFrame.height)
        view.emailLabel.setHoveringForTesting(false)
        XCTAssertFalse(view.emailLabel.isUnderlined)
        XCTAssertNil(view.emailLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))
    }

    func testAccountMarqueeLayoutUsesViewportInsetAndActualOverflowAcrossLanguages() {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let viewport = NSRect(x: 14, y: 75, width: 128, height: 18)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let short = AccountMarqueeLayout(
            measuredTextWidth: 32,
            clipBounds: viewport
        )

        XCTAssertFalse(short.isScrollable)
        XCTAssertEqual(short.edgeFadeWidth, 0, accuracy: 0.001)
        XCTAssertEqual(short.scrollDistance, 0, accuracy: 0.001)
        XCTAssertEqual(short.maskLocations, [])
        XCTAssertEqual(short.contentFrame, viewport)

        for language in [
            AppLanguage.english,
            .simplifiedChinese,
            .traditionalChineseTaiwan,
            .traditionalChineseHongKong,
            .japanese,
            .korean,
            .spanish,
            .german,
            .french
        ] {
            AppLanguage.selected = language
            let localizedText = String(
                repeating: tr(.keyResponseParsers7DayQuota2) + " ",
                count: 6
            )
            let textWidth = AccountMarqueeView.textWidth(of: localizedText, font: font)
            let layout = AccountMarqueeLayout(
                measuredTextWidth: textWidth,
                clipBounds: viewport
            )

            XCTAssertTrue(layout.isScrollable, "expected overflow for \(language)")
            XCTAssertEqual(layout.contentFrame.minX, viewport.minX)
            XCTAssertEqual(layout.contentFrame.minY, viewport.minY)
            XCTAssertEqual(layout.contentFrame.width, textWidth, accuracy: 0.001)
            XCTAssertEqual(layout.textOverflow, textWidth - viewport.width, accuracy: 0.001)
            XCTAssertEqual(layout.trailingFadeBuffer, layout.edgeFadeWidth, accuracy: 0.001)
            XCTAssertEqual(
                layout.scrollDistance,
                layout.textOverflow + layout.trailingFadeBuffer,
                accuracy: 0.001
            )
            XCTAssertEqual(
                layout.endpointContentFrame.maxX,
                layout.trailingOpaqueMaxX,
                accuracy: 0.001
            )
            XCTAssertLessThanOrEqual(
                layout.endpointContentFrame.maxX,
                viewport.maxX - layout.edgeFadeWidth + 0.001
            )
            XCTAssertEqual(layout.clipBounds, viewport)
            XCTAssertEqual(layout.maskLocations.count, 4)
            XCTAssertEqual(layout.maskLocations.first ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(layout.maskLocations.last ?? -1, 1, accuracy: 0.001)
            XCTAssertGreaterThan(layout.maskLocations[1], 0)
            XCTAssertLessThan(layout.maskLocations[2], 1)
        }
    }

    func testAccountMarqueeRecomputesForDynamicTextAndNarrowWideNarrowResize() throws {
        let shortText = "Quota"
        let longText = String(repeating: "A very long localized quota title ", count: 8)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let view = AccountMarqueeView(
            text: shortText,
            font: font,
            textColor: .labelColor,
            frame: NSRect(x: 14, y: 75, width: 128, height: 18)
        )

        XCTAssertFalse(view.isScrollable)
        XCTAssertFalse(view.showsEdgeFade)

        view.updateText(longText)
        view.layout()
        XCTAssertTrue(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertEqual(view.frame.minX, 14, accuracy: 0.001)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(
            view.scrollOverflow,
            view.measuredTextWidth - view.bounds.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            view.scrollDistance,
            view.scrollOverflow + view.edgeFadeInset,
            accuracy: 0.001
        )
        XCTAssertNil(view.layer?.mask)
        view.applyScrollOffsetForTesting(-1)
        XCTAssertTrue(view.isScrolling)
        XCTAssertTrue(view.showsEdgeFade)
        let narrowMask = try XCTUnwrap(view.layer?.mask as? CAGradientLayer)
        XCTAssertEqual(narrowMask.frame, view.layer?.bounds ?? view.bounds)
        XCTAssertEqual(narrowMask.startPoint, CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(narrowMask.endPoint, CGPoint(x: 1, y: 0.5))

        let animation = AccountMarqueeView.scrollAnimation(
            forOverflow: view.scrollOverflow,
            trailingFadeBuffer: view.edgeFadeInset
        )
        let endpoint = try XCTUnwrap(animation.values?[2] as? NSNumber)
        XCTAssertEqual(endpoint.doubleValue, -Double(view.scrollDistance), accuracy: 0.001)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearanceName)
            view.layout()
            let mask = try XCTUnwrap(view.layer?.mask as? CAGradientLayer)
            XCTAssertEqual(mask.frame, view.layer?.bounds ?? view.bounds)
            XCTAssertEqual(mask.startPoint, CGPoint(x: 0, y: 0.5))
            XCTAssertEqual(mask.endPoint, CGPoint(x: 1, y: 0.5))
            XCTAssertEqual(mask.locations?.count, 4)
        }

        let wideWidth = view.measuredTextWidth + 32
        view.setFrameSize(NSSize(width: wideWidth, height: 18))
        view.layout()
        XCTAssertFalse(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(view.accountLabel.frame.width, view.bounds.width, accuracy: 0.001)

        view.setFrameSize(NSSize(width: 64, height: 18))
        view.layout()
        XCTAssertTrue(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(
            view.scrollOverflow,
            view.measuredTextWidth - view.bounds.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            view.scrollDistance,
            view.scrollOverflow + view.edgeFadeInset,
            accuracy: 0.001
        )
        XCTAssertNil(view.layer?.mask)
        view.applyScrollOffsetForTesting(-1)
        XCTAssertTrue(view.isScrolling)
        XCTAssertTrue(view.showsEdgeFade)
        let restoredMask = try XCTUnwrap(view.layer?.mask as? CAGradientLayer)
        XCTAssertEqual(restoredMask.frame, view.layer?.bounds ?? view.bounds)
        XCTAssertEqual(restoredMask.startPoint, CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(restoredMask.endPoint, CGPoint(x: 1, y: 0.5))

        view.updateText(shortText)
        view.layout()
        XCTAssertFalse(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertEqual(view.scrollOverflow, 0, accuracy: 0.001)
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(view.accountLabel.frame.minX, view.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(view.accountLabel.frame.width, view.bounds.width, accuracy: 0.001)

        view.updateText(longText)
        view.layout()
        XCTAssertTrue(view.isScrollable)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertGreaterThan(view.scrollOverflow, 0)
    }

    func testAccountMarqueeStartsAnimationWhenAttachedAndFadesOnlyAfterActualOffset() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 18))
        let view = AccountMarqueeView(
            text: String(repeating: "long-account-name-", count: 8),
            font: .systemFont(ofSize: 13),
            textColor: .secondaryLabelColor,
            frame: container.bounds
        )
        defer { view.removeFromSuperview() }

        container.addSubview(view)

        XCTAssertTrue(view.isScrollable)
        XCTAssertNotNil(view.accountLabel.layer?.animation(forKey: AccountMarqueeView.animationKey))
        XCTAssertEqual(view.scrollOffset, 0, accuracy: 0.001)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertNil(view.layer?.mask)
        XCTAssertFalse(
            AccountMarqueeScrollState(
                offset: 0,
                overflow: view.scrollOverflow
            ).isActive
        )
        XCTAssertFalse(
            AccountMarqueeScrollState(
                offset: -0.25,
                overflow: view.scrollOverflow
            ).isActive
        )

        view.applyScrollOffsetForTesting(-1)
        XCTAssertTrue(view.isScrolling)
        XCTAssertEqual(view.scrollOffset, -1, accuracy: 0.001)
        XCTAssertTrue(view.showsEdgeFade)
        XCTAssertNotNil(view.layer?.mask as? CAGradientLayer)

        view.applyScrollOffsetForTesting(0)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)
        XCTAssertNil(view.layer?.mask)
    }

    func testAccountMarqueeSamplesPresentationOffsetDuringRealAnimation() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 18),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        let view = AccountMarqueeView(
            text: "account-alpha-20260827-singapore-long-identifier-beta-usage-quota-gamma-openai-official-delta-window-resize-epsilon-manual-check@example-super-long-domain.test",
            font: .systemFont(ofSize: 13),
            textColor: .secondaryLabelColor,
            frame: NSRect(x: 0, y: 0, width: 128, height: 18)
        )
        defer {
            view.removeFromSuperview()
            window.orderOut(nil)
        }

        window.contentView?.addSubview(view)
        ApplicationWindowPresentation.presentInBackground(window)

        XCTAssertTrue(view.isScrollable)
        XCTAssertEqual(view.scrollOffset, 0, accuracy: 0.001)
        XCTAssertFalse(view.isScrolling)
        XCTAssertFalse(view.showsEdgeFade)

        let animation = try XCTUnwrap(
            view.accountLabel.layer?.animation(
                forKey: AccountMarqueeView.animationKey
            ) as? CAKeyframeAnimation
        )
        let endpoint = try XCTUnwrap(animation.values?[2] as? NSNumber)
        XCTAssertEqual(endpoint.doubleValue, -Double(view.scrollDistance), accuracy: 0.001)

        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertLessThan(
            view.scrollOffset,
            -AccountMarqueeScrollState.activationThreshold
        )
        XCTAssertTrue(view.isScrolling)
        XCTAssertTrue(view.showsEdgeFade)
        XCTAssertNotNil(view.layer?.mask as? CAGradientLayer)

        let activeOffset = view.scrollOffset
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotEqual(view.scrollOffset, activeOffset, accuracy: 0.001)
    }

    func testAccountMarqueeSpeedsUpForLongerOverflowWithConcaveCurve() {
        let shortSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 120)
        let mediumSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 480)
        let longSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 1_200)
        let extremeSpeed = AccountMarqueeView.scrollSpeed(forOverflow: 12_000)

        XCTAssertGreaterThan(mediumSpeed, shortSpeed)
        XCTAssertGreaterThan(longSpeed, mediumSpeed)
        XCTAssertLessThan(
            longSpeed - mediumSpeed,
            mediumSpeed - shortSpeed
        )
        XCTAssertGreaterThan(extremeSpeed, longSpeed)
        XCTAssertLessThanOrEqual(extremeSpeed, 180)

        let shortAnimation = AccountMarqueeView.scrollAnimation(forOverflow: 120)
        let longAnimation = AccountMarqueeView.scrollAnimation(forOverflow: 1_200)
        XCTAssertGreaterThan(longAnimation.duration, shortAnimation.duration)
        XCTAssertEqual(longAnimation.repeatCount, .infinity)
    }

    func testLocalizedOverviewQuotaAndResetReuseAccountMarqueeLayout() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .german

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(
                email: "person@example.com",
                subscription: .proFiveX
            ),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false
        )
        let shortQuota = "7-Tage-Kontingent"
        let shortResetValue = "6d14"
        let shortReset = shortResetValue
        let longQuota = String(repeating: "7-Tage-Kontingent ", count: 4)
        let longReset = String(repeating: "6d14 ", count: 12)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let baselineFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true
        )
        controller.start(
            snapshot: .official("OpenAI Official", 77, shortQuota, shortResetValue, date),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let shortOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let shortMarquees = shortOverview.subviews.compactMap { $0 as? AccountMarqueeView }
        let shortQuotaView = try XCTUnwrap(
            shortMarquees.first { $0.accountLabel.stringValue == shortQuota }
        )
        let shortResetView = try XCTUnwrap(
            shortMarquees.first { $0.accountLabel.stringValue.contains(shortReset) }
        )
        XCTAssertFalse(shortQuotaView.isScrollable)
        XCTAssertFalse(shortQuotaView.showsEdgeFade)
        XCTAssertFalse(shortResetView.isScrollable)
        XCTAssertFalse(shortResetView.showsEdgeFade)
        XCTAssertGreaterThan(shortQuotaView.bounds.width, baselineFrames.quotaDetail.width)
        XCTAssertGreaterThan(shortResetView.bounds.width, try XCTUnwrap(baselineFrames.reset).width)
        XCTAssertEqual(shortQuotaView.accountLabel.frame.width, shortQuotaView.bounds.width)
        XCTAssertEqual(shortResetView.accountLabel.frame.width, shortResetView.bounds.width)

        controller.update(
            snapshot: .official("OpenAI Official", 78, longQuota, longReset, date),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let marquees = overview.subviews.compactMap { $0 as? AccountMarqueeView }
        let quota = try XCTUnwrap(
            marquees.first { $0.accountLabel.stringValue == longQuota }
        )
        let reset = try XCTUnwrap(
            marquees.first { $0.accountLabel.stringValue.contains(longReset) }
        )
        XCTAssertTrue(quota.isScrollable)
        XCTAssertTrue(reset.isScrollable)
        XCTAssertGreaterThan(quota.accountLabel.frame.width, quota.bounds.width)
        XCTAssertGreaterThan(reset.accountLabel.frame.width, reset.bounds.width)

        let amount = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first { $0.stringValue == "78%" }
        )
        let frames = baselineFrames
        let amountTextWidth = AccountMarqueeView.textWidth(
            of: amount.stringValue,
            font: try XCTUnwrap(amount.font)
        )
        let safeAmountMinX = max(amount.frame.minX, amount.frame.maxX - amountTextWidth)
        let expectedRightEdge = safeAmountMinX
        XCTAssertEqual(quota.frame.minX, frames.quotaDetail.minX)
        XCTAssertEqual(quota.frame.minY, frames.quotaDetail.minY)
        XCTAssertEqual(quota.frame.height, frames.quotaDetail.height)
        XCTAssertGreaterThan(quota.frame.width, frames.quotaDetail.width)
        XCTAssertEqual(quota.frame.maxX, expectedRightEdge, accuracy: 0.5)
        let resetFrame = try XCTUnwrap(frames.reset)
        XCTAssertEqual(reset.frame.minX, resetFrame.minX)
        XCTAssertEqual(reset.frame.minY, resetFrame.minY)
        XCTAssertEqual(reset.frame.height, resetFrame.height)
        XCTAssertGreaterThan(reset.frame.width, resetFrame.width)
        XCTAssertEqual(reset.frame.maxX, expectedRightEdge, accuracy: 0.5)
    }

    func testOfficialCodexMenuCardRendersIndependentFiveHourAndSevenDayRows() throws {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        func makeInput(
            lunaReserveDisplayMode: LunaReserveDisplayMode = .always,
            lunaReserveHideExhaustedQuota: Bool = false
        ) -> StatusItemController.MenuInput {
            StatusItemController.MenuInput(
                choices: [],
                quickSwitchSummaries: [:],
                activeClient: .codex,
                openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
                statusLinks: [],
                showQuickSwitchMenu: false,
                showOpenChatGPTMenu: false,
                showOpenCCSwitchMenu: false,
                showStatusMenu: false,
                lunaReserveDisplayMode: lunaReserveDisplayMode,
                lunaReserveHideExhaustedQuota: lunaReserveHideExhaustedQuota
            )
        }
        let input = makeInput()
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000,
                resetAt: date.addingTimeInterval(2 * 86_400)
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800,
                resetAt: date.addingTimeInterval(7 * 86_400)
            )
        ]

        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                tr(.keyResponseParsers7DayQuota2),
                "1h30m",
                date,
                windows: windows
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let expectedResetTexts = windows.map { $0.resetDisplayText()! }
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        )
        XCTAssertEqual(overview.bounds.size, frames.cardSize)

        let progressViews = overview.subviews.compactMap { $0 as? QuotaProgressView }
        XCTAssertEqual(progressViews.map(\.percentage), [80, 45])
        XCTAssertEqual(
            progressViews.map(\.frame),
            frames.quotaRows.map(\.progress)
        )
        let percentageLabels = allControls(of: overview, as: NSTextField.self)
            .filter { $0.stringValue == "80%" || $0.stringValue == "45%" }
        XCTAssertEqual(percentageLabels.count, 2)
        let expectedAmountTraits = NSFont.monospacedDigitSystemFont(
            ofSize: OpenCodexCardLayout.quotaAmountPointSize,
            weight: .semibold
        ).fontDescriptor.symbolicTraits.rawValue
        XCTAssertTrue(
            percentageLabels.allSatisfy {
                ($0.font?.pointSize ?? 0) == OpenCodexCardLayout.quotaAmountPointSize
                    && ($0.font?.fontDescriptor.symbolicTraits.rawValue ?? 0) == expectedAmountTraits
                    && $0.frame.height == OpenCodexCardLayout.quotaAmountHeight
            }
        )

        let quotaViews = overview.subviews.compactMap { $0 as? AccountMarqueeView }
            .filter {
                let value = $0.accountLabel.stringValue
                return value == tr(.keyResponseParsers5HourQuota)
                    || value == tr(.keyResponseParsers7DayQuota2)
                    || expectedResetTexts.contains(value)
            }
        XCTAssertEqual(
            quotaViews.map { $0.accountLabel.stringValue },
            [
                tr(.keyResponseParsers5HourQuota),
                expectedResetTexts[0],
                tr(.keyResponseParsers7DayQuota2),
                expectedResetTexts[1]
            ]
        )
        XCTAssertTrue(expectedResetTexts.allSatisfy { $0.contains(" · ") })
        XCTAssertNotEqual(expectedResetTexts[0], expectedResetTexts[1])
        let expectedBaseFrames = [
            frames.quotaRows[0].quotaDetail,
            frames.quotaRows[0].reset,
            frames.quotaRows[1].quotaDetail,
            frames.quotaRows[1].reset
        ]
        for (index, (view, expected)) in zip(quotaViews, expectedBaseFrames).enumerated() {
            let isReset = index == 1 || index == 3
            XCTAssertEqual(view.frame.minX, expected.minX)
            XCTAssertEqual(view.frame.minY, expected.minY)
            XCTAssertEqual(view.frame.height, expected.height)
            XCTAssertGreaterThanOrEqual(view.frame.width, expected.width)
            XCTAssertEqual(
                view.accountLabel.font?.pointSize ?? 0,
                isReset
                    ? OpenCodexCardLayout.quotaResetPointSize
                    : OpenCodexCardLayout.quotaDetailPointSize
            )
        }
        XCTAssertTrue(quotaViews.allSatisfy { $0.accountLabel.lineBreakMode == .byClipping })
        let expectedDetailTraits = NSFont.systemFont(
            ofSize: OpenCodexCardLayout.quotaDetailPointSize,
            weight: .medium
        ).fontDescriptor.symbolicTraits.rawValue
        let expectedResetTraits = NSFont.systemFont(
            ofSize: OpenCodexCardLayout.quotaResetPointSize,
            weight: .regular
        ).fontDescriptor.symbolicTraits.rawValue
        for (index, view) in quotaViews.enumerated() {
            let expectedTraits = index == 1 || index == 3
                ? expectedResetTraits
                : expectedDetailTraits
            XCTAssertEqual(
                view.accountLabel.font?.fontDescriptor.symbolicTraits.rawValue ?? 0,
                expectedTraits
            )
        }
        XCTAssertEqual(
            allControls(of: overview, as: NSTextField.self)
                .filter { $0.stringValue == "80%" || $0.stringValue == "45%" }
                .map(\.stringValue),
            ["80%", "45%"]
        )
        XCTAssertLessThanOrEqual(
            frames.quotaRows[0].quotaDetail.maxX,
            overview.bounds.maxX - 14
        )
        XCTAssertLessThanOrEqual(
            frames.quotaRows[1].quotaDetail.maxX,
            overview.bounds.maxX - 14
        )
        XCTAssertTrue(quotaViews.allSatisfy { $0.frame.maxX <= overview.bounds.maxX })

        let longWindows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: String(repeating: windows[0].label + " ", count: 8),
                daysText: windows[0].daysText,
                reset: String(repeating: "2d0h ", count: 8),
                durationSeconds: windows[0].durationSeconds
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: String(repeating: windows[1].label + " ", count: 8),
                daysText: windows[1].daysText,
                reset: String(repeating: "7d0h ", count: 8),
                durationSeconds: windows[1].durationSeconds
            )
        ]
        controller.update(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: longWindows
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let longOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let longQuotaViews = longOverview.subviews.compactMap { $0 as? AccountMarqueeView }
            .filter { view in
                let value = view.accountLabel.stringValue
                return value == longWindows[0].label
                    || value == longWindows[1].label
                    || value.contains("2d0h")
                    || value.contains("7d0h")
            }
        XCTAssertEqual(longQuotaViews.count, 4)
        XCTAssertTrue(longQuotaViews.allSatisfy { $0.isScrollable })
        XCTAssertTrue(longQuotaViews.allSatisfy { $0.frame.maxX <= longOverview.bounds.maxX })

        let reserve = LunaReserveQuota(status: .available, remaining: 45, reset: "1h30m")
        XCTAssertEqual(reserve.menuTitleText, "🌙 Luna Reserve")
        XCTAssertEqual(reserve.menuSubtitleText, "1h30m")
        controller.update(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                lunaReserve: reserve
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let reserveOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let reserveFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesLunaReserve: true
        )
        XCTAssertEqual(reserveOverview.bounds.size, reserveFrames.cardSize)
        XCTAssertEqual(
            reserveOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [80, 45, 45]
        )
        XCTAssertNotNil(
            reserveOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == reserve.menuTitleText
            }
        )
        XCTAssertNotNil(
            reserveOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == reserve.menuSubtitleText
            }
        )

        let unavailableReserve = LunaReserveQuota(status: .unavailable, remaining: nil, reset: nil)
        XCTAssertEqual(unavailableReserve.menuTitleText, "🌙 Luna Reserve")
        XCTAssertEqual(unavailableReserve.menuSubtitleText, "Luna Reserve temporarily unavailable")
        controller.update(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                lunaReserve: unavailableReserve
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let unavailableOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let unavailableFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesLunaReserve: true,
            includesLunaReserveProgress: false
        )
        XCTAssertEqual(unavailableOverview.bounds.size, unavailableFrames.cardSize)
        XCTAssertEqual(
            unavailableOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [80, 45]
        )
        XCTAssertNotNil(
            unavailableOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == unavailableReserve.menuTitleText
            }
        )
        XCTAssertNotNil(
            unavailableOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == unavailableReserve.menuSubtitleText
            }
        )

        let exhaustedWindows = [
            OfficialQuotaWindow(
                kind: windows[0].kind,
                remaining: 0,
                label: windows[0].label,
                daysText: windows[0].daysText,
                reset: windows[0].reset,
                durationSeconds: windows[0].durationSeconds,
                resetAt: windows[0].resetAt
            ),
            windows[1]
        ]
        let exhaustedSnapshot = Snapshot.official(
            "OpenAI Official",
            45,
            exhaustedWindows[1].label,
            exhaustedWindows[1].reset,
            date,
            windows: exhaustedWindows,
            lunaReserve: reserve
        )
        controller.update(
            snapshot: exhaustedSnapshot,
            refreshDate: date,
            menuInput: makeInput(lunaReserveDisplayMode: .whenQuotaExhausted),
            settings: settings
        )
        let thresholdOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(
            thresholdOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [0, 45, 45]
        )
        XCTAssertNotNil(
            thresholdOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == reserve.menuTitleText
            }
        )

        controller.update(
            snapshot: exhaustedSnapshot,
            refreshDate: date,
            menuInput: makeInput(
                lunaReserveDisplayMode: .whenQuotaExhausted,
                lunaReserveHideExhaustedQuota: true
            ),
            settings: settings
        )
        let hiddenExhaustedOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(
            hiddenExhaustedOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [45, 45]
        )
        XCTAssertFalse(
            allControls(of: hiddenExhaustedOverview, as: NSTextField.self)
                .contains { $0.stringValue == "0%" }
        )
        XCTAssertNotNil(
            hiddenExhaustedOverview.subviews.compactMap { $0 as? AccountMarqueeView }.first {
                $0.accountLabel.stringValue == reserve.menuTitleText
            }
        )

        controller.update(
            snapshot: exhaustedSnapshot,
            refreshDate: date,
            menuInput: makeInput(
                lunaReserveDisplayMode: .disabled,
                lunaReserveHideExhaustedQuota: true
            ),
            settings: settings
        )
        let disabledOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        XCTAssertEqual(
            disabledOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [0, 45]
        )
        XCTAssertFalse(
            disabledOverview.subviews.compactMap { $0 as? AccountMarqueeView }.contains {
                $0.accountLabel.stringValue == reserve.menuTitleText
            }
        )
    }

    func testOfficialCodexMenuCardOmitsQuotaProgressViewsWhenProgressBarIsHidden() throws {
        LunaReserveUserFacing.testOverride = true
        defer { LunaReserveUserFacing.testOverride = nil }
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false,
            lunaReserveDisplayMode: .always,
            lunaReserveHideExhaustedQuota: false
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            showQuotaProgressBar: false
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000,
                resetAt: date.addingTimeInterval(2 * 86_400)
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800,
                resetAt: date.addingTimeInterval(7 * 86_400)
            )
        ]
        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                tr(.keyResponseParsers7DayQuota2),
                "1h30m",
                date,
                windows: windows
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesQuotaProgress: false
        )
        XCTAssertEqual(overview.bounds.size, frames.cardSize)
        XCTAssertTrue(overview.subviews.compactMap { $0 as? QuotaProgressView }.isEmpty)
        let withProgressHeight = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesQuotaProgress: true
        ).cardSize.height
        XCTAssertEqual(
            frames.cardSize.height + 2 * (
                OpenCodexCardLayout.quotaRowHeight - OpenCodexCardLayout.lunaReserveNoProgressRowHeight
            ),
            withProgressHeight
        )
        let percentageLabels = allControls(of: overview, as: NSTextField.self)
            .filter { $0.stringValue == "80%" || $0.stringValue == "45%" }
        XCTAssertEqual(percentageLabels.count, 2)
        XCTAssertTrue(
            percentageLabels.allSatisfy {
                $0.frame.height == OpenCodexCardLayout.lunaReserveNoProgressAmountHeight
            }
        )
    }

    func testOfficialCodexMenuCardRendersBankedResetSummaryAndDetailRowsWithoutReserve() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .english

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false,
            lunaReserveDisplayMode: .always
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800
            )
        ]
        let earlier = date.addingTimeInterval(6 * 3_600)
        let later = date.addingTimeInterval((1 * 86_400) + (4 * 3_600))
        let earlierRemaining = try XCTUnwrap(
            CodexBankedResetFormatting.remaining(until: earlier, now: date)
        )
        let laterRemaining = try XCTUnwrap(
            CodexBankedResetFormatting.remaining(until: later, now: date)
        )
        XCTAssertTrue(earlierRemaining.isWarning)
        XCTAssertFalse(laterRemaining.isWarning)
        let bankedReset = CodexBankedReset(cards: [
                CodexBankedResetCard(
                    id: "earlier",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    windowText: tr(.keyCodexBankedResetFullResetWindow),
                    expiresAt: earlier,
                    expiresText: CodexBankedResetFormatting.expiryText(
                        for: earlier,
                        relativeTo: date
                    ),
                    remainingText: earlierRemaining.text,
                    remainingIsWarning: earlierRemaining.isWarning
                ),
                CodexBankedResetCard(
                    id: "later",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    windowText: tr(.keyCodexBankedResetFullResetWindow),
                    expiresAt: later,
                    expiresText: CodexBankedResetFormatting.expiryText(
                        for: later,
                        relativeTo: date
                    ),
                    remainingText: laterRemaining.text,
                    remainingIsWarning: laterRemaining.isWarning
                )
            ])

        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                lunaReserve: LunaReserveQuota(status: .available, remaining: 61, reset: "2h"),
                bankedReset: bankedReset,
                resetForecast: .demo(updatedAt: date)
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 2
        )
        XCTAssertEqual(overview.bounds.size, frames.cardSize)
        XCTAssertEqual(
            overview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [80, 45]
        )
        let labels = allControls(of: overview, as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains("80%"))
        XCTAssertTrue(labels.contains("45%"))
        XCTAssertFalse(labels.contains("2%"))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetTitle)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetProbabilityPrefix)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetProbability24h)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetProbability48h)))
        XCTAssertTrue(labels.contains("24%"))
        XCTAssertTrue(labels.contains("42%"))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetConfidencePrefix)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetConfidenceLow)))
        XCTAssertFalse(labels.contains("--%"))
        XCTAssertTrue(labels.contains(" · ") || labels.contains("·"))
        XCTAssertFalse(labels.contains { $0.contains("…") || $0.hasSuffix("...") })
        let largeAmounts = allControls(of: overview, as: NSTextField.self).filter {
            $0.font?.pointSize == OpenCodexCardLayout.quotaAmountPointSize
        }
        XCTAssertTrue(largeAmounts.contains { $0.stringValue == "2" })
        XCTAssertFalse(
            overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.badge" }
        )
        let countField = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.count"
            }
        )
        XCTAssertEqual(countField.stringValue, "2")
        XCTAssertEqual(
            countField.font?.pointSize,
            OpenCodexCardLayout.quotaAmountPointSize
        )
        XCTAssertEqual(countField.alignment, .right)
        let chromes = overview.subviews.filter {
            $0.identifier?.rawValue == "codex.bankedReset.chrome"
        }
        XCTAssertEqual(chromes.count, 2)
        XCTAssertEqual(chromes[0].frame.width, chromes[1].frame.width, accuracy: 0.001)
        XCTAssertEqual(chromes[0].frame.width, frames.bankedResetDetailRows[0].chrome.width)
        XCTAssertEqual(chromes.map(\.frame), frames.bankedResetDetailRows.map(\.chrome))
        XCTAssertEqual(
            labels.filter { $0 == tr(.keyCodexBankedResetFullResetTitle) }.count,
            2
        )
        XCTAssertFalse(labels.contains { $0.contains("完全重置（") || $0.contains("Full reset (weekly") })
        XCTAssertEqual(
            labels.filter { $0 == tr(.keyCodexBankedResetFullResetWindow) }.count,
            2
        )
        XCTAssertTrue(labels.contains(bankedReset.cards[0].expiresText ?? ""))
        XCTAssertTrue(labels.contains(bankedReset.cards[1].expiresText ?? ""))
        XCTAssertTrue(labels.contains(earlierRemaining.text))
        XCTAssertTrue(labels.contains(laterRemaining.text))
        XCTAssertFalse(labels.contains { $0.contains("GMT") })
        let remainingFields = allControls(of: overview, as: NSTextField.self).filter {
            $0.identifier?.rawValue == "codex.bankedReset.remaining"
        }
        XCTAssertEqual(remainingFields.map(\.stringValue), [
            earlierRemaining.text,
            laterRemaining.text
        ])
        XCTAssertFalse(remainingFields.contains { $0.stringValue.contains("剩余") })
        XCTAssertFalse(remainingFields.contains { $0.stringValue.contains("剩餘") })
        XCTAssertFalse(remainingFields.contains { $0.stringValue.contains("Remaining") })
        XCTAssertEqual(remainingFields[0].textColor, NSColor.systemOrange)
        XCTAssertEqual(remainingFields[1].textColor, NSColor.labelColor)
        XCTAssertEqual(
            remainingFields[0].frame.midY,
            frames.bankedResetDetailRows[0].chrome.midY,
            accuracy: 1
        )
        XCTAssertEqual(
            remainingFields[1].frame.midY,
            frames.bankedResetDetailRows[1].chrome.midY,
            accuracy: 1
        )
        let probabilityLink = try XCTUnwrap(
            allControls(of: overview, as: HoverLinkTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability"
            }
        )
        XCTAssertEqual(probabilityLink.stringValue, tr(.keyCodexBankedResetProbabilityPrefix))
        XCTAssertEqual(
            probabilityLink.hoverHintDelay,
            OpenCodexCardLayout.bankedResetProbabilityHoverHintDelay,
            accuracy: 0.001
        )
        XCTAssertEqual(
            probabilityLink.hoverHint,
            StatusItemController.codexResetForecastHint(for: .demo(updatedAt: date))
        )
        XCTAssertNil(probabilityLink.toolTip)
        XCTAssertEqual(
            probabilityLink.identifier?.rawValue,
            "codex.bankedReset.probability"
        )
        XCTAssertEqual(probabilityLink.lineBreakMode, .byClipping)
        XCTAssertGreaterThanOrEqual(
            probabilityLink.frame.width,
            AccountMarqueeView.textWidth(
                of: tr(.keyCodexBankedResetProbabilityPrefix),
                font: probabilityLink.font ?? .systemFont(ofSize: 12, weight: .medium)
            ) + 4
        )
        XCTAssertEqual(
            probabilityLink.attributedStringValue.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.linkColor
        )
        XCTAssertFalse(
            allControls(of: overview, as: HoverLinkTextField.self).contains {
                $0.stringValue.hasSuffix("%")
            }
        )
        let percent24 = try XCTUnwrap(
            allControls(of: overview, as: OverviewNumericTextView.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability24h"
            }
        )
        let percent48 = try XCTUnwrap(
            allControls(of: overview, as: OverviewNumericTextView.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability48h"
            }
        )
        XCTAssertEqual(percent24.textField.stringValue, "24%")
        XCTAssertEqual(percent48.textField.stringValue, "42%")
        XCTAssertEqual(percent24.textField.textColor, NSColor.secondaryLabelColor)
        XCTAssertEqual(percent48.textField.textColor, NSColor.secondaryLabelColor)
        XCTAssertEqual(percent24.textField.lineBreakMode, .byClipping)
        XCTAssertEqual(percent48.textField.lineBreakMode, .byClipping)
        let prefix24 = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability24hPrefix"
            }
        )
        let prefix48 = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability48hPrefix"
            }
        )
        let confidencePrefix = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.confidencePrefix"
            }
        )
        let confidence = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.confidence"
            }
        )
        XCTAssertEqual(confidence.stringValue, tr(.keyCodexBankedResetConfidenceLow))
        XCTAssertEqual(confidence.textColor, NSColor.secondaryLabelColor)
        XCTAssertFalse(confidence is HoverLinkTextField)
        assertBankedResetForecastSubtitleFullyVisible(
            prefix24,
            expected: tr(.keyCodexBankedResetProbability24h)
        )
        assertBankedResetForecastSubtitleFullyVisible(
            prefix48,
            expected: tr(.keyCodexBankedResetProbability48h)
        )
        assertBankedResetForecastSubtitleFullyVisible(
            confidencePrefix,
            expected: tr(.keyCodexBankedResetConfidencePrefix)
        )
        assertBankedResetForecastSubtitleFullyVisible(
            confidence,
            expected: tr(.keyCodexBankedResetConfidenceLow)
        )
        let firstChrome = try XCTUnwrap(chromes.first)
        XCTAssertGreaterThan(
            probabilityLink.frame.minY,
            firstChrome.frame.maxY
        )
        XCTAssertGreaterThan(probabilityLink.frame.minY, percent24.frame.minY)
        XCTAssertEqual(percent24.frame.minY, percent48.frame.minY, accuracy: 0.001)
        XCTAssertLessThan(percent24.frame.maxX, percent48.frame.minX)
        let separator = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probabilitySeparator"
            }
        )
        XCTAssertTrue(
            separator.stringValue == " · " || separator.stringValue == "·",
            "separator should be a middot, got \(separator.stringValue)"
        )
        assertBankedResetForecastSubtitleFullyVisible(
            separator,
            expected: separator.stringValue
        )
        XCTAssertEqual(separator.frame.minY, percent24.frame.minY, accuracy: 0.001)
        XCTAssertEqual(separator.frame.minX, percent24.frame.maxX, accuracy: 0.001)
        XCTAssertEqual(separator.frame.maxX, prefix48.frame.minX, accuracy: 0.001)
        XCTAssertGreaterThan(percent24.frame.minY, confidence.frame.minY)
        XCTAssertGreaterThan(confidence.frame.minY, firstChrome.frame.maxY)
        let resetTitle = try XCTUnwrap(
            allControls(of: overview, as: AccountMarqueeView.self).first {
                $0.accountLabel.stringValue == tr(.keyCodexBankedResetTitle)
            }
        )
        assertBankedResetSummaryLeadingAligned(
            in: overview,
            title: resetTitle,
            probabilityLink: probabilityLink,
            prefix24: prefix24,
            confidencePrefix: confidencePrefix
        )
        let tickets = overview.subviews.filter {
            $0.identifier?.rawValue == "codex.bankedReset.ticket"
        }
        XCTAssertEqual(tickets.count, 2)
        let firstTicket = try XCTUnwrap(tickets.first)
        let firstTitle = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == tr(.keyCodexBankedResetFullResetTitle)
                    && abs($0.frame.minY - frames.bankedResetDetailRows[0].quotaDetail.minY) < 0.5
            }
        )
        let firstWindow = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == tr(.keyCodexBankedResetFullResetWindow)
                    && abs($0.frame.minY - frames.bankedResetDetailRows[0].window.minY) < 0.5
            }
        )
        let firstExpiry = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.stringValue == (bankedReset.cards[0].expiresText ?? "")
            }
        )
        XCTAssertEqual(
            firstTicket.frame.midY,
            (
                min(firstTitle.frame.minY, firstWindow.frame.minY, firstExpiry.frame.minY)
                    + max(firstTitle.frame.maxY, firstWindow.frame.maxY, firstExpiry.frame.maxY)
            ) / 2,
            accuracy: 1
        )
        XCTAssertFalse(labels.contains { $0.contains("🌙") })
        XCTAssertFalse(labels.contains(tr(.keyLunaReserveTitle)))
        XCTAssertEqual(controller.menuBarPrimaryTextForTesting, "80%")

        controller.update(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )
        let emptyOverview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let emptyFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        )
        XCTAssertEqual(emptyOverview.bounds.size, emptyFrames.cardSize)
        XCTAssertFalse(
            allControls(of: emptyOverview, as: NSTextField.self)
                .contains { $0.stringValue == tr(.keyCodexBankedResetTitle) }
        )
        XCTAssertEqual(
            emptyOverview.subviews.compactMap { $0 as? QuotaProgressView }.map(\.percentage),
            [80, 45]
        )
    }

    func testOfficialCodexMenuCardCompactBankedResetShowsCountWithoutDetailCards() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false,
            bankedResetDisplayMode: .compact
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800
            )
        ]
        let earlier = date.addingTimeInterval(6 * 3_600)
        let bankedReset = CodexBankedReset(cards: [
                CodexBankedResetCard(
                    id: "earlier",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    windowText: tr(.keyCodexBankedResetFullResetWindow),
                    expiresAt: earlier,
                    expiresText: CodexBankedResetFormatting.expiryText(
                        for: earlier,
                        relativeTo: date
                    ),
                    remainingText: "6h",
                    remainingIsWarning: true
                ),
                CodexBankedResetCard(
                    id: "later",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    windowText: tr(.keyCodexBankedResetFullResetWindow),
                    expiresAt: earlier.addingTimeInterval(86_400),
                    expiresText: CodexBankedResetFormatting.expiryText(
                        for: earlier.addingTimeInterval(86_400),
                        relativeTo: date
                    ),
                    remainingText: "1d",
                    remainingIsWarning: false
                )
            ])

        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                bankedReset: bankedReset,
                resetForecast: .demo(updatedAt: date)
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 2,
            bankedResetDisplayMode: .compact
        )
        XCTAssertEqual(overview.bounds.size, frames.cardSize)
        XCTAssertTrue(frames.bankedResetDetailRows.isEmpty)
        let labels = allControls(of: overview, as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetTitle)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetProbabilityPrefix)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetProbability24h)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetProbability48h)))
        XCTAssertTrue(labels.contains("24%"))
        XCTAssertTrue(labels.contains("42%"))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetConfidencePrefix)))
        XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetConfidenceLow)))
        XCTAssertTrue(labels.contains("2"))
        XCTAssertTrue(labels.contains(" · ") || labels.contains("·"))
        XCTAssertFalse(labels.contains { $0.contains("…") || $0.hasSuffix("...") })
        XCTAssertFalse(labels.contains(tr(.keyCodexBankedResetFullResetTitle)))
        XCTAssertFalse(overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.badge" })
        XCTAssertFalse(overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.ticket" })
        XCTAssertFalse(overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.chrome" })
        let countField = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.count"
            }
        )
        XCTAssertEqual(countField.stringValue, "2")
        XCTAssertEqual(
            countField.font?.pointSize,
            OpenCodexCardLayout.quotaAmountPointSize
        )
        let probabilityLink = try XCTUnwrap(
            allControls(of: overview, as: HoverLinkTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability"
            }
        )
        XCTAssertEqual(probabilityLink.stringValue, tr(.keyCodexBankedResetProbabilityPrefix))
        XCTAssertEqual(
            probabilityLink.hoverHintDelay,
            OpenCodexCardLayout.bankedResetProbabilityHoverHintDelay,
            accuracy: 0.001
        )
        XCTAssertEqual(
            probabilityLink.hoverHint,
            StatusItemController.codexResetForecastHint(for: .demo(updatedAt: date))
        )
        XCTAssertNil(probabilityLink.toolTip)
        let prefix24 = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability24hPrefix"
            }
        )
        let prefix48 = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability48hPrefix"
            }
        )
        let percent24 = try XCTUnwrap(
            allControls(of: overview, as: OverviewNumericTextView.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability24h"
            }
        )
        let percent48 = try XCTUnwrap(
            allControls(of: overview, as: OverviewNumericTextView.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probability48h"
            }
        )
        let confidencePrefix = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.confidencePrefix"
            }
        )
        let confidence = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.confidence"
            }
        )
        assertBankedResetForecastSubtitleFullyVisible(
            prefix24,
            expected: tr(.keyCodexBankedResetProbability24h)
        )
        assertBankedResetForecastSubtitleFullyVisible(
            prefix48,
            expected: tr(.keyCodexBankedResetProbability48h)
        )
        assertBankedResetForecastSubtitleFullyVisible(
            confidencePrefix,
            expected: tr(.keyCodexBankedResetConfidencePrefix)
        )
        assertBankedResetForecastSubtitleFullyVisible(
            confidence,
            expected: tr(.keyCodexBankedResetConfidenceLow)
        )
        XCTAssertEqual(percent24.frame.minY, percent48.frame.minY, accuracy: 0.001)
        XCTAssertLessThan(percent24.frame.maxX, percent48.frame.minX)
        let separator = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.probabilitySeparator"
            }
        )
        XCTAssertTrue(
            separator.stringValue == " · " || separator.stringValue == "·",
            "separator should be a middot, got \(separator.stringValue)"
        )
        assertBankedResetForecastSubtitleFullyVisible(
            separator,
            expected: separator.stringValue
        )
        XCTAssertEqual(separator.frame.minY, percent24.frame.minY, accuracy: 0.001)
        XCTAssertGreaterThan(percent24.frame.minY, confidence.frame.minY)
        let resetTitle = try XCTUnwrap(
            allControls(of: overview, as: AccountMarqueeView.self).first {
                $0.accountLabel.stringValue == tr(.keyCodexBankedResetTitle)
            }
        )
        assertBankedResetSummaryLeadingAligned(
            in: overview,
            title: resetTitle,
            probabilityLink: probabilityLink,
            prefix24: prefix24,
            confidencePrefix: confidencePrefix
        )
    }

    func testOfficialCodexMenuBankedResetForecastCopyFitsEveryBundledLanguage() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false,
            lunaReserveDisplayMode: .always
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: "5h",
                daysText: "5h",
                reset: "2d0h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: "7d",
                daysText: "7d",
                reset: "7d0h",
                durationSeconds: 604_800
            )
        ]
        let bankedReset = CodexBankedReset(cards: [
            CodexBankedResetCard(
                id: "card",
                resetType: "codex_rate_limits",
                titleText: "Reset",
                windowText: "Window",
                expiresAt: date.addingTimeInterval(3_600),
                expiresText: "later",
                remainingText: "1h",
                remainingIsWarning: false
            )
        ])
        let subtitleFont = OpenCodexCardLayout.bankedResetForecastSubtitleFont
        let numericFont = OpenCodexCardLayout.bankedResetForecastNumericFont
        for language in AppLanguage.allCases where language != .system {
            AppLanguage.selected = language
            controller.start(
                snapshot: .official(
                    "OpenAI Official",
                    45,
                    windows[1].label,
                    windows[1].reset,
                    date,
                    windows: windows,
                    bankedReset: bankedReset,
                    resetForecast: .demo(updatedAt: date)
                ),
                refreshDate: date,
                menuInput: input,
                settings: settings
            )
            let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
            let prefix24 = try XCTUnwrap(
                allControls(of: overview, as: NSTextField.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.probability24hPrefix"
                }
            )
            let prefix48 = try XCTUnwrap(
                allControls(of: overview, as: NSTextField.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.probability48hPrefix"
                }
            )
            let percent24 = try XCTUnwrap(
                allControls(of: overview, as: OverviewNumericTextView.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.probability24h"
                }
            )
            let percent48 = try XCTUnwrap(
                allControls(of: overview, as: OverviewNumericTextView.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.probability48h"
                }
            )
            let confidencePrefix = try XCTUnwrap(
                allControls(of: overview, as: NSTextField.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.confidencePrefix"
                }
            )
            let confidence = try XCTUnwrap(
                allControls(of: overview, as: NSTextField.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.confidence"
                }
            )
            assertBankedResetForecastSubtitleFullyVisible(
                prefix24,
                expected: tr(.keyCodexBankedResetProbability24h, language: language)
            )
            assertBankedResetForecastSubtitleFullyVisible(
                prefix48,
                expected: tr(.keyCodexBankedResetProbability48h, language: language)
            )
            assertBankedResetForecastSubtitleFullyVisible(
                confidencePrefix,
                expected: tr(.keyCodexBankedResetConfidencePrefix, language: language)
            )
            assertBankedResetForecastSubtitleFullyVisible(
                confidence,
                expected: tr(.keyCodexBankedResetConfidenceLow, language: language)
            )
            XCTAssertEqual(percent24.textField.stringValue, "24%")
            XCTAssertEqual(percent48.textField.stringValue, "42%")
            XCTAssertGreaterThanOrEqual(
                percent24.frame.width,
                AccountMarqueeView.textWidth(of: "24%", font: numericFont)
            )
            XCTAssertGreaterThanOrEqual(
                percent48.frame.width,
                AccountMarqueeView.textWidth(of: "42%", font: numericFont)
            )
            let packing = OpenCodexCardLayout.BankedResetForecastMetricsPacking.make(
                prefix24: tr(.keyCodexBankedResetProbability24h, language: language),
                percent24: "100%",
                prefix48: tr(.keyCodexBankedResetProbability48h, language: language),
                percent48: "100%"
            )
            XCTAssertLessThanOrEqual(
                packing.totalWidth,
                OpenCodexCardLayout.cardWidth - OpenCodexCardLayout.horizontalInset,
                "24h+48h overflow in \(language.rawValue)"
            )
            XCTAssertEqual(percent24.frame.minY, percent48.frame.minY, accuracy: 0.001)
            XCTAssertLessThan(percent24.frame.maxX, percent48.frame.minX)
            let separator = try XCTUnwrap(
                allControls(of: overview, as: NSTextField.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.probabilitySeparator"
                }
            )
            XCTAssertTrue(
                separator.stringValue == " · " || separator.stringValue == "·",
                "separator should be a middot in \(language.rawValue), got \(separator.stringValue)"
            )
            assertBankedResetForecastSubtitleFullyVisible(
                separator,
                expected: separator.stringValue
            )
            XCTAssertEqual(separator.frame.minY, percent24.frame.minY, accuracy: 0.001)
            XCTAssertGreaterThan(percent24.frame.minY, confidence.frame.minY)
            let resetTitle = try XCTUnwrap(
                allControls(of: overview, as: AccountMarqueeView.self).first {
                    $0.accountLabel.stringValue == tr(.keyCodexBankedResetTitle, language: language)
                }
            )
            assertBankedResetSummaryLeadingAligned(
                in: overview,
                title: resetTitle,
                probabilityLink: try XCTUnwrap(
                    allControls(of: overview, as: HoverLinkTextField.self).first {
                        $0.identifier?.rawValue == "codex.bankedReset.probability"
                    }
                ),
                prefix24: prefix24,
                confidencePrefix: confidencePrefix
            )
            let longestConfidence = [
                tr(.keyCodexBankedResetConfidenceLow, language: language),
                tr(.keyCodexBankedResetConfidenceMedium, language: language),
                tr(.keyCodexBankedResetConfidenceHigh, language: language),
                "--"
            ].map { AccountMarqueeView.textWidth(of: $0, font: subtitleFont) }.max() ?? 0
            XCTAssertLessThanOrEqual(
                confidencePrefix.frame.width + 4 + longestConfidence + 4,
                OpenCodexCardLayout.contentWidth,
                "confidence row overflow in \(language.rawValue)"
            )
            let hint = StatusItemController.codexResetForecastHint(
                for: .demo(updatedAt: date)
            )
            let hintLayout = DashboardTextTooltipLayout.make(
                for: hint,
                font: DashboardTextTooltip.font
            )
            XCTAssertTrue(hintLayout.wraps, "hint should wrap for \(language.rawValue)")
            XCTAssertEqual(hintLayout.textWidth, DashboardTextTooltipLayout.maximumTextWidth)
        }
    }

    func testOfficialCodexMenuCardHidesBankedResetWhenShowBankedResetIsOff() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false,
            bankedResetDisplayMode: .detailed
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true,
            showBankedReset: false
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800
            )
        ]
        let earlier = date.addingTimeInterval(6 * 3_600)
        let bankedReset = CodexBankedReset(cards: [
                CodexBankedResetCard(
                    id: "earlier",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    windowText: tr(.keyCodexBankedResetFullResetWindow),
                    expiresAt: earlier,
                    expiresText: CodexBankedResetFormatting.expiryText(
                        for: earlier,
                        relativeTo: date
                    ),
                    remainingText: "6h",
                    remainingIsWarning: true
                )
            ])

        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                bankedReset: bankedReset,
                resetForecast: .demo(updatedAt: date)
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let hiddenFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: false,
            bankedResetCardCount: 1,
            bankedResetDisplayMode: .detailed
        )
        let shownFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 1,
            bankedResetDisplayMode: .detailed
        )
        XCTAssertEqual(overview.bounds.size, hiddenFrames.cardSize)
        XCTAssertEqual(hiddenFrames.cardSize, OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows
        ).cardSize)
        XCTAssertGreaterThan(shownFrames.cardSize.height, hiddenFrames.cardSize.height)
        XCTAssertNil(hiddenFrames.bankedResetSummaryRow)
        XCTAssertTrue(hiddenFrames.bankedResetDetailRows.isEmpty)
        let labels = allControls(of: overview, as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains(tr(.keyResponseParsers5HourQuota)))
        XCTAssertTrue(labels.contains(tr(.keyResponseParsers7DayQuota2)))
        XCTAssertTrue(labels.contains("80%"))
        XCTAssertTrue(labels.contains("45%"))
        XCTAssertFalse(labels.contains(tr(.keyCodexBankedResetTitle)))
        XCTAssertFalse(labels.contains(tr(.keyCodexBankedResetProbabilityPrefix)))
        XCTAssertFalse(labels.contains(tr(.keyCodexBankedResetFullResetTitle)))
        XCTAssertFalse(overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.count" })
        XCTAssertFalse(overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.ticket" })
        XCTAssertFalse(overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.chrome" })
    }

    func testOfficialCodexMenuCardShowsZeroCountBankedResetInCompactAndDetailed() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800
            )
        ]
        let date = Date()
        let expectedFrames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 0,
            bankedResetDisplayMode: .compact
        )
        XCTAssertNotNil(expectedFrames.bankedResetSummaryRow)
        XCTAssertTrue(expectedFrames.bankedResetDetailRows.isEmpty)

        for mode in [CodexBankedResetDisplayMode.compact, .detailed] {
            let controller = StatusItemController(
                actions: StatusItemController.Actions(
                    manualRefresh: {},
                    openDashboard: {},
                    openChatGPT: {},
                    openCCSwitch: {},
                    quit: {},
                    switchProvider: { _ in },
                    openProviderWebsite: {},
                    openStatusLink: { _ in },
                    iconChanged: { _ in }
                )
            )
            defer { controller.teardown() }

            let input = StatusItemController.MenuInput(
                choices: [],
                quickSwitchSummaries: [:],
                activeClient: .codex,
                openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
                statusLinks: [],
                showQuickSwitchMenu: false,
                showOpenChatGPTMenu: false,
                showOpenCCSwitchMenu: false,
                showStatusMenu: false,
                bankedResetDisplayMode: mode
            )
            controller.start(
                snapshot: .official(
                    "OpenAI Official",
                    45,
                    windows[1].label,
                    windows[1].reset,
                    date,
                    windows: windows,
                    bankedReset: CodexBankedReset(cards: []),
                    resetForecast: .demo(updatedAt: date)
                ),
                refreshDate: date,
                menuInput: input,
                settings: StatusItemController.MenuBarSettings(
                    showIcon: true,
                    showAmount: true,
                    showReset: true,
                    horizontalPadding: 6,
                    keepMenuOpenAfterRefresh: true
                )
            )

            let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
            let frames = OpenCodexCardLayout.frames(
                for: .quota,
                includesAccount: true,
                includesSubscription: true,
                officialQuotaWindows: windows,
                includesBankedReset: true,
                bankedResetCardCount: 0,
                bankedResetDisplayMode: mode
            )
            XCTAssertEqual(overview.bounds.size, frames.cardSize, "card size for \(mode)")
            XCTAssertEqual(frames.cardSize, expectedFrames.cardSize, "0-count \(mode) matches compact summary")
            XCTAssertNotNil(frames.bankedResetSummaryRow, "summary row for \(mode)")
            XCTAssertTrue(frames.bankedResetDetailRows.isEmpty, "no tickets for 0-count \(mode)")
            let labels = allControls(of: overview, as: NSTextField.self).map(\.stringValue)
            XCTAssertTrue(labels.contains(tr(.keyResponseParsers5HourQuota)), "5h for \(mode)")
            XCTAssertTrue(labels.contains(tr(.keyResponseParsers7DayQuota2)), "7d for \(mode)")
            XCTAssertTrue(labels.contains(tr(.keyCodexBankedResetTitle)), "reset title for \(mode)")
            let countField = try XCTUnwrap(
                allControls(of: overview, as: NSTextField.self).first {
                    $0.identifier?.rawValue == "codex.bankedReset.count"
                },
                "count field for \(mode)"
            )
            XCTAssertEqual(countField.stringValue, "0", "count 0 for \(mode)")
            XCTAssertFalse(
                overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.ticket" },
                "no tickets for \(mode)"
            )
            XCTAssertFalse(
                overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.chrome" },
                "no chrome for \(mode)"
            )
        }
    }

    func testOfficialCodexMenuCardDetailedBankedResetClipsTicketsToTwoAndAHalfRows() throws {
        let previousLanguage = AppLanguage.selected
        defer { AppLanguage.selected = previousLanguage }
        AppLanguage.selected = .simplifiedChinese

        let controller = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: {},
                openDashboard: {},
                openChatGPT: {},
                openCCSwitch: {},
                quit: {},
                switchProvider: { _ in },
                openProviderWebsite: {},
                openStatusLink: { _ in },
                iconChanged: { _ in }
            )
        )
        defer { controller.teardown() }

        let input = StatusItemController.MenuInput(
            choices: [],
            quickSwitchSummaries: [:],
            activeClient: .codex,
            openAIAccount: OpenAIAccountPresentation(email: "person@example.com", subscription: .proFiveX),
            statusLinks: [],
            showQuickSwitchMenu: false,
            showOpenChatGPTMenu: false,
            showOpenCCSwitchMenu: false,
            showStatusMenu: false
        )
        let settings = StatusItemController.MenuBarSettings(
            showIcon: true,
            showAmount: true,
            showReset: true,
            horizontalPadding: 6,
            keepMenuOpenAfterRefresh: true
        )
        let date = Date()
        let windows = [
            OfficialQuotaWindow(
                kind: .fiveHour,
                remaining: 80,
                label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours),
                reset: "2d0h",
                durationSeconds: 18_000
            ),
            OfficialQuotaWindow(
                kind: .sevenDay,
                remaining: 45,
                label: tr(.keyResponseParsers7DayQuota2),
                daysText: tr(.keyResponseParsers7Days4),
                reset: "7d0h",
                durationSeconds: 604_800
            )
        ]
        var cards: [CodexBankedResetCard] = []
        cards.reserveCapacity(10)
        for index in 0..<10 {
            let expiresAt = date.addingTimeInterval(TimeInterval((index + 1) * 86_400))
            cards.append(
                CodexBankedResetCard(
                    id: "card-\(index)",
                    resetType: "codex_rate_limits",
                    titleText: tr(.keyCodexBankedResetFullResetTitle),
                    windowText: tr(.keyCodexBankedResetFullResetWindow),
                    expiresAt: expiresAt,
                    expiresText: CodexBankedResetFormatting.expiryText(
                        for: expiresAt,
                        relativeTo: date
                    ),
                    remainingText: "\(index + 1)d",
                    remainingIsWarning: index == 0
                )
            )
        }
        let bankedReset = CodexBankedReset(cards: cards)

        controller.start(
            snapshot: .official(
                "OpenAI Official",
                45,
                windows[1].label,
                windows[1].reset,
                date,
                windows: windows,
                bankedReset: bankedReset,
                resetForecast: .demo(updatedAt: date)
            ),
            refreshDate: date,
            menuInput: input,
            settings: settings
        )

        let overview = try XCTUnwrap(controller.menuItemsForTesting.first?.view)
        let frames = OpenCodexCardLayout.frames(
            for: .quota,
            includesAccount: true,
            includesSubscription: true,
            officialQuotaWindows: windows,
            includesBankedReset: true,
            bankedResetCardCount: 10
        )
        XCTAssertEqual(overview.bounds.size, frames.cardSize)
        XCTAssertFalse(
            overview.subviews.contains { $0.identifier?.rawValue == "codex.bankedReset.chrome" }
        )
        let scrollView = try XCTUnwrap(
            allControls(of: overview, as: BankedResetTicketScrollView.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.ticketScroll"
            }
        )
        XCTAssertEqual(scrollView.frame, try XCTUnwrap(frames.bankedResetTicketViewport))
        XCTAssertEqual(
            scrollView.frame.height,
            OpenCodexCardLayout.bankedResetTicketViewportMaxHeight,
            accuracy: 0.001
        )
        let document = try XCTUnwrap(scrollView.documentView)
        XCTAssertEqual(
            document.frame.height,
            OpenCodexCardLayout.bankedResetTicketStackHeight(cardCount: 10),
            accuracy: 0.001
        )
        let chromes = allControls(of: document, as: BankedResetChromeView.self)
        XCTAssertEqual(chromes.count, 10)
        XCTAssertEqual(
            chromes.map(\.frame),
            frames.bankedResetDetailRows.map(\.chrome)
        )
        XCTAssertEqual(
            allControls(of: overview, as: NSImageView.self).filter {
                $0.identifier?.rawValue == "codex.bankedReset.ticket"
            }.count,
            10
        )
        let remainingFields = allControls(of: overview, as: NSTextField.self).filter {
            $0.identifier?.rawValue == "codex.bankedReset.remaining"
        }
        XCTAssertEqual(remainingFields.count, 10)
        XCTAssertEqual(remainingFields.map(\.stringValue), cards.map { $0.remainingText ?? "" })
        let visibleMinY = scrollView.contentView.bounds.minY
        let visibleMaxY = visibleMinY + scrollView.contentView.bounds.height
        XCTAssertEqual(
            visibleMaxY,
            document.bounds.height,
            accuracy: 1
        )
        XCTAssertGreaterThanOrEqual(chromes[0].frame.minY, visibleMinY - 0.5)
        XCTAssertLessThanOrEqual(chromes[0].frame.maxY, visibleMaxY + 0.5)
        XCTAssertGreaterThanOrEqual(chromes[1].frame.minY, visibleMinY - 0.5)
        XCTAssertLessThan(chromes[2].frame.minY, visibleMinY)
        XCTAssertGreaterThan(chromes[2].frame.maxY, visibleMinY)
        XCTAssertLessThan(chromes[9].frame.maxY, visibleMinY)
        let countField = try XCTUnwrap(
            allControls(of: overview, as: NSTextField.self).first {
                $0.identifier?.rawValue == "codex.bankedReset.count"
            }
        )
        XCTAssertEqual(countField.stringValue, "10")
    }

    func testCCSwitchMenuItemStaysIndependentAndOpenCodexMenuItemIsAbsent() throws {
        for showOpenCCSwitchMenu in [true, false] {
            let controller = StatusItemController(
                actions: StatusItemController.Actions(
                    manualRefresh: {},
                    openDashboard: {},
                    openChatGPT: {},
                    openCCSwitch: {},
                    quit: {},
                    switchProvider: { _ in },
                    openProviderWebsite: {},
                    openStatusLink: { _ in },
                    iconChanged: { _ in }
                )
            )
            defer { controller.teardown() }

            controller.start(
                snapshot: .placeholder,
                refreshDate: nil,
                menuInput: StatusItemController.MenuInput(
                    choices: [
                        ProviderChoice(
                            id: "other",
                            name: "Other Provider",
                            isCurrent: true
                        )
                    ],
                    quickSwitchSummaries: [:],
                    activeClient: .claude,
                    openAIAccount: nil,
                    statusLinks: [
                        StatusLink(title: "Status", url: "https://status.example")
                    ],
                    showQuickSwitchMenu: true,
                    showOpenChatGPTMenu: true,
                    showOpenCCSwitchMenu: showOpenCCSwitchMenu,
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

            XCTAssertFalse(
                controller.menuItemsForTesting.contains {
                    $0.title.localizedCaseInsensitiveContains("OpenCodex")
                }
            )
            XCTAssertEqual(
                controller.menuItemsForTesting.contains {
                    $0.title == "打开 CC Switch" || $0.title == "Open CC Switch"
                },
                showOpenCCSwitchMenu
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

    private func findStatusLinksEditors(in view: NSView) -> [StatusLinksEditorHostingView] {
        var result: [StatusLinksEditorHostingView] = []
        if let editor = view as? StatusLinksEditorHostingView {
            result.append(editor)
        }
        for child in view.subviews {
            result.append(contentsOf: findStatusLinksEditors(in: child))
        }
        return result
    }

    private func layoutDescendants(of view: NSView) {
        view.layoutSubtreeIfNeeded()
        for child in view.subviews {
            layoutDescendants(of: child)
        }
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for child in view.subviews {
            if let match = child as? T {
                return match
            }
            if let match = firstDescendant(of: child, as: type) {
                return match
            }
        }
        return nil
    }

    private func ancestors(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        var current = view.superview
        while let ancestor = current {
            result.append(ancestor)
            current = ancestor.superview
        }
        return result
    }

    private func menuPage(in window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        func containsScrollView(_ view: NSView) -> Bool {
            if view is NSScrollView { return true }
            return view.subviews.contains(where: containsScrollView)
        }
        return contentView.subviews
            .flatMap { $0.subviews }
            .first(where: containsScrollView)
    }

    private func firstControl<T: NSView>(
        of view: NSView,
        as type: T.Type,
        where predicate: (T) -> Bool
    ) -> T? {
        for child in view.subviews {
            if let match = child as? T, predicate(match) {
                return match
            }
            if let match = firstControl(of: child, as: type, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func allControls<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        for child in view.subviews {
            if let match = child as? T {
                matches.append(match)
            }
            matches.append(contentsOf: allControls(of: child, as: type))
        }
        return matches
    }

    private func assertBankedResetForecastSubtitleFullyVisible(
        _ field: NSTextField,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(field.stringValue, expected, file: file, line: line)
        XCTAssertEqual(field.lineBreakMode, .byClipping, file: file, line: line)
        XCTAssertFalse(field.stringValue.contains("..."), file: file, line: line)
        XCTAssertFalse(field.stringValue.contains("…"), file: file, line: line)
        let font = field.font ?? OpenCodexCardLayout.bankedResetForecastSubtitleFont
        XCTAssertGreaterThanOrEqual(
            field.frame.width,
            AccountMarqueeView.textWidth(of: expected, font: font),
            "\(expected) clipped in \(field.identifier?.rawValue ?? "label")",
            file: file,
            line: line
        )
    }

    private func visualTextMinX(of view: NSView, in host: NSView) -> CGFloat {
        if let marquee = view as? AccountMarqueeView {
            return visualTextMinX(of: marquee.accountLabel, in: host)
        }
        if let field = view as? NSTextField, let cell = field.cell {
            return field.convert(cell.titleRect(forBounds: field.bounds).origin, to: host).x
        }
        return host.convert(NSPoint(x: view.bounds.minX, y: view.bounds.minY), from: view).x
    }

    private func assertBankedResetSummaryLeadingAligned(
        in overview: NSView,
        title: AccountMarqueeView,
        probabilityLink: HoverLinkTextField,
        prefix24: NSTextField,
        confidencePrefix: NSTextField,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = OpenCodexCardLayout.horizontalInset
        XCTAssertEqual(title.frame.minX, expected, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(prefix24.frame.minX, expected, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(confidencePrefix.frame.minX, expected, accuracy: 0.001, file: file, line: line)
        let titleX = visualTextMinX(of: title, in: overview)
        XCTAssertEqual(
            visualTextMinX(of: probabilityLink, in: overview),
            titleX,
            accuracy: 0.5,
            "重置概率 visual minX",
            file: file,
            line: line
        )
        XCTAssertEqual(
            visualTextMinX(of: prefix24, in: overview),
            titleX,
            accuracy: 0.5,
            "24h prefix visual minX",
            file: file,
            line: line
        )
        XCTAssertEqual(
            visualTextMinX(of: confidencePrefix, in: overview),
            titleX,
            accuracy: 0.5,
            "confidence prefix visual minX",
            file: file,
            line: line
        )
    }
}
