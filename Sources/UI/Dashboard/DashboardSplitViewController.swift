import AppKit

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
    let platformCapabilities: DashboardPlatformCapabilities
    /// Legacy compatibility fill only. Native window surface must not create this view.
    private(set) var legacyContentSurface: NSView?
    private(set) var legacyBackdrop: NSVisualEffectView?
    var contentSplitViewItem: NSSplitViewItem? {
        splitViewItems.first { $0.viewController === contentController }
    }
    var onSidebarGeometryDidChange: (() -> Void)?
    private var splitResizeObserver: NSObjectProtocol?

    convenience init(
        sidebarView: NSView,
        content: NSViewController,
        capabilities: DashboardPlatformCapabilities = .current
    ) {
        self.init(
            sidebar: DashboardSidebarViewController(view: sidebarView),
            content: content,
            capabilities: capabilities
        )
    }

    init(
        sidebar: NSViewController,
        content: NSViewController,
        capabilities: DashboardPlatformCapabilities = .current
    ) {
        self.sidebarController = sidebar
        self.contentController = content
        self.platformCapabilities = capabilities
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
        Self.applyAdjacentContentSafeAreaPolicy(
            to: contentItem,
            capabilities: capabilities
        )
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    /// Native AppKit may overlay the sidebar on the adjacent content item and
    /// then adjust that item's `safeAreaInsets`. The flag belongs on the
    /// content item, not the sidebar item or AccessoryHost. `#available` stays
    /// because `automaticallyAdjustsSafeAreaInsets` is a macOS 26 API.
    static func applyAdjacentContentSafeAreaPolicy(
        to item: NSSplitViewItem,
        capabilities: DashboardPlatformCapabilities = .current
    ) {
        guard capabilities.adjustsAdjacentContentSafeArea else { return }
        if #available(macOS 26.0, *) {
            item.automaticallyAdjustsSafeAreaInsets = true
        }
    }

    override func loadView() {
        let root = DashboardContentRootView(frame: .zero)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view = root

        if platformCapabilities.usesNativeWindowSurface {
            // Leave the window surface and outline to AppKit. Do not keep a
            // hidden compatibility fill behind the native chrome.
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

    /// Legacy translucent shell. Window outline stays with NSWindow; do
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
