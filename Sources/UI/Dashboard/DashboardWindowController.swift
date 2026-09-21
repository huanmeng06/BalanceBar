import AppKit

/// Window lifecycle owner. Sidebar, pages, toolbar items, and accessories are
/// attached here but implemented by their dedicated controllers.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let restorationStore: DashboardShellRestorationStoring
    var didClose: (() -> Void)?
    var didResize: (() -> Void)?
    var onAppearanceDidChange: (() -> Void)?

    private(set) var window: NSWindow?
    private(set) var windowCreationCount = 0
    private(set) var appearanceObserverInstallCount = 0
    private(set) var mouseMonitorInstallCount = 0
    private(set) var lastFramePlacement: DashboardShellFramePlacement?

    private var appearanceObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var isTornDown = false
    private var isApplyingRestoration = false
    private var lastExpandedSidebarWidth: CGFloat?
    private var lastPersistedWindowedFrame: NSRect?
    private var attachedAccessoryHost: DashboardAccessoryHost?

    init(
        restorationStore: DashboardShellRestorationStoring = DashboardShellRestoration.makeDefaultStore()
    ) {
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
                self.onAppearanceDidChange?()
            }
        }
    }

    /// Create and restore the window without presenting it. Callers attach the
    /// split/pages first, then `present()`, matching AppKit's
    /// configure-then-order-front sequence.
    func open(initialSection: DashboardSection = .general) {
        guard !isTornDown else { return }
        start()

        if window == nil {
            createDashboardWindow(initialSection: initialSection)
        }
    }

    func present() {
        // Become regular only after the dashboard window exists. Switching
        // accessory → regular with no key window lets a leftover menu-bar
        // click highlight Window.
        presentOpenedDashboardWindow()
    }

    private func createDashboardWindow(initialSection: DashboardSection) {
        let window = Self.makeUnpresentedWindow(initialSection: initialSection)
        restoreWindowedFrame(on: window)
        window.delegate = self

        self.window = window
        windowCreationCount += 1
        installMouseMonitor()
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
        window.autorecalculatesKeyViewLoop = true
        return window
    }

    /// Hang the already-built split, toolbar, and accessory host on this window.
    /// Sidebar width/collapse come from live geometry or #411 restoration.
    func attachShell(
        _ splitController: DashboardSplitViewController,
        toolbar: DashboardToolbarController,
        accessoryHost: DashboardAccessoryHost,
        applySidebarInset: (NSWindow) -> Void
    ) {
        guard let window, !isTornDown else { return }
        let liveSidebar = liveSidebarSeed()
        let plan = restorationPlan(for: window)
        let seedWidth = liveSidebar.width ?? plan.sidebarWidth
        let collapsed = liveSidebar.collapsed ?? plan.isSidebarCollapsed
        splitController.sidebarController.view.setFrameSize(
            NSSize(
                width: seedWidth,
                height: window.frame.height
            )
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
        toolbar.install(on: window)
        accessoryHost.attach(window: window, splitViewController: splitController)
        attachedAccessoryHost = accessoryHost
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
        applySidebarInset(window)
        window.layoutIfNeeded()
        if collapsed {
            splitController.splitViewItems[0].isCollapsed = true
        }
        lastExpandedSidebarWidth = seedWidth
        isApplyingRestoration = false
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
        attachedAccessoryHost?.detach()
        attachedAccessoryHost = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === window else { return }
        persistShellGeometry()
        didClose?()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        DashboardScrollTrace.marker("window-resize", source: "DashboardWindowController")
        didResize?()
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
}

/// AppKit automatic key-view loop maintenance for Dashboard structural changes.
enum DashboardKeyViewLoop {
    static func invalidate(_ window: NSWindow?) {
        window?.recalculateKeyViewLoop()
    }

    /// Ends editing and resigns page controls before the current page is
    /// removed. Toolbar search and the source list stay first responder.
    static func prepareForPageReplacement(_ window: NSWindow?) {
        guard let window else { return }
        guard let responder = window.firstResponder,
              !isPreservedNavigationSurface(responder) else {
            return
        }
        window.endEditing(for: nil)
        if let remaining = window.firstResponder,
           !isPreservedNavigationSurface(remaining) {
            _ = window.makeFirstResponder(nil)
        }
    }

    static func resignUnreachableFirstResponder(_ window: NSWindow?) {
        guard let window else { return }
        guard let responder = window.firstResponder else { return }
        if isPreservedNavigationSurface(responder) {
            return
        }
        window.endEditing(for: nil)
        guard let remaining = window.firstResponder,
              !isPreservedNavigationSurface(remaining),
              isUnreachable(remaining, in: window) else {
            return
        }
        _ = window.makeFirstResponder(nil)
    }

    private static func isPreservedNavigationSurface(_ responder: NSResponder) -> Bool {
        if responder is NSSearchField || responder is NSOutlineView {
            return true
        }
        if let field = associatedTextField(for: responder), field is NSSearchField {
            return true
        }
        return false
    }

    private static func associatedTextField(for responder: NSResponder) -> NSTextField? {
        if let field = responder as? NSTextField {
            return field
        }
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            return textView.delegate as? NSTextField
        }
        return nil
    }

    private static func isUnreachable(_ responder: NSResponder, in window: NSWindow) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let field = textView.delegate as? NSTextField {
                return isUnreachableView(field, in: window)
            }
            return true
        }
        if let field = associatedTextField(for: responder) {
            return isUnreachableView(field, in: window)
        }
        guard let view = responder as? NSView else { return false }
        return isUnreachableView(view, in: window)
    }

    private static func isUnreachableView(_ view: NSView, in window: NSWindow) -> Bool {
        if view.window !== window {
            return true
        }
        if view.isHiddenOrHasHiddenAncestor {
            return true
        }
        var current: NSView? = view
        while let candidate = current {
            if DashboardSearchVisibility.isCollapsedForSearchLayout(candidate) {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
