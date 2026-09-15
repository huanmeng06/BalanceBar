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

        window.setFrame(
            NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 1020, height: 700),
            display: false
        )
        window.layoutIfNeeded()
        try assertAccessoryStaysInsideContentPane(in: window, marker: "content-accessory")

        let sidebarItem = splitController.splitViewItems[0]
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .contentSplitItem)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        try assertAccessoryStaysInsideContentPane(in: window, marker: "content-accessory")

        splitController.toggleSidebar(nil)
        window.layoutIfNeeded()
        XCTAssertFalse(sidebarItem.isCollapsed)
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

        controller.showSection(.advanced)
        window.layoutIfNeeded()
        controller.rebuild()
        window.layoutIfNeeded()
        XCTAssertEqual(controller.accessoryHostForTesting.mountedKind, .windowTitlebar)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
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
        XCTAssertFalse(hostSource.contains("setValue("))
        XCTAssertFalse(hostSource.contains("forKey:"))
        XCTAssertFalse(hostSource.contains("NSClassFromString"))
        XCTAssertFalse(hostSource.contains("preferredScrollEdgeEffectStyle"))
        XCTAssertFalse(hostSource.contains("automaticallyAdjustsSafeAreaInsets"))
        XCTAssertFalse(hostSource.contains("NSGlassEffectView"))
        XCTAssertFalse(hostSource.contains("NSVisualEffectView"))

        let windowSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/UI/Dashboard/DashboardWindowController.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(windowSource.contains("accessoryHost.attach"))
        XCTAssertTrue(windowSource.contains("accessoryHost.apply"))
        XCTAssertTrue(windowSource.contains("accessoryHost.detach"))
        XCTAssertFalse(windowSource.contains("titlebarAccessoryViewControllers"))
        XCTAssertFalse(windowSource.contains("addTitlebarAccessoryViewController"))
        XCTAssertFalse(windowSource.contains("NSTitlebarAccessoryViewController"))
        XCTAssertFalse(windowSource.contains("NSSplitViewItemAccessoryViewController"))
        XCTAssertFalse(windowSource.contains("topAlignedAccessoryViewControllers"))

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

    private func makeController(
        makeSectionPage: ((DashboardSection) -> NSViewController)? = nil,
        providerChoices: [ProviderChoice] = []
    ) -> DashboardWindowController {
        DashboardWindowController(
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
        in controller: DashboardWindowController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            controller.accessoryHostForTesting.mountedKind,
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
