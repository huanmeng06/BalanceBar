import AppKit

/// Owns a Dashboard page's scroll chrome: the unique page-level `NSScrollView`,
/// clip/document/content host, content insets, restore hooks, and clip-view
/// bounds listening.
///
/// Settings row layout stays in the hosted content. macOS 26+ overlaps the
/// titlebar so AppKit can inset content and choose Soft or Hard scroll-edge
/// automatically. macOS 14/15 keep the 52pt titlebar clearance and do not
/// imitate that effect. Compact viewports keep zero extra document spacing.
/// Tall viewports add one system-spacing document margin above the first
/// section; that margin scrolls away. The breakpoint is the page scroll
/// view's laid-out height, not zoom or fullscreen. No custom blur, shadow, gradient, hairline, forced
/// `.soft` / `.hard`, or private scroll-pocket API is installed. `isAtTop`
/// and `scrollOffset` remain page-local signals.
final class DashboardScrollablePageViewController: NSViewController {
    static let viewportBottomInset: CGFloat = 0
    static let documentHorizontalInset: CGFloat = 34
    static let spaciousTopSpacingMultiplier: CGFloat = 1
    /// Page-local responsive breakpoint. Default 620-pt windows stay compact;
    /// clearly taller viewports pick up one system-spacing document margin.
    static let spaciousViewportHeight: CGFloat = 760
    static let documentBottomInset: CGFloat = 34
    static let documentFillIdentifier = NSUserInterfaceItemIdentifier(
        "dashboardPageDocumentFill"
    )

    private struct RootAssembly {
        let root: NSView
        let compactContentTopConstraint: NSLayoutConstraint
        let spaciousContentTopConstraint: NSLayoutConstraint
    }

    let layoutPolicy: DashboardPageScrollLayoutPolicy
    let hostedContent: NSView
    let pageScrollView: NSScrollView
    private let pageClipView: NSClipView
    private let pageDocumentView: DashboardSettingsDocumentView
    private var compactContentTopConstraint: NSLayoutConstraint?
    private var spaciousContentTopConstraint: NSLayoutConstraint?
    private var usesSpaciousTopLayout = false
    /// `offset - spacing` captured when the breakpoint flips while scrolled.
    /// Applied on the next layout pass, after the new top constraint is in
    /// geometry; `layoutSubtreeIfNeeded()` is a no-op inside `viewDidLayout`.
    private var pendingScrolledOffsetBase: CGFloat?
    private var clipViewObserver: NSObjectProtocol?
    private var scrollViewFrameObserver: NSObjectProtocol?
    private var isUpdatingTopSpacingMode = false

    init(
        wrapping contentView: NSView,
        layoutPolicy: DashboardPageScrollLayoutPolicy = .current
    ) {
        hostedContent = contentView
        self.layoutPolicy = layoutPolicy
        pageScrollView = NSScrollView()
        pageClipView = NSClipView()
        pageDocumentView = DashboardSettingsDocumentView()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        removeLayoutObservers()
    }

    override func loadView() {
        let assembly = Self.makeRootView(
            hosting: hostedContent,
            scrollView: pageScrollView,
            clipView: pageClipView,
            documentView: pageDocumentView,
            layoutPolicy: layoutPolicy
        )
        compactContentTopConstraint = assembly.compactContentTopConstraint
        spaciousContentTopConstraint = assembly.spaciousContentTopConstraint
        view = assembly.root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installLayoutObservers()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyPendingScrolledOffsetCompensationIfNeeded()
        updateTopSpacingModeIfNeeded()
    }

    var isAtTop: Bool {
        abs(scrollOffset) <= DashboardScrollClampingPolicy.boundsOriginTolerance
    }

    var scrollOffset: CGFloat {
        DashboardPageScrollPosition.visualOffsetY(of: pageScrollView)
    }

    func restoreScrollOffset(_ offset: CGFloat) {
        view.layoutSubtreeIfNeeded()
        DashboardPageScrollPosition.restore(visualOffsetY: offset, in: pageScrollView)
    }

    var scrollViewForTesting: NSScrollView { pageScrollView }
    var documentViewForTesting: NSView { pageDocumentView }
    var clipViewForTesting: NSClipView { pageClipView }
    var hostedContentForTesting: NSView { hostedContent }
    var clipViewObserverInstalledForTesting: Bool { clipViewObserver != nil }
    /// Scroll-document margin above the first section. Chrome insets stay on
    /// `NSScrollView`; this value is content layout, so it scrolls away.
    /// Measured in the flipped document, not the unflipped host `frame`.
    var documentTopSpacingForTesting: CGFloat { documentTopSpacing }

    private var documentTopSpacing: CGFloat {
        let contentRect = hostedContent.convert(hostedContent.bounds, to: pageDocumentView)
        return contentRect.minY - pageDocumentView.bounds.minY
    }

    /// Right-pane vertical space: the page `NSScrollView`'s laid-out height.
    /// That is the clip view's height once AppKit tiles; the scroll view
    /// frame is available during Auto Layout, so resize/zoom/fullscreen all
    /// use one number. Clip-only bounds can stay 0 or stale in offscreen tests.
    private var pageViewportHeight: CGFloat {
        let scrollHeight = pageScrollView.bounds.height
        return scrollHeight > 1 ? scrollHeight : pageClipView.bounds.height
    }

    private func updateTopSpacingModeIfNeeded() {
        guard !isUpdatingTopSpacingMode else { return }
        let shouldUseSpaciousLayout =
            pageViewportHeight >= Self.spaciousViewportHeight
        guard shouldUseSpaciousLayout != usesSpaciousTopLayout else { return }

        let stayAtTop = isAtTop
        let spacingBefore = documentTopSpacing
        let offsetBefore = scrollOffset

        usesSpaciousTopLayout = shouldUseSpaciousLayout
        if shouldUseSpaciousLayout {
            compactContentTopConstraint?.isActive = false
            spaciousContentTopConstraint?.isActive = true
        } else {
            spaciousContentTopConstraint?.isActive = false
            compactContentTopConstraint?.isActive = true
        }

        isUpdatingTopSpacingMode = true
        hostedContent.superview?.needsLayout = true
        hostedContent.needsLayout = true
        hostedContent.superview?.layoutSubtreeIfNeeded()
        isUpdatingTopSpacingMode = false

        let spacingAfter = documentTopSpacing
        if stayAtTop {
            pendingScrolledOffsetBase = nil
        } else if abs(spacingAfter - spacingBefore) > 0.5 {
            pendingScrolledOffsetBase = nil
            DashboardPageScrollPosition.restore(
                visualOffsetY: offsetBefore + (spacingAfter - spacingBefore),
                in: pageScrollView
            )
        } else {
            pendingScrolledOffsetBase = offsetBefore - spacingBefore
            view.needsLayout = true
        }
    }

    private func applyPendingScrolledOffsetCompensationIfNeeded() {
        guard let offsetBase = pendingScrolledOffsetBase else { return }
        pendingScrolledOffsetBase = nil
        DashboardPageScrollPosition.restore(
            visualOffsetY: offsetBase + documentTopSpacing,
            in: pageScrollView
        )
    }

    /// Compatibility assembler for tests that still need a complete page view
    /// without a controller. Production pages go through this controller so
    /// the page-level scroll view is a typed, stable property.
    static func makePageView(
        hosting contentView: NSView,
        layoutPolicy: DashboardPageScrollLayoutPolicy = .current
    ) -> NSView {
        makeRootView(
            hosting: contentView,
            scrollView: NSScrollView(),
            clipView: NSClipView(),
            documentView: DashboardSettingsDocumentView(),
            layoutPolicy: layoutPolicy
        ).root
    }

    private static func makeRootView(
        hosting contentView: NSView,
        scrollView: NSScrollView,
        clipView: NSClipView,
        documentView: DashboardSettingsDocumentView,
        layoutPolicy: DashboardPageScrollLayoutPolicy = .current
    ) -> RootAssembly {
        let root = DashboardSettingsPageView()
        let viewportContainer = NSView()
        viewportContainer.translatesAutoresizingMaskIntoConstraints = false

        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        // macOS 26 overlaps the titlebar; 14/15 keep a layout gap. See
        // `DashboardPageScrollLayoutPolicy`.
        layoutPolicy.apply(to: scrollView)
        // Keep the scrollbar discoverable on dense settings pages. The
        // document is taller than the viewport when the status-link editor is
        // present, so hiding the scroller makes the add control look missing.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        documentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        if contentView.superview != nil {
            contentView.removeFromSuperview()
        }
        contentView.setContentHuggingPriority(.required, for: .vertical)
        contentView.setContentCompressionResistancePriority(.required, for: .vertical)
        if let stack = contentView as? NSStackView {
            stack.setHuggingPriority(.required, for: .vertical)
            stack.setClippingResistancePriority(.required, for: .vertical)
        }

        // Wrapper only: full-width document chrome around the inset page
        // stack. Section height belongs to SettingsSectionView / the page
        // stack; this host must not remeasure children or invalidate ICS
        // from layout().
        let contentHost = DashboardSettingsContentHost()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.clipsToBounds = false
        contentHost.setContentHuggingPriority(.required, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.required, for: .vertical)
        contentHost.addSubview(contentView)

        let documentFill = DashboardSettingsDocumentFillView()
        documentFill.identifier = documentFillIdentifier
        documentFill.translatesAutoresizingMaskIntoConstraints = false
        documentFill.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        documentFill.setContentCompressionResistancePriority(.required, for: .vertical)

        documentView.addSubview(contentHost)
        documentView.addSubview(documentFill)
        root.addSubview(viewportContainer)
        viewportContainer.addSubview(scrollView)

        let compactTopConstraint = contentView.topAnchor.constraint(
            equalTo: contentHost.topAnchor
        )
        let spaciousTopConstraint = contentView.topAnchor.constraint(
            equalToSystemSpacingBelow: contentHost.topAnchor,
            multiplier: spaciousTopSpacingMultiplier
        )
        spaciousTopConstraint.isActive = false

        NSLayoutConstraint.activate([
            viewportContainer.leadingAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.leadingAnchor
            ),
            viewportContainer.trailingAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.trailingAnchor
            ),
            viewportContainer.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: layoutPolicy.viewportTopInset
            ),
            viewportContainer.bottomAnchor.constraint(
                equalTo: root.bottomAnchor,
                constant: -viewportBottomInset
            ),
            scrollView.leadingAnchor.constraint(equalTo: viewportContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: viewportContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: viewportContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: viewportContainer.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.safeAreaLayoutGuide.heightAnchor
            ),
            contentHost.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            documentFill.topAnchor.constraint(equalTo: contentHost.bottomAnchor),
            documentFill.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            documentFill.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            documentFill.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentFill.heightAnchor.constraint(greaterThanOrEqualToConstant: documentBottomInset),
            compactTopConstraint,
            contentView.leadingAnchor.constraint(
                equalTo: contentHost.leadingAnchor,
                constant: documentHorizontalInset
            ),
            contentView.trailingAnchor.constraint(
                equalTo: contentHost.trailingAnchor,
                constant: -documentHorizontalInset
            ),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        return RootAssembly(
            root: root,
            compactContentTopConstraint: compactTopConstraint,
            spaciousContentTopConstraint: spaciousTopConstraint
        )
    }

    private func installLayoutObservers() {
        removeLayoutObservers()
        pageClipView.postsBoundsChangedNotifications = true
        clipViewObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: pageClipView,
            queue: nil
        ) { [weak self] _ in
            self?.handleClipViewBoundsChange()
        }
        pageScrollView.postsFrameChangedNotifications = true
        scrollViewFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pageScrollView,
            queue: nil
        ) { [weak self] _ in
            self?.updateTopSpacingModeIfNeeded()
        }
    }

    private func handleClipViewBoundsChange() {
        // Signal-only for scroll-edge chrome. Height changes also retarget
        // compact/spacious document spacing; origin-only scrolls are no-ops
        // because the mode guard compares viewport height, not offset.
        _ = isAtTop
        _ = scrollOffset
        updateTopSpacingModeIfNeeded()
    }

    private func removeLayoutObservers() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
            self.clipViewObserver = nil
        }
        if let scrollViewFrameObserver {
            NotificationCenter.default.removeObserver(scrollViewFrameObserver)
            self.scrollViewFrameObserver = nil
        }
    }
}

/// Full-width document wrapper around the inset page stack. It has no
/// intrinsic height of its own: hosted sections report height, the four-edge
/// pin sizes this wrapper, and leftover clip-view height stays in the fill.
private final class DashboardSettingsContentHost: NSView {}

/// Bottom spacer with a real intrinsic height. Views without intrinsic size
/// are treated as freely stretchable, which is what made SettingsRowView grow.
private final class DashboardSettingsDocumentFillView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: DashboardScrollablePageViewController.documentBottomInset
        )
    }
}
