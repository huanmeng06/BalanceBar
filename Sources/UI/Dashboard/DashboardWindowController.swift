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

final class DashboardContentRootView: NSView {
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

    let sidebarController: NSViewController
    let contentController: NSViewController
    /// macOS 14/15 compatibility fill only. Tahoe must not create this view.
    private(set) var legacyContentSurface: NSView?
    private(set) var legacyBackdrop: NSVisualEffectView?
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
        let root = DashboardContentRootView(frame: .zero)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view = root

        if #available(macOS 26.0, *) {
            // Leave the window surface and outline to AppKit. Do not keep a
            // hidden compatibility fill behind Tahoe's native chrome.
            legacyBackdrop = nil
            legacyContentSurface = nil
        } else {
            installLegacyCompatibilitySurface(on: root)
        }

        root.addSubview(splitView)
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

        var constraints = [
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ]
        if let legacyBackdrop {
            constraints.append(contentsOf: [
                legacyBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                legacyBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                legacyBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
                legacyBackdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }
        if let legacyContentSurface {
            constraints.append(contentsOf: [
                legacyContentSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                legacyContentSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                legacyContentSurface.topAnchor.constraint(equalTo: root.topAnchor),
                legacyContentSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Pre-Tahoe translucent shell. Window outline stays with NSWindow; do
    /// not clip this root to a fixed radius.
    private func installLegacyCompatibilitySurface(on root: DashboardContentRootView) {
        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.08),
            dark: NSColor.black.withAlphaComponent(0.14)
        ).cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false
        legacyBackdrop = effect
        root.addSubview(effect)

        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.isOpaque = false
        surface.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor(calibratedWhite: 0.94, alpha: 0.82),
            dark: NSColor.black.withAlphaComponent(0.20)
        ).cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        legacyContentSurface = surface
        root.addSubview(surface)
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
    var sidebarScrollLayoutPolicy = DashboardSidebarScrollLayoutPolicy.current
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
        let window = Self.makeUnpresentedWindow(initialSection: initialSection)
        restoreWindowedFrame(on: window)
        window.delegate = self

        self.window = window
        windowCreationCount += 1
        installLayout(in: window)
        installMouseMonitor()
        showSection(initialSection)
    }

    /// Production window configuration before restoration/presentation. The
    /// XCTest host deliberately changes opacity when parking a window, so
    /// surface assertions must inspect this boundary rather than `open()`.
    static func makeUnpresentedWindow(initialSection: DashboardSection) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = initialSection.title
        window.minSize = NSSize(width: 800, height: 540)
        window.titleVisibility = .hidden
        if #available(macOS 26.0, *) {
            // Apple’s macOS 26 scroll-edge path requires the title bar to
            // participate in the native window surface; a transparent title
            // bar leaves the inset geometry present but disables the visible
            // toolbar/content edge composition.
            window.titlebarAppearsTransparent = false
            // Use the native window surface on Tahoe rather than the legacy
            // translucent shell. AppKit owns scroll-edge rendering.
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
        } else {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.hasShadow = true
        window.appearance = nil
        window.isMovableByWindowBackground = false
        window.identifier = NSUserInterfaceItemIdentifier(DashboardShellRestoration.identity)
        window.isReleasedWhenClosed = false
        return window
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

    func bindSearchQueryHandler(_ handler: @escaping (String) -> Void) {
        toolbarController.onSearchQueryChanged = handler
    }

    func setSearchQuery(_ query: String) {
        toolbarController.setQuery(query)
    }

    var searchQuery: String { toolbarController.searchQuery }

    func currentHostedPageContent() -> NSView {
        if let scrollable = currentScrollablePage {
            return scrollable.hostedContent
        }
        return pageContainer.currentPage?.view ?? pageContainer.view
    }

    func restoreCurrentPageScrollToTop() {
        currentScrollablePage?.restoreScrollOffset(0)
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
        let sidebar = makeSidebar(in: window, layoutPolicy: sidebarScrollLayoutPolicy)
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
        // override `NSSplitViewItem.titlebarSeparatorStyle`. This controls
        // separators, not the Soft/Hard scroll-edge effect or its visibility.
        DashboardPageScrollLayoutPolicy.current.applyTitlebarSeparators(
            to: window,
            sidebarItem: splitController.splitViewItems.first,
            contentItem: splitController.contentSplitViewItem
        )
        window.layoutIfNeeded()
        applySidebarScrollViewportTopInset(
            layoutPolicy: sidebarScrollLayoutPolicy,
            sidebar: sidebar,
            window: window
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

    private func applySidebarScrollViewportTopInset(
        layoutPolicy: DashboardSidebarScrollLayoutPolicy,
        sidebar: NSView,
        window: NSWindow
    ) {
        guard let navigation = sourceListController?.view else { return }
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let constant = layoutPolicy.viewportTopInset(titlebarHeight: titlebarHeight)
        for constraint in sidebar.constraints
        where constraint.firstAttribute == .top
            && constraint.secondAttribute == .top
            && constraint.firstItem === navigation
            && constraint.secondItem === sidebar
        {
            constraint.constant = constant
            break
        }
    }

    private func makeSidebar(
        in window: NSWindow,
        layoutPolicy: DashboardSidebarScrollLayoutPolicy = .current
    ) -> NSView {
        let sidebar = NSView()

        sourceListController?.teardown()
        let sourceList = DashboardSourceListController(layoutPolicy: layoutPolicy)
        sourceList.setShowsUpdateAvailableBadge(showsUpdateAvailableBadge)
        sourceList.onSelectSection = { [weak self] section in
            self?.showSection(section)
        }
        sourceListController = sourceList

        let navigation = sourceList.view
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(
                equalTo: sidebar.topAnchor,
                constant: layoutPolicy.viewportTopInset(titlebarHeight: titlebarHeight)
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
