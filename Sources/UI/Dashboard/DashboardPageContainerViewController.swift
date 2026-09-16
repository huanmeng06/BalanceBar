import AppKit

/// Content-pane owner for Dashboard pages. Page switches add and remove a
/// child `NSViewController` instead of swapping naked `NSView` subviews.
final class DashboardPageContainerViewController: NSViewController {
    private(set) var currentPage: NSViewController?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
    }

    func replacePage(_ page: NSViewController) {
        removeCurrentPage()
        addChild(page)
        installPageView(page.view)
        currentPage = page
    }

    /// Fill the content pane, but keep interactive page chrome in the split
    /// item's horizontal safe area. Top stays on the view edge so the existing
    /// titlebar inset is not doubled.
    private func installPageView(_ pageView: NSView) {
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func removeCurrentPage() {
        guard let currentPage else { return }
        currentPage.view.removeFromSuperview()
        currentPage.removeFromParent()
        self.currentPage = nil
    }
}

/// Adapter for page factories that still produce a view. It does not change
/// the wrapped page's internal layout or lifecycle beyond hosting it.
final class DashboardHostedPageViewController: NSViewController {
    private let hostedView: NSView

    init(wrapping pageView: NSView) {
        hostedView = pageView
        super.init(nibName: nil, bundle: nil)
    }

    convenience init() {
        self.init(wrapping: NSView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = hostedView
    }
}
