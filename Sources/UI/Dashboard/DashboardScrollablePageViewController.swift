import AppKit

/// Owns a Dashboard page's scroll chrome after wrapping an existing page view:
/// `NSScrollView`, clip/document views, content insets, restore hooks, and
/// clip-view bounds listening.
///
/// Settings row layout stays in the wrapped content. Scroll-edge visual
/// effects stay off; `isAtTop` and `scrollOffset` are the only signals.
final class DashboardScrollablePageViewController: NSViewController {
    static let viewportTopInset: CGFloat = 52

    private let hostedView: NSView
    private var claimedScrollView: NSScrollView?
    private var clipViewObserver: NSObjectProtocol?

    init(wrapping pageView: NSView) {
        hostedView = pageView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        removeClipViewObserver()
    }

    override func loadView() {
        view = hostedView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        claimPageScrollView()
    }

    var isAtTop: Bool {
        abs(scrollOffset) <= DashboardScrollClampingPolicy.boundsOriginTolerance
    }

    var scrollOffset: CGFloat {
        guard let claimedScrollView else { return 0 }
        return DashboardPageScrollPosition.visualOffsetY(of: claimedScrollView)
    }

    func restoreScrollOffset(_ offset: CGFloat) {
        view.layoutSubtreeIfNeeded()
        guard let claimedScrollView else { return }
        DashboardPageScrollPosition.restore(visualOffsetY: offset, in: claimedScrollView)
    }

    var scrollViewForTesting: NSScrollView? { claimedScrollView }
    var documentViewForTesting: NSView? { claimedScrollView?.documentView }
    var clipViewForTesting: NSClipView? { claimedScrollView?.contentView }
    var clipViewObserverInstalledForTesting: Bool { clipViewObserver != nil }

    private func claimPageScrollView() {
        guard let scrollView = DashboardPageScrollPosition.firstScrollView(in: view) else {
            return
        }
        claimedScrollView = scrollView
        disableScrollEdgeEffects(scrollView)
        installClipViewObserver(on: scrollView.contentView)
    }

    private func disableScrollEdgeEffects(_ scrollView: NSScrollView) {
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
