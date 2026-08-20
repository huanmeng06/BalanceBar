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
    let makeSectionPage: (DashboardSection) -> NSView
    let makeProviderPage: (ProviderChoice) -> NSView
    let providerChoices: () -> [ProviderChoice]
    let prepareForPageReplacement: () -> Void
    let didShowPage: () -> Void
    let didClose: () -> Void
    let didResize: () -> Void
}

struct DashboardWindowDragRegion {
    let bounds: NSRect
    let titlebarHeight: CGFloat
    let excludedRects: [NSRect]

    var frame: NSRect {
        let height = min(max(0, titlebarHeight), bounds.height)
        return NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        )
    }

    func contains(_ point: NSPoint) -> Bool {
        guard frame.height > 0,
              NSPointInRect(point, frame),
              !excludedRects.contains(where: { NSPointInRect(point, $0) })
        else { return false }
        return true
    }
}

final class DashboardContentRootView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class DashboardTitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              alphaValue > 0,
              let window,
              !window.styleMask.contains(.fullScreen)
        else { return nil }

        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let region = DashboardWindowDragRegion(
            bounds: bounds,
            titlebarHeight: titlebarHeight,
            excludedRects: standardWindowButtonRects(in: window)
        )
        return region.contains(point) ? self : nil
    }

    private func standardWindowButtonRects(in window: NSWindow) -> [NSRect] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type), !button.isHidden else {
                return nil
            }
            return convert(button.bounds, from: button)
        }
    }
}

enum DashboardWindowDragPolicy {
    @discardableResult
    static func install(in window: NSWindow, contentRoot: NSView) -> DashboardTitlebarDragView {
        window.isMovableByWindowBackground = false

        let dragView = DashboardTitlebarDragView()
        dragView.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(dragView)
        NSLayoutConstraint.activate([
            dragView.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            dragView.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor)
        ])
        return dragView
    }
}

final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let actions: DashboardWindowControllerActions
    private(set) var window: NSWindow?
    private(set) var contentHost = NSView()
    private(set) var section: DashboardSection = .general
    private(set) var selectedProviderID: String?
    private(set) var windowCreationCount = 0
    private(set) var appearanceObserverInstallCount = 0
    private(set) var mouseMonitorInstallCount = 0

    private var navigationButtons: [DashboardSection: NSButton] = [:]
    private var navigationRows: [DashboardSection: DashboardNavigationRowView] = [:]
    private var appearanceObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var isTornDown = false

    init(actions: DashboardWindowControllerActions) {
        self.actions = actions
        super.init()
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

    func open() {
        guard !isTornDown else { return }
        start()
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = DashboardSection.general.title
        window.minSize = NSSize(width: 800, height: 540)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let dashboardToolbar = NSToolbar(identifier: NSToolbar.Identifier("BalanceBarDashboardToolbar"))
        dashboardToolbar.displayMode = .iconOnly
        dashboardToolbar.allowsUserCustomization = false
        dashboardToolbar.autosavesConfiguration = false
        window.toolbar = dashboardToolbar
        window.toolbarStyle = .unified
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = nil
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Keep the complete standard titlebar button group enabled so AppKit
        // owns the native colors, hover glyphs, pressed state, and zoom action.
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        self.window = window
        windowCreationCount += 1
        installLayout(in: window)
        installMouseMonitor()
        showSection(.general)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func rebuild() {
        guard let window, !isTornDown else { return }
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
    }

    func showSection(_ section: DashboardSection) {
        guard !isTornDown else { return }
        self.section = section
        selectedProviderID = nil
        window?.title = section.title
        updateNavigationSelection(selectedSection: section)
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
        updateNavigationSelection(selectedSection: nil)
        replacePage {
            actions.makeProviderPage(choice)
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true

        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        window?.delegate = nil
        window?.close()
        window = nil
        navigationButtons.removeAll()
        navigationRows.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === window else { return }
        actions.didClose()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        DashboardScrollTrace.marker("window-resize", source: "DashboardWindowController")
        actions.didResize()
    }

    private func replacePage(makePage: () -> NSView) {
        actions.prepareForPageReplacement()
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let page = makePage()
        page.frame = contentHost.bounds
        page.autoresizingMask = [.width, .height]
        contentHost.addSubview(page)
        // Complete the replacement synchronously so newly hosted SwiftUI
        // accessibility descendants are materialized before callers inspect
        // the page (notably on Xcode 16.4 CI).
        contentHost.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        actions.didShowPage()
    }

    private func updateNavigationSelection(selectedSection: DashboardSection?) {
        navigationButtons.forEach { key, button in
            let isCurrent = key == selectedSection
            button.state = isCurrent ? .on : .off
            button.isBordered = false
            button.contentTintColor = .clear
            navigationRows[key]?.isSelected = isCurrent
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
        let root = DashboardContentRootView(frame: window.contentView?.bounds ?? .zero)
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.08),
            dark: NSColor.black.withAlphaComponent(0.14)
        ).cgColor

        contentHost.removeFromSuperview()
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let sidebar = makeSidebar(titlebarHeight: titlebarHeight)
        let contentSurface = NSView()
        contentSurface.wantsLayer = true
        contentSurface.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor(calibratedWhite: 0.94, alpha: 0.82),
            dark: NSColor.black.withAlphaComponent(0.20)
        ).cgColor
        contentSurface.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentSurface)
        root.addSubview(sidebar)
        root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentSurface.topAnchor.constraint(equalTo: root.topAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 216),
            contentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        window.contentView = root
        DashboardWindowDragPolicy.install(in: window, contentRoot: root)
    }

    private func makeSidebar(titlebarHeight: CGFloat) -> NSView {
        let sidebar = NSView()
        let panelShadow = NSView()
        panelShadow.wantsLayer = true
        panelShadow.layer?.cornerRadius = 22
        panelShadow.layer?.shadowColor = NSColor.black.cgColor
        panelShadow.layer?.shadowOpacity = dashboardUsesDarkAppearance ? 0.18 : 0.08
        panelShadow.layer?.shadowRadius = 10
        panelShadow.layer?.shadowOffset = NSSize(width: 0, height: -2)
        panelShadow.layer?.masksToBounds = false
        panelShadow.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(panelShadow)

        let sidebarContent = NSView()
        let panel: NSView
        if let glassPanel = makeDashboardGlassEffectView(contentView: sidebarContent, cornerRadius: 22) {
            panel = glassPanel
        } else {
            let visualEffectPanel = NSVisualEffectView()
            visualEffectPanel.material = .sidebar
            visualEffectPanel.blendingMode = .withinWindow
            visualEffectPanel.state = .active
            visualEffectPanel.wantsLayer = true
            visualEffectPanel.layer?.cornerRadius = 22
            visualEffectPanel.layer?.masksToBounds = true
            sidebarContent.translatesAutoresizingMaskIntoConstraints = false
            visualEffectPanel.addSubview(sidebarContent)
            NSLayoutConstraint.activate([
                sidebarContent.topAnchor.constraint(equalTo: visualEffectPanel.topAnchor),
                sidebarContent.leadingAnchor.constraint(equalTo: visualEffectPanel.leadingAnchor),
                sidebarContent.trailingAnchor.constraint(equalTo: visualEffectPanel.trailingAnchor),
                sidebarContent.bottomAnchor.constraint(equalTo: visualEffectPanel.bottomAnchor)
            ])
            panel = visualEffectPanel
        }
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelShadow.addSubview(panel)

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 2
        navigationButtons.removeAll()
        navigationRows.removeAll()

        navigation.addArrangedSubview(makeNavigationRow(for: .general))
        navigation.setCustomSpacing(12, after: navigation.arrangedSubviews.last!)

        let appearanceLabel = makeSidebarGroupTitle(tr("外观", "Appearance"))
        navigation.addArrangedSubview(appearanceLabel)
        navigation.addArrangedSubview(makeNavigationRow(for: .menuBar))
        navigation.addArrangedSubview(makeNavigationRow(for: .menu))
        navigation.setCustomSpacing(12, after: navigation.arrangedSubviews.last!)

        let systemLabel = makeSidebarGroupTitle(tr("系统", "System"))
        navigation.addArrangedSubview(systemLabel)
        navigation.addArrangedSubview(makeNavigationRow(for: .advanced))
        navigation.addArrangedSubview(makeNavigationRow(for: .about))

        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(navigation)
        let panelInset: CGFloat = 8
        let navigationTopInset = max(0, titlebarHeight + 14 - panelInset)
        NSLayoutConstraint.activate([
            panelShadow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: panelInset),
            panelShadow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: panelInset),
            panelShadow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -panelInset),
            panelShadow.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -panelInset),
            panel.topAnchor.constraint(equalTo: panelShadow.topAnchor),
            panel.leadingAnchor.constraint(equalTo: panelShadow.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: panelShadow.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: panelShadow.bottomAnchor),
            navigation.topAnchor.constraint(equalTo: sidebarContent.topAnchor, constant: navigationTopInset),
            navigation.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 14),
            navigation.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor, constant: -14)
        ])
        return sidebar
    }

    private func makeSidebarGroupTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return label
    }

    private func makeNavigationRow(for section: DashboardSection) -> NSView {
        let row = DashboardNavigationRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.clear.cgColor
        row.widthAnchor.constraint(equalToConstant: 168).isActive = true
        row.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let button = NSButton(title: "", target: self, action: #selector(selectSection(_:)))
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .clear
        button.tag = section.rawValue
        button.focusRingType = .none
        button.toolTip = section.title
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        let icon = PassthroughImageView()
        icon.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = PassthroughTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(label)
        row.iconView = icon
        row.titleLabel = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        navigationButtons[section] = button
        navigationRows[section] = row
        row.updateAppearance(animated: false)
        return row
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let section = DashboardSection(rawValue: sender.tag) else { return }
        showSection(section)
    }
}
