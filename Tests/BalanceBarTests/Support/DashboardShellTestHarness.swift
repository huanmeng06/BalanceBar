import AppKit
@testable import BalanceBar

/// Test-only pairing of window lifecycle and page session. Production
/// composition and the accessory harness assemble the same two types
/// rather than a second chrome controller.
final class DashboardShellTestHarness {
    let windowController: DashboardWindowController
    let pageSession: DashboardPageSession

    var window: NSWindow? { windowController.window }
    var contentHost: NSView { pageSession.contentHost }
    var section: DashboardSection { pageSession.section }
    var selectedProviderID: String? { pageSession.selectedProviderID }
    var windowCreationCount: Int { windowController.windowCreationCount }
    var appearanceObserverInstallCount: Int { windowController.appearanceObserverInstallCount }
    var mouseMonitorInstallCount: Int { windowController.mouseMonitorInstallCount }
    var lastFramePlacement: DashboardShellFramePlacement? { windowController.lastFramePlacement }

    var sidebarScrollLayoutPolicy: DashboardSidebarScrollLayoutPolicy {
        get { pageSession.sidebarScrollLayoutPolicy }
        set { pageSession.sidebarScrollLayoutPolicy = newValue }
    }

    var platformCapabilities: DashboardPlatformCapabilities {
        get { pageSession.platformCapabilities }
        set { applyPlatformCapabilities(newValue) }
    }

    func applyPlatformCapabilities(_ capabilities: DashboardPlatformCapabilities) {
        windowController.platformCapabilities = capabilities
        pageSession.platformCapabilities = capabilities
        pageSession.accessoryHost.platformCapabilities = capabilities
        pageSession.sidebarScrollLayoutPolicy = .forCapabilities(capabilities)
    }

    init(
        actions: DashboardWindowControllerActions,
        restorationStore: DashboardShellRestorationStoring = DashboardShellRestoration.makeDefaultStore()
    ) {
        self.pageSession = DashboardPageSession(actions: actions)
        let windowController = DashboardWindowController(restorationStore: restorationStore)
        windowController.didClose = { actions.didClose() }
        windowController.didResize = { actions.didResize() }
        self.windowController = windowController
        windowController.onAppearanceDidChange = { [weak self] in
            self?.rebuild()
        }
    }

    deinit {
        teardown()
    }

    func start() {
        windowController.start()
    }

    func open(
        initialSection: DashboardSection = .general,
        scrollOffsetY: CGFloat? = nil
    ) {
        let isNewWindow = windowController.window == nil
        windowController.open(initialSection: initialSection)
        if isNewWindow {
            pageSession.installShell(on: windowController)
            pageSession.showSection(initialSection)
            if let scrollOffsetY {
                windowController.window?.makeFirstResponder(nil)
                restorePageScrollOffsetY(scrollOffsetY)
            }
        }
        windowController.present()
    }

    func pageScrollOffsetY() -> CGFloat {
        pageSession.pageScrollOffsetY()
    }

    func restorePageScrollOffsetY(_ offset: CGFloat) {
        windowController.window?.layoutIfNeeded()
        contentHost.layoutSubtreeIfNeeded()
        pageSession.restorePageScrollOffsetY(offset)
        windowController.window?.makeFirstResponder(nil)
    }

    func rebuild() {
        pageSession.rebuild(on: windowController)
    }

    func showSection(_ section: DashboardSection) {
        pageSession.showSection(section)
    }

    func showProvider(_ providerID: String) {
        pageSession.showProvider(providerID)
    }

    func setShowsUpdateAvailableBadge(_ visible: Bool) {
        pageSession.setShowsUpdateAvailableBadge(visible)
    }

    func bindSearchQueryHandler(_ handler: @escaping (String) -> Void) {
        pageSession.toolbarController.onSearchQueryChanged = handler
    }

    func setSearchQuery(_ query: String) {
        pageSession.toolbarController.setQuery(query)
    }

    var searchQuery: String { pageSession.toolbarController.searchQuery }

    func currentHostedPageContent() -> NSView {
        pageSession.currentHostedPageContent()
    }

    func restoreCurrentPageScrollToTop() {
        pageSession.restoreCurrentPageScrollToTop()
    }

    func teardown() {
        pageSession.teardown()
        windowController.teardown()
    }

    var sourceListForTesting: DashboardSourceListController? {
        pageSession.sourceListController
    }

    var pageContainerForTesting: DashboardPageContainerViewController {
        pageSession.pageContainer
    }

    var accessoryHostForTesting: DashboardAccessoryHost {
        pageSession.accessoryHost
    }

    var scrollablePageForTesting: DashboardScrollablePageViewController? {
        pageSession.scrollablePage
    }
}

/// The search toolbar item keeps a stable host view; the circular button or
/// `NSSearchField` is that host or its visible content.
enum DashboardSearchToolbarProbe {
    static func contentView(in item: NSToolbarItem?) -> NSView? {
        guard let view = item?.view else { return nil }
        if view is NSSearchField || view is NSButton { return view }
        let controls = view.subviews.filter { $0 is NSSearchField || $0 is NSButton }
        return controls.first { !$0.isHidden } ?? controls.first
    }
}
