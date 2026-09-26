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
    private var cachedSectionPages: [DashboardSection: NSViewController] = [:]

    var contentHost: NSView { pageContainer.view }
    var scrollablePage: DashboardScrollablePageViewController? {
        pageContainer.currentPage as? DashboardScrollablePageViewController
    }

    init(actions: DashboardWindowControllerActions) {
        self.actions = actions
        toolbarController.onManualRefresh = actions.onManualRefresh
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
        DashboardPageInstrumentation.measure(.totalSelectionToReady) {
            self.showSectionMeasured(section)
        }
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

    private func detachPageContainerFromParent() {
        if pageContainer.parent != nil {
            pageContainer.removeFromParent()
        }
        pageContainer.view.removeFromSuperview()
    }
}
