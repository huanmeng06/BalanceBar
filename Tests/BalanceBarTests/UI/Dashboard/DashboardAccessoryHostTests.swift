import AppKit
import XCTest
@testable import BalanceBar

@MainActor
final class DashboardAccessoryHostTests: XCTestCase {
    func testCurrentPagesLeaveNativeToolbarWithoutEmptyAccessory() throws {
        let controller = makeController()
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)

        for section in DashboardSection.allCases {
            controller.showSection(section)
            window.layoutIfNeeded()
            try assertNoMountedAccessory(in: controller)
        }
    }

    func testHostCreatedTitlebarWrapperUsesIndependentContainerAndRestoresChild() throws {
        let content = ProbeAccessoryController(marker: "host-titlebar-child")
        XCTAssertNil(content.parent)

        let controller = makeController(
            makeSectionPage: { section in
                section == .menuBar
                    ? AccessoryProbePage(
                        accessory: .windowTitlebar(
                            viewController: content,
                            reason: "window-owned chrome"
                        )
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        controller.showSection(.menuBar)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let wrapper = try XCTUnwrap(controller.accessoryHostForTesting.titlebarAccessoryForTesting)
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(controller.accessoryHostForTesting.mountOwnershipForTesting, .hostCreatedWrapper)
        XCTAssertTrue(wrapper is NSTitlebarAccessoryViewController)
        XCTAssertEqual(wrapper.layoutAttribute, .bottom)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains(wrapper))
        XCTAssertTrue(content.parent === wrapper)
        XCTAssertTrue(wrapper.children.contains(content))
        XCTAssertTrue(content.view.superview === wrapper.view)
        XCTAssertFalse(wrapper.view === content.view)
        if #available(macOS 26.0, *) {
            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController
            )
            XCTAssertTrue(
                splitController.contentSplitViewItem?
                    .topAlignedAccessoryViewControllers.isEmpty ?? true
            )
        }

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertNil(content.parent)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertFalse(wrapper.children.contains(content))
    }

    func testCallerProvidedTitlebarAccessoryKeepsLeftRightAndBottomLayout() throws {
        try assertCallerProvidedTitlebarPreserves(layoutAttribute: .left)
        try assertCallerProvidedTitlebarPreserves(layoutAttribute: .right)
        try assertCallerProvidedTitlebarPreserves(layoutAttribute: .bottom)
    }

    func testHostCreatedSplitItemWrapperStaysOnContentPane() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSSplitViewItemAccessoryViewController requires macOS 26")
        }

        let content = ProbeAccessoryController(marker: "host-split-child")
        let controller = makeController(
            makeSectionPage: { section in
                section == .menu
                    ? AccessoryProbePage(
                        accessory: .contentSplitItem(viewController: content)
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        controller.showSection(.menu)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let host = controller.accessoryHostForTesting
        XCTAssertEqual(host.mountedKind, .contentSplitItem)
        XCTAssertEqual(host.mountOwnershipForTesting, .hostCreatedWrapper)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)

        let wrapper = try XCTUnwrap(host.contentSplitItemAccessoryForTesting)
        XCTAssertTrue(wrapper is NSSplitViewItemAccessoryViewController)
        XCTAssertTrue(content.parent === wrapper)
        XCTAssertTrue(wrapper.children.contains(content))
        XCTAssertTrue(content.view.superview === wrapper.view)
        XCTAssertFalse(wrapper.view === content.view)

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let contentItem = try XCTUnwrap(splitController.contentSplitViewItem)
        XCTAssertEqual(contentItem.topAlignedAccessoryViewControllers.count, 1)
        XCTAssertTrue(contentItem.topAlignedAccessoryViewControllers.first === wrapper)
        XCTAssertTrue(splitController.splitViewItems[0].topAlignedAccessoryViewControllers.isEmpty)
        try assertAccessoryStaysInsideContentPane(in: window, marker: "host-split-child")

        window.setFrame(
            NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 1020, height: 700),
            display: false
        )
        window.layoutIfNeeded()
        try assertAccessoryStaysInsideContentPane(in: window, marker: "host-split-child")

        let sidebarItem = splitController.splitViewItems[0]
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()
        XCTAssertEqual(host.mountedKind, .contentSplitItem)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        try assertAccessoryStaysInsideContentPane(in: window, marker: "host-split-child")

        splitController.toggleSidebar(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(sidebarItem.isCollapsed)
        try assertAccessoryStaysInsideContentPane(in: window, marker: "host-split-child")

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertNil(content.parent)
        XCTAssertTrue(contentItem.topAlignedAccessoryViewControllers.isEmpty)
    }

    func testCallerProvidedSplitItemAccessoryKeepsChildContainmentAfterUnmount() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSSplitViewItemAccessoryViewController requires macOS 26")
        }

        let provided = NSSplitViewItemAccessoryViewController()
        let child = ProbeAccessoryController(marker: "caller-split-child")
        provided.addChild(child)
        provided.view = child.view

        let controller = makeController(
            makeSectionPage: { section in
                section == .menu
                    ? AccessoryProbePage(
                        accessory: .contentSplitItem(viewController: provided)
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        controller.showSection(.menu)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .contentSplitItem)
        XCTAssertEqual(controller.accessoryHostForTesting.mountOwnershipForTesting, .callerProvidedNative)
        XCTAssertTrue(controller.accessoryHostForTesting.contentSplitItemAccessoryForTesting === provided)
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        XCTAssertTrue(
            splitController.contentSplitViewItem?
                .topAlignedAccessoryViewControllers.isEmpty ?? true
        )
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)
    }

    func testCallerOwnedSplitAccessoryMissingFromItemListDoesNotRemoveFromParent() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSSplitViewItemAccessoryViewController requires macOS 26")
        }

        let provided = NSSplitViewItemAccessoryViewController()
        let child = ProbeAccessoryController(marker: "caller-split-orphaned")
        provided.addChild(child)
        provided.view = child.view

        let controller = makeController(
            makeSectionPage: { section in
                section == .menu
                    ? AccessoryProbePage(
                        accessory: .contentSplitItem(viewController: provided)
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        controller.showSection(.menu)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let contentItem = try XCTUnwrap(splitController.contentSplitViewItem)
        if let index = contentItem.topAlignedAccessoryViewControllers.firstIndex(of: provided) {
            contentItem.removeTopAlignedAccessoryViewController(at: index)
        }
        XCTAssertFalse(contentItem.topAlignedAccessoryViewControllers.contains(provided))

        let owner = NSViewController()
        owner.view = NSView()
        if provided.parent != owner {
            if provided.parent != nil {
                provided.removeFromParent()
            }
            owner.addChild(provided)
        }
        XCTAssertTrue(provided.parent === owner)
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertTrue(provided.parent === owner)
        XCTAssertTrue(owner.children.contains(provided))
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)
    }

    func testHostRefusesToStealAlreadyParentedOrdinaryController() throws {
        let owner = NSViewController()
        owner.view = NSView()
        let content = ProbeAccessoryController(marker: "already-parented")
        owner.addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        owner.view.addSubview(content.view)

        let controller = makeController(
            makeSectionPage: { section in
                section == .advanced
                    ? AccessoryProbePage(
                        accessory: .windowTitlebar(
                            viewController: content,
                            reason: "must not steal parent"
                        )
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        controller.showSection(.advanced)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        try assertNoMountedAccessory(in: controller)
        XCTAssertTrue(content.parent === owner)
        XCTAssertTrue(owner.children.contains(content))
        XCTAssertTrue(content.view.superview === owner.view)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
    }

    func testContentSplitItemAccessoryMountsOnContentPaneOnly() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSSplitViewItemAccessoryViewController requires macOS 26")
        }

        let content = ProbeAccessoryController(marker: "content-accessory")
        let controller = makeController(
            makeSectionPage: { section in
                section == .menu
                    ? AccessoryProbePage(
                        accessory: .contentSplitItem(viewController: content)
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        try assertNoMountedAccessory(in: controller)

        controller.showSection(.menu)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .contentSplitItem)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController
        )
        let contentItem = try XCTUnwrap(splitController.contentSplitViewItem)
        XCTAssertEqual(contentItem.topAlignedAccessoryViewControllers.count, 1)
        XCTAssertTrue(
            contentItem.topAlignedAccessoryViewControllers.first
                === controller.accessoryHostForTesting.contentSplitItemAccessoryForTesting
        )
        XCTAssertTrue(
            splitController.splitViewItems[0].topAlignedAccessoryViewControllers.isEmpty
        )
        try assertAccessoryStaysInsideContentPane(in: window, marker: "content-accessory")
    }

    func testWindowTitlebarAccessoryRequiresOwnershipReasonAndUsesPublicTitlebarHost() throws {
        let content = ProbeAccessoryController(marker: "titlebar-accessory")
        let controller = makeController(
            makeSectionPage: { section in
                switch section {
                case .advanced:
                    AccessoryProbePage(
                        accessory: .windowTitlebar(
                            viewController: content,
                            reason: "window-owned status belongs in the titlebar"
                        )
                    )
                case .about:
                    AccessoryProbePage(
                        accessory: .windowTitlebar(
                            viewController: ProbeAccessoryController(marker: "empty-reason"),
                            reason: "   "
                        )
                    )
                default:
                    DashboardHostedPageViewController()
                }
            }
        )
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        try assertNoMountedAccessory(in: controller)

        controller.showSection(.about)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)

        controller.showSection(.advanced)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertTrue(
            window.titlebarAccessoryViewControllers.first
                === controller.accessoryHostForTesting.titlebarAccessoryForTesting
        )
        XCTAssertEqual(
            controller.accessoryHostForTesting.titlebarAccessoryForTesting?.layoutAttribute,
            .bottom
        )
        XCTAssertEqual(controller.accessoryHostForTesting.createdByHostForTesting, true)
        if #available(macOS 26.0, *) {
            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController
            )
            XCTAssertTrue(
                splitController.contentSplitViewItem?
                    .topAlignedAccessoryViewControllers.isEmpty ?? true
            )
        }
    }

    func testPageSwitchRemovesPreviousAccessoryAndLeavesNoPlaceholder() throws {
        let first = ProbeAccessoryController(marker: "first-accessory")
        let second = ProbeAccessoryController(marker: "second-accessory")
        let controller = makeController(
            makeSectionPage: { section in
                switch section {
                case .menu:
                    AccessoryProbePage(
                        accessory: .contentSplitItem(viewController: first)
                    )
                case .advanced:
                    AccessoryProbePage(
                        accessory: .windowTitlebar(
                            viewController: second,
                            reason: "window-owned chrome"
                        )
                    )
                default:
                    DashboardHostedPageViewController()
                }
            }
        )
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)

        controller.showSection(.menu)
        window.layoutIfNeeded()
        if #available(macOS 26.0, *) {
            XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .contentSplitItem)
        } else {
            XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .skippedUnsupportedOS)
            XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        }

        controller.showSection(.advanced)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertNotNil(view(withIdentifier: "second-accessory", in: window))
        XCTAssertNil(view(withIdentifier: "first-accessory", in: window))
        if #available(macOS 26.0, *) {
            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController
            )
            XCTAssertTrue(
                splitController.contentSplitViewItem?
                    .topAlignedAccessoryViewControllers.isEmpty ?? true
            )
        }

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertNil(view(withIdentifier: "second-accessory", in: window))
        XCTAssertNil(second.parent)

        controller.showSection(.advanced)
        window.layoutIfNeeded()
        controller.rebuild()
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
    }

    func testLegacyCapabilitiesSkipContentSplitItemAccessoryWithoutFabricatingOverlay() throws {
        let content = ProbeAccessoryController(marker: "capability-skipped-accessory")
        let controller = makeController(
            makeSectionPage: { _ in
                AccessoryProbePage(
                    accessory: .contentSplitItem(viewController: content)
                )
            }
        )
        defer { controller.teardown() }
        controller.applyPlatformCapabilities(.legacyCompatibility)

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .skippedUnsupportedOS)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertNil(view(withIdentifier: "capability-skipped-accessory", in: window))
        XCTAssertNil(controller.accessoryHostForTesting.contentSplitItemAccessoryForTesting)
        XCTAssertNil(content.parent)
        if #available(macOS 26.0, *) {
            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController
            )
            XCTAssertTrue(
                splitController.contentSplitViewItem?
                    .topAlignedAccessoryViewControllers.isEmpty ?? true
            )
        }
    }

    func testOlderOSDoesNotFakeContentSplitItemAccessoryWithOverlay() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 else {
            throw XCTSkip("This path is the pre-macOS 26 compatibility skip")
        }

        let content = ProbeAccessoryController(marker: "legacy-content-accessory")
        let controller = makeController(
            makeSectionPage: { _ in
                AccessoryProbePage(
                    accessory: .contentSplitItem(viewController: content)
                )
            }
        )
        defer { controller.teardown() }

        controller.open()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .skippedUnsupportedOS)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertNil(view(withIdentifier: "legacy-content-accessory", in: window))
        XCTAssertNil(controller.accessoryHostForTesting.contentSplitItemAccessoryForTesting)
        XCTAssertNil(content.parent)
    }

    func testHostAndPagesStayOnPublicOwnershipAPI() throws {
        let repositoryRoot = try TestRepositoryRoot.locate(from: #filePath)
        let hostSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardAccessoryHost.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(hostSource.contains("NSTitlebarAccessoryViewController"))
        XCTAssertTrue(hostSource.contains("NSSplitViewItemAccessoryViewController"))
        XCTAssertTrue(hostSource.contains("addTopAlignedAccessoryViewController"))
        XCTAssertTrue(hostSource.contains("addTitlebarAccessoryViewController"))
        XCTAssertTrue(hostSource.contains("layoutAttribute = .bottom"))
        XCTAssertTrue(hostSource.contains("var platformCapabilities = DashboardPlatformCapabilities.current"))
        XCTAssertTrue(hostSource.contains("supportsSplitItemAccessories"))
        XCTAssertTrue(hostSource.contains("guard #available(macOS 26.0, *) else"))
        XCTAssertFalse(hostSource.contains("layoutAttribute = .top"))
        XCTAssertFalse(hostSource.contains("setValue("))
        XCTAssertFalse(hostSource.contains("forKey:"))
        XCTAssertFalse(hostSource.contains("NSClassFromString"))
        XCTAssertFalse(hostSource.contains("preferredScrollEdgeEffectStyle"))
        XCTAssertFalse(hostSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(hostSource.contains("NSGlassEffectView"))
        XCTAssertFalse(hostSource.contains("NSVisualEffectView"))
        XCTAssertFalse(hostSource.contains("DashboardSourceList"))
        XCTAssertFalse(hostSource.contains("outlineView"))
        XCTAssertFalse(hostSource.contains("onWindowChromeNeedsRefresh"))
        XCTAssertFalse(hostSource.contains("contentLayoutGuide"))
        XCTAssertFalse(hostSource.contains("DashboardSidebarChromeBaseline"))
        XCTAssertFalse(hostSource.contains("if content.parent != nil"))
        XCTAssertFalse(hostSource.contains("else if accessory.parent != nil"))

        let windowSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardPageSession.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(windowSource.contains("accessoryHost.attach"))
        XCTAssertTrue(sessionSource.contains("accessoryHost.apply"))
        XCTAssertTrue(windowSource.contains("attachedAccessoryHost?.detach"))
        XCTAssertFalse(windowSource.contains("titlebarAccessoryViewControllers"))
        XCTAssertFalse(windowSource.contains("addTitlebarAccessoryViewController"))
        XCTAssertFalse(windowSource.contains("NSTitlebarAccessoryViewController"))
        XCTAssertFalse(windowSource.contains("NSSplitViewItemAccessoryViewController"))
        XCTAssertFalse(windowSource.contains("topAlignedAccessoryViewControllers"))
        XCTAssertFalse(windowSource.contains("DashboardSidebarChromeBaseline"))
        XCTAssertFalse(windowSource.contains("sourceListTopConstraint"))
        XCTAssertFalse(windowSource.contains("windowDidEnterFullScreen"))
        XCTAssertFalse(windowSource.contains("windowWillExitFullScreen"))
        XCTAssertFalse(windowSource.contains("equalTo: contentLayoutGuide.topAnchor"))

        let pagesRoot = repositoryRoot.appendingPathComponent("Sources/UI/Dashboard/Pages")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: pagesRoot, includingPropertiesForKeys: nil)
        )
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains("titlebarAccessoryViewControllers"),
                fileURL.lastPathComponent
            )
            XCTAssertFalse(
                source.contains("NSTitlebarAccessoryViewController"),
                fileURL.lastPathComponent
            )
            XCTAssertFalse(
                source.contains("NSSplitViewItemAccessoryViewController"),
                fileURL.lastPathComponent
            )
            XCTAssertFalse(
                source.contains("topAlignedAccessoryViewControllers"),
                fileURL.lastPathComponent
            )
            XCTAssertFalse(source.contains("DashboardAccessoryHost"), fileURL.lastPathComponent)
            XCTAssertFalse(
                source.contains("DashboardPageTopAccessoryProviding"),
                fileURL.lastPathComponent
            )
        }
    }

    func testTitlebarAccessoryKeepsControlHitsWithoutDrivingSidebarLayout() throws {
        let harness = DashboardAccessoryHarnessController()
        defer { harness.teardown() }
        harness.present()
        let controller = harness
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let beforeTop = try sourceListTop(in: controller)
        try assertSectionRowIsInteractive(.general, in: controller)
        try assertTitlebarChromePassThrough(in: controller)

        controller.showSection(.menuBar)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        if #available(macOS 26.0, *) {
            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController
            )
            XCTAssertTrue(
                splitController.contentSplitViewItem?
                    .topAlignedAccessoryViewControllers.isEmpty ?? true
            )
        }
        XCTAssertEqual(try sourceListTop(in: controller), beforeTop, accuracy: 1)
        try assertSectionRowIsInteractive(.general, in: controller)
        try assertTitlebarChromePassThrough(in: controller)

        try clickSourceListSection(.general, in: controller)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.section, .general)
        try assertNoMountedAccessory(in: controller)
        XCTAssertEqual(try sourceListTop(in: controller), beforeTop, accuracy: 1)
        try assertSectionRowIsInteractive(.general, in: controller)
    }

    func testHarnessIsDevOnlyAndReusesRealAccessoryHost() throws {
        XCTAssertFalse(
            DashboardAccessoryHarnessController.isEnabled(
                bundleIdentifier: "com.huanmeng06.BalanceBar.app",
                environment: [DashboardAccessoryHarnessController.environmentKey: "1"],
                isTestHost: false
            )
        )
        XCTAssertFalse(
            DashboardAccessoryHarnessController.isEnabled(
                bundleIdentifier: "com.huanmeng06.BalanceBar.dev",
                environment: [:],
                isTestHost: false
            )
        )
        XCTAssertFalse(
            DashboardAccessoryHarnessController.isEnabled(
                bundleIdentifier: "com.huanmeng06.BalanceBar.dev",
                environment: [DashboardAccessoryHarnessController.environmentKey: "1"],
                isTestHost: true
            )
        )
        XCTAssertTrue(
            DashboardAccessoryHarnessController.isEnabled(
                bundleIdentifier: "com.huanmeng06.BalanceBar.dev",
                environment: [DashboardAccessoryHarnessController.environmentKey: "1"],
                isTestHost: false
            )
        )

        XCTAssertFalse(DashboardAccessoryHarnessController.accessory(for: .general).needsAccessory)
        XCTAssertFalse(DashboardAccessoryHarnessController.accessory(for: .advanced).needsAccessory)
        XCTAssertFalse(DashboardAccessoryHarnessController.accessory(for: .about).needsAccessory)

        let harness = DashboardAccessoryHarnessController()
        defer { harness.teardown() }
        harness.present()
        let controller = harness
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertTrue(window.contentViewController is DashboardSplitViewController)
        XCTAssertEqual(window.toolbar?.identifier, DashboardToolbarController.identifier)

        controller.showSection(.menuBar)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(
            controller.accessoryHostForTesting.titlebarAccessoryForTesting?.layoutAttribute,
            .bottom
        )
        XCTAssertNotNil(
            view(
                withIdentifier: DashboardAccessoryHarnessController.titlebarStripIdentifier,
                in: window
            )
        )

        controller.showSection(.menu)
        window.layoutIfNeeded()
        if #available(macOS 26.0, *) {
            XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .contentSplitItem)
            XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
            XCTAssertNil(
                view(
                    withIdentifier: DashboardAccessoryHarnessController.titlebarStripIdentifier,
                    in: window
                )
            )
            try assertAccessoryStaysInsideContentPane(
                in: window,
                marker: DashboardAccessoryHarnessController.contentStripIdentifier
            )
        }

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertNil(
            view(
                withIdentifier: DashboardAccessoryHarnessController.contentStripIdentifier,
                in: window
            )
        )
    }

    private func assertCallerProvidedTitlebarPreserves(
        layoutAttribute: NSLayoutConstraint.Attribute
    ) throws {
        let provided = NSTitlebarAccessoryViewController()
        provided.layoutAttribute = layoutAttribute
        let child = ProbeAccessoryController(marker: "caller-titlebar-\(layoutAttribute.rawValue)")
        provided.addChild(child)
        provided.view = child.view

        let controller = makeController(
            makeSectionPage: { section in
                section == .advanced
                    ? AccessoryProbePage(
                        accessory: .windowTitlebar(
                            viewController: provided,
                            reason: "caller-owned titlebar accessory"
                        )
                    )
                    : DashboardHostedPageViewController()
            }
        )
        defer { controller.teardown() }

        controller.open()
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)
        XCTAssertEqual(provided.layoutAttribute, layoutAttribute)

        controller.showSection(.advanced)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()

        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(controller.accessoryHostForTesting.mountOwnershipForTesting, .callerProvidedNative)
        XCTAssertTrue(controller.accessoryHostForTesting.titlebarAccessoryForTesting === provided)
        XCTAssertEqual(provided.layoutAttribute, layoutAttribute)
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains(provided))

        controller.showSection(.general)
        window.layoutIfNeeded()
        try assertNoMountedAccessory(in: controller)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertTrue(provided.children.contains(child))
        XCTAssertTrue(child.parent === provided)
        XCTAssertEqual(provided.layoutAttribute, layoutAttribute)
    }

    private func makeController(
        makeSectionPage: ((DashboardSection) -> NSViewController)? = nil,
        providerChoices: [ProviderChoice] = []
    ) -> DashboardShellTestHarness {
        DashboardShellTestHarness(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { section in
                    makeSectionPage?(section) ?? DashboardHostedPageViewController()
                },
                makeProviderPage: { _ in DashboardHostedPageViewController() },
                providerChoices: { providerChoices },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
    }

    private func assertNoMountedAccessory(
        in controller: DashboardShellInspecting,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            controller.accessoryHostForTesting.mountedKind,
            .none,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controller.accessoryHostForTesting.mountOwnershipForTesting,
            .none,
            file: file,
            line: line
        )
        let window = try XCTUnwrap(controller.window, file: file, line: line)
        XCTAssertTrue(
            window.titlebarAccessoryViewControllers.isEmpty,
            "No-accessory pages must not keep a titlebar accessory or spacer",
            file: file,
            line: line
        )
        if #available(macOS 26.0, *) {
            let splitController = try XCTUnwrap(
                window.contentViewController as? DashboardSplitViewController,
                file: file,
                line: line
            )
            XCTAssertTrue(
                splitController.contentSplitViewItem?
                    .topAlignedAccessoryViewControllers.isEmpty ?? true,
                "No-accessory pages must not keep a split-item accessory",
                file: file,
                line: line
            )
            XCTAssertTrue(
                splitController.splitViewItems[0].topAlignedAccessoryViewControllers.isEmpty,
                file: file,
                line: line
            )
        }
        XCTAssertNil(
            controller.accessoryHostForTesting.titlebarAccessoryForTesting,
            file: file,
            line: line
        )
        XCTAssertNil(
            controller.accessoryHostForTesting.contentSplitItemAccessoryForTesting,
            file: file,
            line: line
        )
    }

    private func assertAccessoryStaysInsideContentPane(
        in window: NSWindow,
        marker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let splitController = try XCTUnwrap(
            window.contentViewController as? DashboardSplitViewController,
            file: file,
            line: line
        )
        let accessory = try XCTUnwrap(view(withIdentifier: marker, in: window), file: file, line: line)
        let contentView = splitController.contentController.view
        let accessoryFrame = accessory.convert(accessory.bounds, to: nil)
        let contentFrame = contentView.convert(contentView.bounds, to: nil)
        XCTAssertGreaterThan(accessoryFrame.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(accessoryFrame.minX, contentFrame.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(accessoryFrame.maxX, contentFrame.maxX + 1, file: file, line: line)
        let sidebarView = splitController.sidebarController.view
        if sidebarView.frame.width > 1, !splitController.splitViewItems[0].isCollapsed {
            let sidebarFrame = sidebarView.convert(sidebarView.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(
                accessoryFrame.minX,
                sidebarFrame.maxX - 1,
                "Content-pane accessory must not span the sidebar",
                file: file,
                line: line
            )
        }
    }

    private func sourceListTop(in controller: DashboardShellInspecting) throws -> CGFloat {
        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        return sourceList.view.convert(sourceList.view.bounds, to: nil).maxY
    }

    private func assertSectionRowIsInteractive(
        _ section: DashboardSection,
        in controller: DashboardShellInspecting
    ) throws {
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let row = try XCTUnwrap(sourceList.row(for: section))
        let cell = try XCTUnwrap(
            sourceList.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
        )
        let contentView = try XCTUnwrap(window.contentView as? DashboardContentRootView)
        let frameView = try XCTUnwrap(contentView.superview)
        let centerInWindow = cell.convert(
            NSPoint(x: cell.bounds.midX, y: cell.bounds.midY),
            to: nil
        )
        let centerInSelf = contentView.convert(centerInWindow, from: nil)
        let centerInSuperview = contentView.convert(centerInSelf, to: frameView)
        let hitView = try XCTUnwrap(
            contentView.hitTest(centerInSuperview),
            "\(section) row hit-test returned nil; click would miss the source list. center=\(centerInWindow) contentLayout=\(window.contentLayoutRect)"
        )
        var current: NSView? = hitView
        var inSourceList = false
        while let node = current {
            if node === sourceList.outlineView || node === sourceList.scrollView {
                inSourceList = true
                break
            }
            current = node.superview
        }
        XCTAssertTrue(inSourceList, "\(section) row hit-test must land in the source-list hierarchy")
    }

    private func assertTitlebarChromePassThrough(
        in controller: DashboardShellInspecting
    ) throws {
        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView as? DashboardContentRootView)
        let frameView = try XCTUnwrap(contentView.superview)
        let layoutRect = window.contentLayoutRect
        let topInWindow = contentView.convert(
            NSPoint(x: contentView.bounds.midX, y: contentView.bounds.maxY),
            to: nil
        )
        XCTAssertGreaterThan(topInWindow.y - layoutRect.maxY, 1)

        let split = try XCTUnwrap(window.contentViewController as? DashboardSplitViewController)
        let sidebarWidth = split.sidebarController.view.frame.width
        let titlebarX = layoutRect.minX + min(layoutRect.width - 24, max(sidebarWidth + 40, layoutRect.width * 0.6))
        let titlebarY = (layoutRect.maxY + topInWindow.y) / 2
        let titlebarInSelf = contentView.convert(NSPoint(x: titlebarX, y: titlebarY), from: nil)
        let titlebarInSuperview = contentView.convert(titlebarInSelf, to: frameView)
        XCTAssertNil(
            contentView.hitTest(titlebarInSuperview),
            "Content-side titlebar must still pass through to NSThemeFrame"
        )

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let buttonPoint = closeButton.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            to: frameView
        )
        XCTAssertNil(contentView.hitTest(buttonPoint), "Traffic lights must stay outside content hit-testing")
    }

    private func clickSourceListSection(
        _ section: DashboardSection,
        in controller: DashboardShellInspecting
    ) throws {
        try assertSectionRowIsInteractive(section, in: controller)
        let sourceList = try XCTUnwrap(controller.sourceListForTesting)
        let row = try XCTUnwrap(sourceList.row(for: section))
        sourceList.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func view(withIdentifier identifier: String, in window: NSWindow) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier {
                return view
            }
            for subview in view.subviews {
                if let match = search(subview) {
                    return match
                }
            }
            return nil
        }

        if let contentView = window.contentView, let match = search(contentView) {
            return match
        }
        for accessory in window.titlebarAccessoryViewControllers {
            if let match = search(accessory.view) {
                return match
            }
        }
        return nil
    }
}

private protocol DashboardShellInspecting: AnyObject {
    var window: NSWindow? { get }
    var section: DashboardSection { get }
    var accessoryHostForTesting: DashboardAccessoryHost { get }
    var sourceListForTesting: DashboardSourceListController? { get }
    func showSection(_ section: DashboardSection)
}

extension DashboardShellTestHarness: DashboardShellInspecting {}
extension DashboardAccessoryHarnessController: DashboardShellInspecting {}

private final class AccessoryProbePage: NSViewController, DashboardPageTopAccessoryProviding {
    let dashboardPageTopAccessory: DashboardPageTopAccessory

    init(accessory: DashboardPageTopAccessory) {
        dashboardPageTopAccessory = accessory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
    }
}

private final class ProbeAccessoryController: NSViewController {
    init(marker: String, height: CGFloat = 28) {
        super.init(nibName: nil, bundle: nil)
        let probe = ProbeAccessoryView(height: height)
        probe.identifier = NSUserInterfaceItemIdentifier(marker)
        view = probe
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ProbeAccessoryView: NSView {
    private let probeHeight: CGFloat

    init(height: CGFloat) {
        probeHeight = height
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: probeHeight)
    }
}
