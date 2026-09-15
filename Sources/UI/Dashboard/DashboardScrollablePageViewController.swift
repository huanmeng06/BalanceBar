import AppKit

/// Owns a Dashboard page's scroll chrome: the unique page-level `NSScrollView`,
/// clip/document/content host, content insets, restore hooks, and clip-view
/// bounds listening.
///
/// Settings row layout stays in the hosted content. Scroll-edge visual
/// effects stay off; `isAtTop` and `scrollOffset` are the only signals.
final class DashboardScrollablePageViewController: NSViewController {
    static let viewportTopInset: CGFloat = 52
    static let viewportBottomInset: CGFloat = 0
    static let documentHorizontalInset: CGFloat = 34
    static let documentBottomInset: CGFloat = 34

    private let hostedContent: NSView
    let pageScrollView: NSScrollView
    private let pageClipView: NSClipView
    private let pageDocumentView: DashboardSettingsDocumentView
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installClipViewObserver(on: pageClipView)
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
        // Do not inherit a window/titlebar content inset when a fresh page is
        // mounted. AppKit still owns all user bounds and momentum behavior;
        // this only makes the scroll host's legal top coincide with its
        // document's top edge across window creation and page replacement.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
        documentView.addSubview(contentView)
        root.addSubview(viewportContainer)
        viewportContainer.addSubview(scrollView)

        NSLayoutConstraint.activate([
            viewportContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            viewportContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
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
                greaterThanOrEqualTo: scrollView.contentView.heightAnchor
            ),
            contentView.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentView.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor,
                constant: documentHorizontalInset
            ),
            contentView.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -documentHorizontalInset
            ),
            contentView.bottomAnchor.constraint(
                lessThanOrEqualTo: documentView.bottomAnchor,
                constant: -documentBottomInset
            )
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

    private func handleClipViewBoundsChange() {
        // Keep this a signal-only hook. Overlay, blur, and system scroll-edge
        // effects belong to later Issues.
        _ = isAtTop
        _ = scrollOffset
    }

    private func removeClipViewObserver() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
            self.clipViewObserver = nil
        }
    }
}
