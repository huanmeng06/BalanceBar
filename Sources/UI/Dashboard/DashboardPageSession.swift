import AppKit
import os

enum DashboardPageInstrumentation {
    enum Phase: String {
        case sidebarSelectionCallback = "sidebar-selection-callback"
        case prepareForPageReplacement = "prepare-for-page-replacement"
        case preferencePagesSuspend = "preference-pages-suspend"
        case preferencePagesTeardown = "preference-pages-teardown"
        case makeSectionPage = "make-section-page"
        case pageContainerReplace = "page-container-replace"
        case initialLayoutSettle = "initial-layout-settle"
        case displayIfNeeded = "display-if-needed"
        case didShowPage = "did-show-page"
        case recalculateKeyViewLoop = "recalculate-key-view-loop"
        case totalSelectionToReady = "selection-to-ready"
    }

    enum Boundary: Equatable {
        case begin
        case end
    }

    nonisolated(unsafe) static var eventRecorder: ((Phase, Boundary) -> Void)?

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "BalanceBar",
        category: "DashboardNavigation"
    )

    @discardableResult
    static func measure<T>(_ phase: Phase, _ work: () -> T) -> T {
        eventRecorder?(phase, .begin)
        os_signpost(.begin, log: log, name: "DashboardNavigation", "%{public}s", phase.rawValue)
        defer {
            os_signpost(.end, log: log, name: "DashboardNavigation", "%{public}s", phase.rawValue)
            eventRecorder?(phase, .end)
        }
        return work()
    }
}

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
    var onManualRefresh: () -> Void = {}
    var suspendSectionPage: (DashboardSection) -> Void = { _ in }
    var activateSectionPage: (DashboardSection) -> Void = { _ in }
    var invalidateSectionPages: () -> Void = {}
}

/// Composition-owned page, source-list, toolbar, and accessory session.
/// `DashboardWindowController` only attaches the resulting split onto an `NSWindow`.
final class DashboardPageSession {
    let actions: DashboardWindowControllerActions
    let pageContainer = DashboardPageContainerViewController()
    let toolbarController = DashboardToolbarController()
    let navigationHistory = DashboardNavigationHistory()
    let accessoryHost = DashboardAccessoryHost()
    var platformCapabilities = DashboardPlatformCapabilities.current
    var sidebarScrollLayoutPolicy = DashboardSidebarScrollLayoutPolicy.current

    private(set) var section: DashboardSection = .general
    private(set) var mountedSection: DashboardSection = .general
    private(set) var selectedProviderID: String?
    private(set) var sourceListController: DashboardSourceListController?
    var shouldPreserveSectionSelection: ((DashboardSection) -> Bool)?
    var onPreservedSectionSelection: ((DashboardSection) -> Void)?
    /// Feature-owned destinations (such as future notification child pages)
    /// are rendered by the feature while the history cursor remains owned by
    /// this session.
    var onShowExtendedNavigationDestination: ((String) -> Bool)?
    var preparePageForDisplay: (() -> Void)?
    private var showsUpdateAvailableBadge = false
    private var isTornDown = false
    private weak var window: NSWindow?
    private var cachedSectionPages: [DashboardSection: NSViewController] = [:]

    var contentHost: NSView { pageContainer.view }
    var scrollablePage: DashboardScrollablePageViewController? {
        pageContainer.currentPage as? DashboardScrollablePageViewController
    }
    var navigationDestination: DashboardNavigationDestination? {
        navigationHistory.currentDestination
    }

    init(actions: DashboardWindowControllerActions) {
        self.actions = actions
        toolbarController.onManualRefresh = actions.onManualRefresh
        toolbarController.onGoBack = { [weak self] in self?.goBack() }
        toolbarController.onGoForward = { [weak self] in self?.goForward() }
        updateNavigationToolbarState()
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
        invalidateCachedSectionPages()
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: contentHost)
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: window.contentView)
        let selectedSection = section
        let selectedProviderID = selectedProviderID
        installShell(on: windowController)
        if let destination = navigationHistory.currentDestination,
           canPresent(destination) {
            restoreNavigation(to: destination)
        } else if let selectedProviderID,
                  actions.providerChoices().contains(where: { $0.id == selectedProviderID }) {
            restoreNavigation(to: .provider(selectedProviderID))
        } else {
            restoreNavigation(to: .section(selectedSection))
        }
        window.displayIfNeeded()
        DashboardKeyViewLoop.invalidate(window)
        if AutomatedTestHost.isRunning {
            ApplicationWindowPresentation.presentInBackground(window)
        }
    }

    func showSection(_ section: DashboardSection) {
        navigate(to: .section(section))
    }

    private func showSectionMeasured(_ section: DashboardSection) {
        guard !isTornDown else { return }
        DashboardPageInstrumentation.measure(.sidebarSelectionCallback) {
            self.section = section
            self.selectedProviderID = nil
            self.window?.title = section.title
            self.sourceListController?.applySelection(section)
        }
        self.replacePage(activateSection: section) {
            if let cached = self.cachedSectionPages[section] {
                return cached
            }
            let page = DashboardPageInstrumentation.measure(.makeSectionPage) {
                self.actions.makeSectionPage(section)
            }
            self.cachedSectionPages[section] = page
            return page
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
        navigate(to: .provider(providerID))
    }

    /// Re-displays a destination without changing the history cursor. Shell
    /// rebuilds and search projections use this entry point so they cannot
    /// manufacture navigation entries while restoring the current page.
    func restoreNavigation(to destination: DashboardNavigationDestination) {
        navigate(to: destination, recordingHistory: false)
    }

    /// Entry point for future Dashboard feature pages. The session records the
    /// destination, updates toolbar state, and delegates route rendering to
    /// `onShowExtendedNavigationDestination` when the destination is a route.
    func navigate(to destination: DashboardNavigationDestination) {
        navigate(to: destination, recordingHistory: true)
    }

    private func goBack() {
        guard let destination = navigationHistory.goBack() else { return }
        guard canPresent(destination) else {
            _ = navigationHistory.goForward()
            return
        }
        updateNavigationToolbarState()
        present(destination)
    }

    private func goForward() {
        guard let destination = navigationHistory.goForward() else { return }
        guard canPresent(destination) else {
            _ = navigationHistory.goBack()
            return
        }
        updateNavigationToolbarState()
        present(destination)
    }

    private func navigate(
        to destination: DashboardNavigationDestination,
        recordingHistory: Bool
    ) {
        guard !isTornDown, canPresent(destination) else { return }
        if recordingHistory {
            navigationHistory.push(destination)
        }
        updateNavigationToolbarState()
        present(destination)
    }

    private func canPresent(_ destination: DashboardNavigationDestination) -> Bool {
        switch destination {
        case .section:
            return true
        case .provider(let providerID):
            return actions.providerChoices().contains { $0.id == providerID }
        case .route:
            return onShowExtendedNavigationDestination != nil
        }
    }

    private func present(_ destination: DashboardNavigationDestination) {
        switch destination {
        case .section(let section):
            DashboardPageInstrumentation.measure(.totalSelectionToReady) {
                self.showSectionMeasured(section)
            }
        case .provider(let providerID):
            guard let choice = actions.providerChoices().first(where: { $0.id == providerID }) else {
                return
            }
            selectedProviderID = providerID
            mountedSection = section
            window?.title = choice.name
            sourceListController?.applySelection(nil)
            replacePage {
                actions.makeProviderPage(choice)
            }
        case .route(let route):
            _ = onShowExtendedNavigationDestination?(route)
        }
    }

    func setShowsUpdateAvailableBadge(_ visible: Bool) {
        showsUpdateAvailableBadge = visible
        sourceListController?.setShowsUpdateAvailableBadge(visible)
    }

    func pageScrollOffsetY() -> CGFloat {
        scrollablePage?.scrollOffset ?? 0
    }

    func sectionScrollOffsetY(_ section: DashboardSection) -> CGFloat {
        (cachedSectionPages[section] as? DashboardScrollablePageViewController)?.scrollOffset ?? 0
    }

    func restorePageScrollOffsetY(_ offset: CGFloat) {
        scrollablePage?.restoreScrollOffset(offset)
    }

    func schedulePageScrollRestoration(_ offset: CGFloat) {
        scrollablePage?.scheduleVisualOffsetRestoration(offset)
    }

    func cancelScheduledPageScrollRestoration() {
        scrollablePage?.cancelScheduledVisualOffsetRestoration()
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
        invalidateCachedSectionPages()
        accessoryHost.detach()
        toolbarController.detach()
        sourceListController?.teardown()
        sourceListController = nil
        pageContainer.removeCurrentPage()
        window = nil
    }

    private func replacePage(
        prepareForPageReplacement: Bool = true,
        activateSection: DashboardSection? = nil,
        makePage: () -> NSViewController
    ) {
        actions.suspendSectionPage(mountedSection)
        if prepareForPageReplacement {
            DashboardPageInstrumentation.measure(.prepareForPageReplacement) {
                DashboardKeyViewLoop.prepareForPageReplacement(window)
                actions.prepareForPageReplacement()
            }
        }
        let page = makePage()
        DashboardPageInstrumentation.measure(.pageContainerReplace) {
            pageContainer.replacePage(page)
        }
        accessoryHost.apply(page: page)
        if let activateSection {
            mountedSection = activateSection
            actions.activateSectionPage(activateSection)
        }
        // Complete the replacement synchronously so native accessibility
        // descendants are materialized before callers inspect the page
        // (notably on Xcode 16.4 CI).
        DashboardPageInstrumentation.measure(.initialLayoutSettle) {
            contentHost.layoutSubtreeIfNeeded()
            if let scrollablePage = page as? DashboardScrollablePageViewController {
                scrollablePage.settleInitialLayout()
            }
        }
        preparePageForDisplay?()
        DashboardPageInstrumentation.measure(.displayIfNeeded) {
            window?.displayIfNeeded()
        }
        DashboardPageInstrumentation.measure(.didShowPage) {
            actions.didShowPage()
        }
        DashboardPageInstrumentation.measure(.recalculateKeyViewLoop) {
            DashboardKeyViewLoop.invalidate(window)
        }
        if AutomatedTestHost.isRunning, let window {
            ApplicationWindowPresentation.presentInBackground(window)
        }
    }

    private func invalidateCachedSectionPages() {
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: contentHost)
        for page in cachedSectionPages.values {
            DashboardSettingsComponents.disconnectPopUpButtonActions(in: page.view)
        }
        guard !cachedSectionPages.isEmpty else {
            actions.invalidateSectionPages()
            return
        }
        actions.invalidateSectionPages()
        cachedSectionPages.removeAll()
    }

    private func updateNavigationToolbarState() {
        toolbarController.setNavigationState(
            canGoBack: navigationHistory.canGoBack,
            canGoForward: navigationHistory.canGoForward
        )
    }

    private func detachPageContainerFromParent() {
        if pageContainer.parent != nil {
            pageContainer.removeFromParent()
        }
        pageContainer.view.removeFromSuperview()
    }
}
