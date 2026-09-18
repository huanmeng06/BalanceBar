import AppKit

func makeDashboardGlassEffectView(contentView: NSView, cornerRadius: CGFloat) -> NSView? {
    guard #available(macOS 26.0, *),
          let glassViewClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
        return nil
    }
    // Resolve this macOS 26 class dynamically so older SDKs can compile the source.
    let glassView = glassViewClass.init(frame: .zero)
    glassView.setValue(0, forKey: "style") // NSGlassEffectViewStyleRegular
    glassView.setValue(cornerRadius, forKey: "cornerRadius")
    glassView.setValue(contentView, forKey: "contentView")
    return glassView
}

struct DashboardWindowControllerActions {
    let makeSectionPage: (DashboardSection) -> NSViewController
    let makeProviderPage: (ProviderChoice) -> NSViewController
    let providerChoices: () -> [ProviderChoice]
    let prepareForPageReplacement: () -> Void
    let didShowPage: () -> Void
    let didClose: () -> Void
    let didResize: () -> Void
}

final class DashboardContentRootView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // fullSizeContentView draws under the titlebar. Empty chrome in that
        // band must reach NSThemeFrame so AppleActionOnDoubleClick and the
        // traffic lights keep working. Hits that already land on AppKit
        // controls stay with those controls so a window titlebar accessory
        // cannot disable sidebar navigation.
        guard let window else { return super.hitTest(point) }
        let pointInSelf = convert(point, from: superview)
        let layoutRectInSelf = convert(window.contentLayoutRect, from: nil)
        if layoutRectInSelf.height > 0, pointInSelf.y >= layoutRectInSelf.maxY {
            let hit = super.hitTest(point)
            if let hit, isInteractiveControl(hit) {
                return hit
            }
            return nil
        }
        return super.hitTest(point)
    }

    private func isInteractiveControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current, node !== self {
            if node is NSControl || node is NSOutlineView || node is NSTableView {
                return true
            }
            current = node.superview
        }
        return false
    }
}

/// Native Dashboard shell. The split view owns the sidebar/content geometry;
/// page controllers remain responsible only for their own content.
final class DashboardSplitViewController: NSSplitViewController {
    /// Opening width from the #383/#384 baseline, seeded via the sidebar
    /// view's initial frame. `preferredThicknessFraction` is a size fraction
    /// of the split view, not an absolute point width, and is left at factory.
    static let preferredSidebarThickness: CGFloat = 216
    static let sidebarThickness: CGFloat = preferredSidebarThickness
    /// 168pt navigation rows plus the former 14pt stack and 8pt panel insets.
    /// Kept so the pre-#386 rows still fit; do not shrink after removing the
    /// custom sidebar glass panel.
    static let minimumSidebarThickness: CGFloat = 8 + 14 + 168 + 14 + 8
    /// Product cap for divider resizing. Factory sidebar maximum is
    /// `unspecifiedDimension`; 320 is the actual upper bound.
    static let maximumSidebarThickness: CGFloat = 320
    /// Sidebar holds its current width; content uses `.defaultLow` so window
    /// resize is absorbed by the content pane.
    static let sidebarHoldingPriority = NSLayoutConstraint.Priority(
        rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 1
    )
    static let contentHoldingPriority = NSLayoutConstraint.Priority.defaultLow
    static let contentSurfaceIdentifier = NSUserInterfaceItemIdentifier("dashboardContentSurface")

    let sidebarController: NSViewController
    let contentController: NSViewController
    private(set) var contentSurface = NSView()
    var contentSplitViewItem: NSSplitViewItem? {
        splitViewItems.first { $0.viewController === contentController }
    }
    var onSidebarGeometryDidChange: (() -> Void)?
    private var splitResizeObserver: NSObjectProtocol?

    init(sidebar: NSViewController, content: NSViewController) {
        self.sidebarController = sidebar
        self.contentController = content
        super.init(nibName: nil, bundle: nil)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = max(
            sidebarItem.minimumThickness,
            Self.minimumSidebarThickness
        )
        sidebarItem.maximumThickness = Self.maximumSidebarThickness
        sidebarItem.holdingPriority = Self.sidebarHoldingPriority

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.canCollapse = false
        contentItem.holdingPriority = Self.contentHoldingPriority
        Self.applyAdjacentContentSafeAreaPolicy(to: contentItem)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    /// macOS 26 may overlay the sidebar on the adjacent content item and then
    /// adjust that item's `safeAreaInsets`. The flag belongs on the content
    /// item, not the sidebar item or AccessoryHost.
    static func applyAdjacentContentSafeAreaPolicy(to item: NSSplitViewItem) {
        if #available(macOS 26.0, *) {
            item.automaticallyAdjustsSafeAreaInsets = true
        }
    }

    override func loadView() {
        let backdrop = DashboardContentRootView(frame: .zero)
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.08),
            dark: NSColor.black.withAlphaComponent(0.14)
        ).cgColor

        contentSurface.identifier = Self.contentSurfaceIdentifier
        contentSurface.wantsLayer = true
        contentSurface.layer?.isOpaque = false
        // Full-window tint from the #383 baseline. The split view stays
        // transparent so this surface, not a darker content-pane overlay,
        // provides light/dark contrast over the visual-effect backdrop.
        contentSurface.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor(calibratedWhite: 0.94, alpha: 0.82),
            dark: NSColor.black.withAlphaComponent(0.20)
        ).cgColor
        contentSurface.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false

        view = backdrop
        backdrop.addSubview(contentSurface)
        backdrop.addSubview(splitView)
        if let splitResizeObserver {
            NotificationCenter.default.removeObserver(splitResizeObserver)
        }
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak self] _ in
            self?.onSidebarGeometryDidChange?()
        }
        NSLayoutConstraint.activate([
            contentSurface.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            contentSurface.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            contentSurface.topAnchor.constraint(equalTo: backdrop.topAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
    }

    deinit {
        if let splitResizeObserver {
            NotificationCenter.default.removeObserver(splitResizeObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class DashboardSidebarViewController: NSViewController {
    private let hostedView: NSView
    init(view: NSView) { hostedView = view; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = hostedView }
}

final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let actions: DashboardWindowControllerActions
    private let restorationStore: DashboardShellRestorationStoring
    private let pageContainer = DashboardPageContainerViewController()
    private let toolbarController = DashboardToolbarController()
    private let accessoryHost = DashboardAccessoryHost()
    private(set) var window: NSWindow?
    var contentHost: NSView { pageContainer.view }
    private(set) var section: DashboardSection = .general
    private(set) var selectedProviderID: String?
    private(set) var windowCreationCount = 0
    private(set) var appearanceObserverInstallCount = 0
    private(set) var mouseMonitorInstallCount = 0
    private(set) var lastFramePlacement: DashboardShellFramePlacement?

    private var sourceListController: DashboardSourceListController?
    private var showsUpdateAvailableBadge = false
    private var appearanceObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var isTornDown = false
    private var isApplyingRestoration = false
    private var lastExpandedSidebarWidth: CGFloat?
    private var lastPersistedWindowedFrame: NSRect?

    init(
        actions: DashboardWindowControllerActions,
        restorationStore: DashboardShellRestorationStoring = DashboardShellRestoration.makeDefaultStore()
    ) {
        self.actions = actions
        self.restorationStore = restorationStore
        super.init()
        if let saved = restorationStore.load() {
            lastPersistedWindowedFrame = saved.windowedFrame
            if let savedWidth = saved.sidebarWidth {
                lastExpandedSidebarWidth = DashboardShellRestoration.clampSidebarWidth(savedWidth)
            }
        }
    }

    deinit {
        teardown()
    }

    func start() {
        guard !isTornDown, appearanceObserver == nil else { return }
        appearanceObserverInstallCount += 1
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Let AppKit publish the new effective appearance before resolving
            // the small number of CALayer-backed adaptive colors.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.window?.appearance = nil
                self.rebuild()
            }
        }
    }

    func open(
        initialSection: DashboardSection = .general,
        scrollOffsetY: CGFloat? = nil
    ) {
        guard !isTornDown else { return }
        start()

        let isNewWindow = window == nil
        if isNewWindow {
            createDashboardWindow(initialSection: initialSection)
        }

        // Become regular only after the dashboard window exists. Switching
        // accessory → regular with no key window lets a leftover menu-bar
        // click highlight Window.
        presentOpenedDashboardWindow()

        if isNewWindow, scrollOffsetY != nil {
            window?.makeFirstResponder(nil)
            if let scrollOffsetY {
                restorePageScrollOffsetY(scrollOffsetY)
            }
        }
    }

    private func createDashboardWindow(initialSection: DashboardSection) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = initialSection.title
        window.minSize = NSSize(width: 800, height: 540)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = nil
        window.isMovableByWindowBackground = false
        window.identifier = NSUserInterfaceItemIdentifier(DashboardShellRestoration.identity)
        restoreWindowedFrame(on: window)
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        windowCreationCount += 1
        installLayout(in: window)
        installMouseMonitor()
        showSection(initialSection)
    }

    private func presentOpenedDashboardWindow() {
        guard let window else { return }
        dismissApplicationMenuTracking()
        if !AutomatedTestHost.isRunning {
            _ = NSApp.setActivationPolicy(.regular)
        }
        ApplicationWindowPresentation.present(window)
        dismissApplicationMenuTracking()
        guard !AutomatedTestHost.isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dismissApplicationMenuTracking()
        }
    }

    private func dismissApplicationMenuTracking() {
        NSApp.mainMenu?.cancelTracking()
        NSApp.windowsMenu?.cancelTracking()
    }

    func pageScrollOffsetY() -> CGFloat {
        currentScrollablePage?.scrollOffset ?? 0
    }

    func restorePageScrollOffsetY(_ offset: CGFloat) {
        window?.layoutIfNeeded()
        contentHost.layoutSubtreeIfNeeded()
        currentScrollablePage?.restoreScrollOffset(offset)
        window?.makeFirstResponder(nil)
    }

    func rebuild() {
        guard let window, !isTornDown else { return }
        // Delayed AppKit popup actions can fire after the page is replaced.
        // Clear target/action first so a leftover language cannot be written.
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: contentHost)
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: window.contentView)
        let selectedSection = section
        let selectedProviderID = selectedProviderID
        installLayout(in: window)
        if let selectedProviderID,
           actions.providerChoices().contains(where: { $0.id == selectedProviderID }) {
            showProvider(selectedProviderID)
        } else {
            showSection(selectedSection)
        }
        window.displayIfNeeded()
        if AutomatedTestHost.isRunning {
            ApplicationWindowPresentation.presentInBackground(window)
        }
    }

    func showSection(_ section: DashboardSection) {
        guard !isTornDown else { return }
        self.section = section
        selectedProviderID = nil
        window?.title = section.title
        sourceListController?.applySelection(section)
        replacePage {
            actions.makeSectionPage(section)
        }
    }

    func showProvider(_ providerID: String) {
        guard !isTornDown,
              let choice = actions.providerChoices().first(where: { $0.id == providerID })
        else { return }
        selectedProviderID = providerID
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

    func teardown() {
        guard !isTornDown else { return }
        persistShellGeometry()
        isTornDown = true

        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        accessoryHost.detach()
        window?.delegate = nil
        window?.close()
        window = nil
        sourceListController?.teardown()
        sourceListController = nil
        pageContainer.removeCurrentPage()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === window else { return }
        persistShellGeometry()
        actions.didClose()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        DashboardScrollTrace.marker("window-resize", source: "DashboardWindowController")
        actions.didResize()
        if !resizedWindow.inLiveResize {
            persistShellGeometry()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow === window else { return }
        persistShellGeometry()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        persistShellGeometry()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let fullScreenWindow = notification.object as? NSWindow,
              fullScreenWindow === window else { return }
        persistShellGeometry()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let fullScreenWindow = notification.object as? NSWindow,
              fullScreenWindow === window else { return }
        persistShellGeometry()
    }

    private func replacePage(makePage: () -> NSViewController) {
        DashboardSettingsComponents.disconnectPopUpButtonActions(in: contentHost)
        actions.prepareForPageReplacement()
        let page = makePage()
        pageContainer.replacePage(page)
        accessoryHost.apply(page: page)
        // Complete the replacement synchronously so native accessibility
        // descendants are materialized before callers inspect the page
        // (notably on Xcode 16.4 CI).
        contentHost.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        actions.didShowPage()
        if AutomatedTestHost.isRunning, let window {
            ApplicationWindowPresentation.presentInBackground(window)
        }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitorInstallCount += 1
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            self?.finishEditingIfClickIsOutsideInput(event)
            return event
        }
    }

    private func finishEditingIfClickIsOutsideInput(_ event: NSEvent) {
        guard let window,
              event.window === window,
              let hitView = window.contentView?.hitTest(event.locationInWindow)
        else { return }

        // Keep the field active when the user clicks inside another editable
        // text control. Clicking labels, cards, buttons, or blank space should
        // commit the current editor before the click is handled normally.
        var view: NSView? = hitView
        while let current = view {
            if let textField = current as? NSTextField, textField.isEditable {
                return
            }
            view = current.superview
        }
        guard window.firstResponder != nil else { return }
        window.makeFirstResponder(nil)
    }

    private func installLayout(in window: NSWindow) {
        let liveSidebar = liveSidebarSeed()
        detachPageContainerFromParent()
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let sidebar = makeSidebar(titlebarHeight: titlebarHeight)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let plan = restorationPlan(for: window)
        let seedWidth = liveSidebar.width ?? plan.sidebarWidth
        let collapsed = liveSidebar.collapsed ?? plan.isSidebarCollapsed
        sidebar.setFrameSize(
            NSSize(
                width: seedWidth,
                height: window.frame.height
            )
        )
        let splitController = DashboardSplitViewController(
            sidebar: DashboardSidebarViewController(view: sidebar),
            content: pageContainer
        )
        splitController.onSidebarGeometryDidChange = { [weak self] in
            self?.persistShellGeometry()
        }
        isApplyingRestoration = true
        let requestedFrame = window.frame
        window.contentViewController = splitController
        // AppKit may fit a newly installed split-view controller to its
        // minimum thicknesses. Preserve the current window frame after
        // installing the native hierarchy. Sidebar width is seeded from
        // restored/live geometry, not a locked thickness; min/max still
        // allow native divider resizing.
        window.setFrame(requestedFrame, display: false)
        // Install the toolbar after the split view is the window's content
        // controller so AppKit can bind the standard tracking separator.
        toolbarController.install(on: window)
        accessoryHost.attach(window: window, splitViewController: splitController)
        // After the tracking separator exists, restore the public pane
        // titlebar-separator preference. A window-level `.none` would
        // override `NSSplitViewItem.titlebarSeparatorStyle` and suppress the
        // system scroll-edge on macOS 26.
        DashboardPageScrollLayoutPolicy.current.applyTitlebarSeparators(
            to: window,
            sidebarItem: splitController.splitViewItems.first,
            contentItem: splitController.contentSplitViewItem
        )
        window.layoutIfNeeded()
        if collapsed {
            splitController.splitViewItems[0].isCollapsed = true
        }
        lastExpandedSidebarWidth = seedWidth
        isApplyingRestoration = false
    }

    private func restoreWindowedFrame(on window: NSWindow) {
        // Keep a dedicated AppKit identity. The Bool is only "name was set",
        // not "a saved frame was restored", so it never chooses placement.
        if !AutomatedTestHost.isRunning {
            _ = window.setFrameAutosaveName(DashboardShellRestoration.frameAutosaveName)
        }

        isApplyingRestoration = true
        let placement = DashboardShellRestoration.framePlacement(
            saved: restorationStore.load(),
            defaultFrame: window.frame,
            screens: DashboardShellRestoration.currentScreens(),
            minSize: window.minSize
        )
        lastFramePlacement = placement
        switch placement {
        case .restored(let frame):
            window.setFrame(frame, display: false)
        case .defaultCentered:
            window.center()
        }
        if AutomatedTestHost.isRunning {
            ApplicationWindowPresentation.prepare(window)
        }
        isApplyingRestoration = false
    }

    private func restorationPlan(for window: NSWindow) -> DashboardShellRestorationState {
        DashboardShellRestoration.plan(
            saved: restorationStore.load(),
            defaultFrame: window.frame,
            screens: DashboardShellRestoration.currentScreens(),
            minSize: window.minSize
        )
    }

    private func liveSidebarSeed() -> (width: CGFloat?, collapsed: Bool?) {
        guard let splitController = window?.contentViewController as? DashboardSplitViewController,
              let item = splitController.splitViewItems.first
        else { return (nil, nil) }
        let collapsed = item.isCollapsed
        let width = item.viewController.view.frame.width
        if collapsed {
            return (lastExpandedSidebarWidth, true)
        }
        if width > 1 {
            lastExpandedSidebarWidth = DashboardShellRestoration.clampSidebarWidth(width)
        }
        return (lastExpandedSidebarWidth, false)
    }

    private func persistShellGeometry() {
        guard !isApplyingRestoration, !isTornDown, let window else { return }
        let splitController = window.contentViewController as? DashboardSplitViewController
        let sidebarItem = splitController?.splitViewItems.first
        let collapsed = sidebarItem?.isCollapsed ?? false
        let liveWidth = sidebarItem?.viewController.view.frame.width ?? 0
        if !collapsed, liveWidth > 1 {
            lastExpandedSidebarWidth = DashboardShellRestoration.clampSidebarWidth(liveWidth)
        }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        let currentFrame: NSRect
        if AutomatedTestHost.isRunning, window.frame.origin.x <= -9_000 {
            currentFrame = lastPersistedWindowedFrame
                ?? restorationStore.load()?.windowedFrame
                ?? window.frame
        } else {
            currentFrame = window.frame
        }
        let persistedFrame = DashboardShellRestoration.persistedWindowedFrame(
            currentFrame: currentFrame,
            isFullScreen: isFullScreen,
            previouslySavedFrame: lastPersistedWindowedFrame
        )
        guard let persistedFrame else { return }
        lastPersistedWindowedFrame = persistedFrame
        let width = lastExpandedSidebarWidth
            ?? restorationStore.load()?.sidebarWidth
            ?? DashboardShellRestoration.defaultSidebarWidth
        restorationStore.save(
            DashboardShellRestorationState(
                windowedFrame: persistedFrame,
                sidebarWidth: DashboardShellRestoration.clampSidebarWidth(width),
                isSidebarCollapsed: collapsed
            )
        )
    }

    private func makeSidebar(titlebarHeight: CGFloat) -> NSView {
        let sidebar = NSView()

        sourceListController?.teardown()
        let sourceList = DashboardSourceListController()
        sourceList.setShowsUpdateAvailableBadge(showsUpdateAvailableBadge)
        sourceList.onSelectSection = { [weak self] section in
            self?.showSection(section)
        }
        sourceListController = sourceList

        let navigation = sourceList.view
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        // Full-height sidebar sits under the titlebar. Keep the source-list
        // below traffic lights without a custom glass/card wrapper.
        // Scroll-edge content insets belong to #401.
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(
                equalTo: sidebar.topAnchor,
                constant: max(0, titlebarHeight + 14)
            ),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            navigation.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        return sidebar
    }

    private func detachPageContainerFromParent() {
        if pageContainer.parent != nil {
            pageContainer.removeFromParent()
        }
        pageContainer.view.removeFromSuperview()
    }

    var sourceListForTesting: DashboardSourceListController? { sourceListController }
    var pageContainerForTesting: DashboardPageContainerViewController { pageContainer }
    var accessoryHostForTesting: DashboardAccessoryHost { accessoryHost }
    var scrollablePageForTesting: DashboardScrollablePageViewController? {
        currentScrollablePage
    }

    private var currentScrollablePage: DashboardScrollablePageViewController? {
        pageContainer.currentPage as? DashboardScrollablePageViewController
    }
}
