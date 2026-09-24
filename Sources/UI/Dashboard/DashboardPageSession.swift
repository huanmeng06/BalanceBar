import AppKit

/// Page factories and close/resize callbacks used by composition and tests.
/// Window lifecycle does not own these closures.
struct DashboardWindowControllerActions {
    let makeSectionPage: (DashboardSection) -> NSViewController
    let makeProviderPage: (ProviderChoice) -> NSViewController
    let providerChoices: () -> [ProviderChoice]
    let prepareForPageReplacement: () -> Void
    let didShowPage: () -> Void
    let didClose: () -> Void
    let didResize: () -> Void
}

/// Composition-owned page, source-list, toolbar, and accessory session.
/// `DashboardWindowController` only attaches the resulting split onto an `NSWindow`.
final class DashboardPageSession {
    let actions: DashboardWindowControllerActions
    let pageContainer = DashboardPageContainerViewController()
    let toolbarController = DashboardToolbarController()
    let accessoryHost = DashboardAccessoryHost()
    var platformCapabilities = DashboardPlatformCapabilities.current
    var sidebarScrollLayoutPolicy = DashboardSidebarScrollLayoutPolicy.current

    private(set) var section: DashboardSection = .general
    private(set) var mountedSection: DashboardSection = .general
    private(set) var selectedProviderID: String?
    private(set) var sourceListController: DashboardSourceListController?
    var shouldPreserveSectionSelection: ((DashboardSection) -> Bool)?
    var onPreservedSectionSelection: ((DashboardSection) -> Void)?
    var preparePageForDisplay: (() -> Void)?
    private var showsUpdateAvailableBadge = false
    private var isTornDown = false
    private weak var window: NSWindow?

    var contentHost: NSView { pageContainer.view }
    var scrollablePage: DashboardScrollablePageViewController? {
        pageContainer.currentPage as? DashboardScrollablePageViewController
    }

    init(actions: DashboardWindowControllerActions) {
        self.actions = actions
    }

    func installShell(on windowController: DashboardWindowController) {
        guard let window = windowController.window, !isTornDown else { return }
        self.window = window
        let reuseSplit = toolbarController.isSearchActive
            || toolbarController.hostsSearchResponder(window.firstResponder)
        sourceListController?.teardown()
        let sourceList = DashboardSourceListController(layoutPolicy: sidebarScrollLayoutPolicy)
        sourceList.setShowsUpdateAvailableBadge(showsUpdateAvailableBadge)
        sourceList.onSelectSection = { [weak self] section in
            self?.selectSection(section)
        }
        sourceListController = sourceList
        let sidebar = sourceList.makeSidebar(in: window)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.platformCapabilities = platformCapabilities
        let splitController: DashboardSplitViewController
        if reuseSplit,
           let existing = window.contentViewController as? DashboardSplitViewController,
           existing.contentController === pageContainer {
            existing.onSidebarGeometryDidChange = nil
            existing.replaceSidebar(with: sidebar)
            splitController = existing
        } else {
            detachPageContainerFromParent()
            splitController = DashboardSplitViewController(
                sidebarView: sidebar,
                content: pageContainer,
                capabilities: platformCapabilities
            )
        }
        windowController.attachShell(
            splitController,
            toolbar: toolbarController,
            accessoryHost: accessoryHost,
            applySidebarInset: { hostedWindow in
                sourceList.applyViewportTopInset(in: hostedWindow)
            }
        )
    }

    func rebuild(on windowController: DashboardWindowController) {
        guard let window = windowController.window, !isTornDown else { return }
        let searchWindow = window as? DashboardSearchWindow
        if toolbarController.isSearchActive
            || toolbarController.hostsSearchResponder(window.firstResponder) {
            searchWindow?.preservesToolbarSearchEditing = true
        }
        defer { searchWindow?.preservesToolbarSearchEditing = false }
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: contentHost)
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: window.contentView)
        let selectedSection = section
        let selectedProviderID = selectedProviderID
        installShell(on: windowController)
        if let selectedProviderID,
           actions.providerChoices().contains(where: { $0.id == selectedProviderID }) {
            showProvider(selectedProviderID)
        } else {
            selectSection(selectedSection)
        }
        window.displayIfNeeded()
        DashboardKeyViewLoop.invalidate(window)
        if AutomatedTestHost.isRunning {
            ApplicationWindowPresentation.presentInBackground(window)
        }
    }

    func showSection(_ section: DashboardSection) {
        guard !isTornDown else { return }
        self.section = section
        mountedSection = section
        selectedProviderID = nil
        window?.title = section.title
        sourceListController?.applySelection(section)
        replacePage {
            actions.makeSectionPage(section)
        }
    }

    func selectSection(_ section: DashboardSection) {
        guard !isTornDown else { return }
        if shouldPreserveSectionSelection?(section) == true {
            self.section = section
            selectedProviderID = nil
            window?.title = section.title
            sourceListController?.applySelection(section)
            onPreservedSectionSelection?(section)
            return
        }
        showSection(section)
    }

    func showSearchResults(makeContent: () -> NSView, preservingCurrentPage: Bool = false) {
        guard !isTornDown else { return }
        selectedProviderID = nil
        replacePage(prepareForPageReplacement: !preservingCurrentPage) {
            DashboardScrollablePageViewController(wrapping: makeContent())
        }
    }

    func showHostedSettingsContent(_ content: NSView) {
        guard !isTornDown else { return }
        selectedProviderID = nil
        replacePage(prepareForPageReplacement: false) {
            DashboardScrollablePageViewController(wrapping: content)
        }
    }

    func showProvider(_ providerID: String) {
        guard !isTornDown,
              let choice = actions.providerChoices().first(where: { $0.id == providerID })
        else { return }
        selectedProviderID = providerID
        mountedSection = section
        window?.title = choice.name
        sourceListController?.applySelection(nil)
        replacePage {
            actions.makeProviderPage(choice)
        }
    }

    func setShowsUpdateAvailableBadge(_ visible: Bool) {
        showsUpdateAvailableBadge = visible
        sourceListController?.setShowsUpdateAvailableBadge(visible)
    }

    func pageScrollOffsetY() -> CGFloat {
        scrollablePage?.scrollOffset ?? 0
    }

    func restorePageScrollOffsetY(_ offset: CGFloat) {
        scrollablePage?.restoreScrollOffset(offset)
    }

    func restoreCurrentPageScrollToTop() {
        scrollablePage?.restoreScrollOffset(0)
    }

    func currentHostedPageContent() -> NSView {
        if let scrollable = scrollablePage {
            return scrollable.hostedContent
        }
        return pageContainer.currentPage?.view ?? pageContainer.view
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        accessoryHost.detach()
        toolbarController.detach()
        sourceListController?.teardown()
        sourceListController = nil
        pageContainer.removeCurrentPage()
        window = nil
    }

    private func replacePage(
        prepareForPageReplacement: Bool = true,
        makePage: () -> NSViewController
    ) {
        if prepareForPageReplacement {
            DashboardSettingsComponents.disconnectPopUpButtonActions(in: contentHost)
            DashboardKeyViewLoop.prepareForPageReplacement(window)
            actions.prepareForPageReplacement()
        }
        let page = makePage()
        pageContainer.replacePage(page)
        accessoryHost.apply(page: page)
        // Complete the replacement synchronously so native accessibility
        // descendants are materialized before callers inspect the page
        // (notably on Xcode 16.4 CI).
        contentHost.layoutSubtreeIfNeeded()
        preparePageForDisplay?()
        window?.displayIfNeeded()
        actions.didShowPage()
        DashboardKeyViewLoop.invalidate(window)
        if AutomatedTestHost.isRunning, let window {
            ApplicationWindowPresentation.presentInBackground(window)
        }
    }

    private func detachPageContainerFromParent() {
        if pageContainer.parent != nil {
            pageContainer.removeFromParent()
        }
        pageContainer.view.removeFromSuperview()
    }
}
