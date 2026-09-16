import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardContentSafeAreaTests: XCTestCase {
    func testSplitAndPageSourcesKeepSafeAreaOnContentOwnership() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let windowSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        let containerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardPageContainerViewController.swift"
            ),
            encoding: .utf8
        )
        let hostSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardAccessoryHost.swift"
            ),
            encoding: .utf8
        )
        let aboutSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/Pages/Preferences/DashboardAboutPage.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(windowSource.contains("applyAdjacentContentSafeAreaPolicy(to: contentItem)"))
        XCTAssertTrue(windowSource.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(windowSource.contains("item.automaticallyAdjustsSafeAreaInsets = true"))
        XCTAssertFalse(windowSource.contains("sidebarItem.automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(windowSource.contains("additionalSafeAreaInsets"))
        XCTAssertFalse(windowSource.contains("NSBackgroundExtensionView"))

        let policyStart = try XCTUnwrap(
            windowSource.range(of: "static func applyAdjacentContentSafeAreaPolicy")
        )
        let policySource = String(windowSource[policyStart.lowerBound...])
        XCTAssertTrue(policySource.contains("automaticallyAdjustsSafeAreaInsets = true"))
        XCTAssertTrue(policySource.contains("#available(macOS 26.0, *)"))

        XCTAssertTrue(containerSource.contains("view.safeAreaLayoutGuide.leadingAnchor"))
        XCTAssertTrue(containerSource.contains("view.safeAreaLayoutGuide.trailingAnchor"))
        XCTAssertTrue(containerSource.contains("pageView.topAnchor.constraint(equalTo: view.topAnchor)"))
        XCTAssertFalse(containerSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(containerSource.contains("preferredSidebarThickness"))
        XCTAssertFalse(containerSource.contains("minimumSidebarThickness"))
        XCTAssertFalse(containerSource.contains("additionalSafeAreaInsets"))
        XCTAssertFalse(containerSource.contains("NSBackgroundExtensionView"))
        XCTAssertFalse(containerSource.contains("NSClassFromString"))

        XCTAssertFalse(hostSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(hostSource.contains("safeAreaLayoutGuide"))
        XCTAssertFalse(hostSource.contains("NSBackgroundExtensionView"))

        XCTAssertTrue(aboutSource.contains("root.safeAreaLayoutGuide.centerXAnchor"))
        XCTAssertFalse(aboutSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(aboutSource.contains("preferredSidebarThickness"))
        XCTAssertFalse(aboutSource.contains("NSBackgroundExtensionView"))
    }

    func testContentSplitItemEnablesSafeAreaAdjustmentOnlyOnSupportedOS() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let sidebarItem = splitController.splitViewItems[0]
        let contentItem = try XCTUnwrap(splitController.contentSplitViewItem)
        XCTAssertTrue(contentItem.viewController === splitController.contentController)
        XCTAssertTrue(splitController.contentController is DashboardPageContainerViewController)

        if #available(macOS 26.0, *) {
            XCTAssertTrue(contentItem.automaticallyAdjustsSafeAreaInsets)
            XCTAssertFalse(sidebarItem.automaticallyAdjustsSafeAreaInsets)
        }
    }

    func testPageViewStaysInHorizontalSafeAreaAcrossSidebarGeometry() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let sidebarItem = splitController.splitViewItems[0]
        let content = splitController.contentController.view
        let page = try XCTUnwrap(controller.pageContainerForTesting.currentPage?.view)
        let mutations: [(String, () -> Void)] = [
            ("initial", {}),
            ("narrower", {
                splitController.splitView.setPosition(
                    sidebarItem.minimumThickness + 20,
                    ofDividerAt: 0
                )
            }),
            ("maximum", {
                splitController.splitView.setPosition(
                    sidebarItem.maximumThickness,
                    ofDividerAt: 0
                )
            }),
            ("collapsed", {
                sidebarItem.isCollapsed = true
            }),
            ("reexpanded", {
                sidebarItem.isCollapsed = false
            }),
            ("toggleCollapsed", {
                splitController.toggleSidebar(nil)
            }),
            ("toggleExpanded", {
                splitController.toggleSidebar(nil)
            })
        ]

        for (name, mutate) in mutations {
            mutate()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            assertPageHonorsHorizontalSafeArea(page: page, in: content, name: name)
        }
        XCTAssertFalse(sidebarItem.isCollapsed)
    }

    func testContentSafeAreaDoesNotCoverInteractivePageWhenSidebarOverlays() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("automaticallyAdjustsSafeAreaInsets requires macOS 26")
        }

        let controller = makeController()
        defer { controller.teardown() }
        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        XCTAssertTrue(
            splitController.contentSplitViewItem?.automaticallyAdjustsSafeAreaInsets ?? false
        )
        let sidebar = splitController.splitViewItems[0].viewController.view
        let content = splitController.contentController.view
        let page = try XCTUnwrap(controller.pageContainerForTesting.currentPage?.view)
        let sidebarInSplit = sidebar.convert(sidebar.bounds, to: splitController.splitView)
        let contentInSplit = content.convert(content.bounds, to: splitController.splitView)
        let pageInSplit = page.convert(page.bounds, to: splitController.splitView)
        let safeFrameInSplit = content.convert(content.safeAreaRect, to: splitController.splitView)

        if sidebarInSplit.insetBy(dx: 0.5, dy: 0.5)
            .intersects(contentInSplit.insetBy(dx: 0.5, dy: 0.5)) {
            XCTAssertGreaterThan(content.safeAreaInsets.left, 0)
            XCTAssertFalse(
                sidebarInSplit.insetBy(dx: 0.5, dy: 0.5)
                    .intersects(safeFrameInSplit.insetBy(dx: 0.5, dy: 0.5))
            )
            XCTAssertFalse(
                sidebarInSplit.insetBy(dx: 0.5, dy: 0.5)
                    .intersects(pageInSplit.insetBy(dx: 0.5, dy: 0.5))
            )
        } else {
            XCTAssertEqual(page.frame.minX, content.safeAreaRect.minX, accuracy: 1)
        }
    }

    func testStartupSettingsRowKeepsIntrinsicHeightWhenDocumentIsTallerThanContent() throws {
        let launchAtLogin = DashboardSettingsComponents.makeSettingsRow(
            "登录时自动启动",
            subtitle: "登录 Mac 后自动启动 BalanceBar",
            control: NSSwitch()
        )
        let silentLaunch = SettingsRowView(
            title: "静默启动",
            detail: "启动 BalanceBar 时不打开主窗口",
            accessoryView: NSSwitch()
        )
        let launchWithChatGPT = DashboardSettingsComponents.makeSettingsRow(
            "随 ChatGPT 启动",
            subtitle: "暂时无法读取随 ChatGPT 启动服务状态",
            control: NSSwitch()
        )
        let startup = SettingsSectionView(
            title: "启动",
            contentViews: [launchAtLogin, silentLaunch, launchWithChatGPT]
        )
        let pageContent = DashboardSettingsComponents.makeSettingsPageContent([startup])
        let controller = DashboardScrollablePageViewController(wrapping: pageContent)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 1100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 880, height: 1100))
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.pageScrollView.layoutSubtreeIfNeeded()
        documentAndRowsNeedLayout(controller)

        let document = try XCTUnwrap(controller.documentViewForTesting)
        let viewportHeight = controller.pageScrollView.bounds.height
        let fill = try XCTUnwrap(
            firstView(in: document) {
                $0.identifier == DashboardScrollablePageViewController.documentFillIdentifier
            }
        )
        XCTAssertGreaterThan(
            viewportHeight,
            pageContent.fittingSize.height + 80,
            "The simulated viewport must be taller than the startup section; viewport=\(viewportHeight) content=\(pageContent.fittingSize.height) view=\(controller.view.bounds)"
        )
        XCTAssertGreaterThanOrEqual(document.bounds.height, viewportHeight - 1)
        XCTAssertEqual(
            silentLaunch.frame.height,
            silentLaunch.fittingSize.height,
            accuracy: 8,
            "Fullscreen extra height must stay in the document fill, not the native startup row"
        )
        XCTAssertLessThanOrEqual(
            silentLaunch.frame.height,
            SettingsRowView.minimumHeight + 8
        )
        XCTAssertGreaterThan(
            fill.frame.height,
            DashboardScrollablePageViewController.documentBottomInset + 80
        )
        XCTAssertLessThan(launchAtLogin.frame.height, 200)
        XCTAssertLessThan(launchWithChatGPT.frame.height, 200)
    }

    private func documentAndRowsNeedLayout(
        _ controller: DashboardScrollablePageViewController
    ) {
        controller.documentViewForTesting.layoutSubtreeIfNeeded()
        controller.hostedContentForTesting.layoutSubtreeIfNeeded()
    }

    private func firstView(in root: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(root) { return root }
        for child in root.subviews {
            if let match = firstView(in: child, matching: predicate) {
                return match
            }
        }
        return nil
    }

    private func makeController() -> DashboardWindowController {
        DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { _ in
                    DashboardScrollablePageViewController(
                        wrapping: DashboardSettingsComponents.makeSettingsPageContent([
                            DashboardSettingsComponents.makeSettingsSection(
                                "General",
                                rows: [DashboardSettingsComponents.makeSettingsRow("Language")]
                            )
                        ])
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
    }

    private func assertPageHonorsHorizontalSafeArea(
        page: NSView,
        in content: NSView,
        name: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        content.layoutSubtreeIfNeeded()
        page.superview?.layoutSubtreeIfNeeded()
        let pageInContent = page.convert(page.bounds, to: content)
        XCTAssertEqual(
            pageInContent.minX,
            content.safeAreaRect.minX,
            accuracy: 1,
            "Page leading inset mismatch after \(name)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            pageInContent.maxX,
            content.safeAreaRect.maxX,
            accuracy: 1,
            "Page trailing inset mismatch after \(name)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            page.frame.minY,
            content.bounds.minY,
            accuracy: 1,
            "Page top should stay on the content edge after \(name)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            page.frame.maxY,
            content.bounds.maxY,
            accuracy: 1,
            "Page bottom should stay on the content edge after \(name)",
            file: file,
            line: line
        )
    }
}
