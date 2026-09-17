import AppKit

/// Owns a Dashboard page's scroll chrome: the unique page-level `NSScrollView`,
/// clip/document/content host, content insets, restore hooks, and clip-view
/// bounds listening.
///
/// Settings row layout stays in the hosted content. The page scroll view
/// occupies the pane top so AppKit can overlap the titlebar, write content
/// insets, and install the macOS 26 `NSScrollPocket`. That pocket is not
/// observable at 1x on this window: the unified toolbar is almost empty, the
/// titlebar is transparent, `titlebarSeparatorStyle` stays `.none` so a
/// window-wide line does not span the sidebar, and the #383 `contentSurface`
/// matches the toolbar band. Issue 401 then allows a page-local fallback:
/// a 1pt `separatorColor` hairline at the toolbar/content boundary, driven
/// by this page's `isAtTop` / `scrollOffset`. It is not a second glass bar,
/// a window-wide overlay, or a gradient over system chrome.
final class DashboardScrollablePageViewController: NSViewController {
    static let viewportTopInset: CGFloat = 0
    static let viewportBottomInset: CGFloat = 0
    static let documentHorizontalInset: CGFloat = 34
    static let documentBottomInset: CGFloat = 34
    static let documentFillIdentifier = NSUserInterfaceItemIdentifier(
        "dashboardPageDocumentFill"
    )
    static let scrollEdgeHairlineIdentifier = NSUserInterfaceItemIdentifier(
        "dashboardPageScrollEdgeHairline"
    )

    private let hostedContent: NSView
    let pageScrollView: NSScrollView
    private let pageClipView: NSClipView
    private let pageDocumentView: DashboardSettingsDocumentView
    private let scrollEdgeHairline = DashboardScrollEdgeHairline()
    private var scrollEdgeHairlineTopConstraint: NSLayoutConstraint?
    private var clipViewObserver: NSObjectProtocol?

    init(wrapping contentView: NSView) {
        hostedContent = contentView
        pageScrollView = NSScrollView()
        pageClipView = NSClipView()
        pageDocumentView = DashboardSettingsDocumentView()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        removeClipViewObserver()
    }

    override func loadView() {
        view = Self.makeRootView(
            hosting: hostedContent,
            scrollView: pageScrollView,
            clipView: pageClipView,
            documentView: pageDocumentView
        )
        installScrollEdgeHairline()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installClipViewObserver(on: pageClipView)
        updateScrollEdgeHairline()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateScrollEdgeHairline()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateScrollEdgeHairline()
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
        updateScrollEdgeHairline()
    }

    var scrollViewForTesting: NSScrollView { pageScrollView }
    var documentViewForTesting: NSView { pageDocumentView }
    var clipViewForTesting: NSClipView { pageClipView }
    var hostedContentForTesting: NSView { hostedContent }
    var clipViewObserverInstalledForTesting: Bool { clipViewObserver != nil }
    var scrollEdgeHairlineForTesting: NSView { scrollEdgeHairline }
    var scrollEdgeHairlineVisibleForTesting: Bool {
        !scrollEdgeHairline.isHidden && scrollEdgeHairline.alphaValue > 0.01
    }

    /// Compatibility assembler for tests that still need a complete page view
    /// without a controller. Production pages go through this controller so
    /// the page-level scroll view is a typed, stable property.
    static func makePageView(hosting contentView: NSView) -> NSView {
        makeRootView(
            hosting: contentView,
            scrollView: NSScrollView(),
            clipView: NSClipView(),
            documentView: DashboardSettingsDocumentView()
        )
    }

    static func makeRootView(
        hosting contentView: NSView,
        scrollView: NSScrollView,
        clipView: NSClipView,
        documentView: DashboardSettingsDocumentView
    ) -> NSView {
        let root = DashboardSettingsPageView()
        let viewportContainer = NSView()
        viewportContainer.translatesAutoresizingMaskIntoConstraints = false

        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        // Overlap the titlebar/toolbar so AppKit can apply content insets and
        // install NSScrollPocket. A layout gap above the scroll view would
        // keep content below chrome and suppress that pocket.
        scrollView.automaticallyAdjustsContentInsets = true
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

        NSLayoutConstraint.activate([
            viewportContainer.leadingAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.leadingAnchor
            ),
            viewportContainer.trailingAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.trailingAnchor
            ),
            viewportContainer.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: viewportTopInset
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
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
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
        return root
    }

    private func installClipViewObserver(on clipView: NSClipView) {
        removeClipViewObserver()
        clipView.postsBoundsChangedNotifications = true
        clipViewObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.handleClipViewBoundsChange()
        }
    }

    private func installScrollEdgeHairline() {
        scrollEdgeHairline.identifier = Self.scrollEdgeHairlineIdentifier
        scrollEdgeHairline.translatesAutoresizingMaskIntoConstraints = false
        scrollEdgeHairline.isHidden = true
        scrollEdgeHairline.alphaValue = 0
        view.addSubview(scrollEdgeHairline)

        let top = scrollEdgeHairline.topAnchor.constraint(
            equalTo: pageScrollView.topAnchor
        )
        scrollEdgeHairlineTopConstraint = top
        NSLayoutConstraint.activate([
            top,
            scrollEdgeHairline.leadingAnchor.constraint(equalTo: pageScrollView.leadingAnchor),
            scrollEdgeHairline.trailingAnchor.constraint(equalTo: pageScrollView.trailingAnchor),
            scrollEdgeHairline.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func updateScrollEdgeHairline() {
        let inset = pageScrollView.contentInsets.top
        if let constraint = scrollEdgeHairlineTopConstraint,
           abs(constraint.constant - inset) > 0.5 {
            constraint.constant = inset
        }
        // Only the toolbar/content boundary. Untitled fixtures without a
        // titlebar inset have nothing to mark, so stay hidden.
        let shouldShow = !isAtTop && inset > 0.5
        if scrollEdgeHairline.isHidden == !shouldShow,
           (scrollEdgeHairline.alphaValue > 0.01) == shouldShow {
            return
        }
        scrollEdgeHairline.isHidden = !shouldShow
        scrollEdgeHairline.alphaValue = shouldShow ? 1 : 0
    }

    private func handleClipViewBoundsChange() {
        updateScrollEdgeHairline()
    }

    private func removeClipViewObserver() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
            self.clipViewObserver = nil
        }
    }
}

/// 1pt native-colored hairline at the toolbar/content boundary. `NSBox.separator`
/// keeps a 5pt margin and is not a visible 1x edge here. Hit-testing is off
/// so the line cannot steal clicks from rows or the titlebar.
private final class DashboardScrollEdgeHairline: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateHairlineColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHairlineColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        _ = point
        return nil
    }

    private func updateHairlineColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
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
