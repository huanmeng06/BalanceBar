import AppKit

/// Non-production window that reuses the real Dashboard split view, toolbar,
/// and accessory host so a human can verify page accessory ownership:
/// `.none`, `.windowTitlebar`, and `.contentSplitItem`.
/// A window-titlebar accessory is owned by the window even if a floating
/// sidebar visually covers part of it. This harness never installs
/// accessories on the official Dashboard composition.
final class DashboardAccessoryHarnessController {
    static let environmentKey = "BALANCEBAR_DASHBOARD_ACCESSORY_HARNESS"
    static let titlebarStripIdentifier = "dashboard-accessory-harness-titlebar"
    static let contentStripIdentifier = "dashboard-accessory-harness-content"

    private var windowController: DashboardWindowController?
    private var pageSession: DashboardPageSession?

    static var isEnabled: Bool {
        isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            environment: ProcessInfo.processInfo.environment,
            isTestHost: AutomatedTestHost.isRunning
        )
    }

    static func isEnabled(
        bundleIdentifier: String,
        environment: [String: String],
        isTestHost: Bool
    ) -> Bool {
        guard !isTestHost else { return false }
        guard environment[environmentKey] == "1" else { return false }
        return bundleIdentifier == "com.huanmeng06.BalanceBar.dev"
            || bundleIdentifier.hasPrefix("com.huanmeng06.BalanceBar.dev.")
    }

    func presentIfRequested() -> Bool {
        guard Self.isEnabled else { return false }
        present()
        return true
    }

    func present() {
        if windowController == nil || pageSession == nil {
            assembleShell()
        }
        let isNewWindow = windowController?.window == nil
        windowController?.open(initialSection: .general)
        if isNewWindow, let windowController, let pageSession {
            pageSession.installShell(on: windowController)
            pageSession.showSection(.general)
        }
        windowController?.present()
    }

    func teardown() {
        pageSession?.teardown()
        windowController?.teardown()
        pageSession = nil
        windowController = nil
    }

    var window: NSWindow? { windowController?.window }
    var section: DashboardSection { pageSession?.section ?? .general }
    var windowControllerForTesting: DashboardWindowController? { windowController }
    var sourceListForTesting: DashboardSourceListController? {
        pageSession?.sourceListController
    }
    var accessoryHostForTesting: DashboardAccessoryHost {
        pageSession?.accessoryHost ?? DashboardAccessoryHost()
    }

    func showSection(_ section: DashboardSection) {
        pageSession?.showSection(section)
    }

    static func accessory(for section: DashboardSection) -> DashboardPageTopAccessory {
        switch section {
        case .menuBar:
            return .windowTitlebar(
                viewController: DashboardAccessoryHarnessStripController(
                    identifier: titlebarStripIdentifier,
                    color: .systemOrange
                ),
                reason: "manual harness window-level titlebar accessory"
            )
        case .menu:
            return .contentSplitItem(
                viewController: DashboardAccessoryHarnessStripController(
                    identifier: contentStripIdentifier,
                    color: .systemBlue
                )
            )
        case .general, .advanced, .about:
            return .none
        }
    }

    private func assembleShell() {
        pageSession = DashboardPageSession(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { section in
                    DashboardAccessoryHarnessPage(
                        accessory: Self.accessory(for: section)
                    )
                },
                makeProviderPage: { _ in
                    DashboardAccessoryHarnessPage(accessory: .none)
                },
                providerChoices: { [] },
                prepareForPageReplacement: {},
                didShowPage: {},
                didClose: {},
                didResize: {}
            )
        )
        windowController = DashboardWindowController()
    }
}

private final class DashboardAccessoryHarnessPage: NSViewController, DashboardPageTopAccessoryProviding {
    let dashboardPageTopAccessory: DashboardPageTopAccessory

    init(accessory: DashboardPageTopAccessory) {
        dashboardPageTopAccessory = accessory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
    }
}

private final class DashboardAccessoryHarnessStripController: NSViewController {
    init(identifier: String, color: NSColor, height: CGFloat = 28) {
        super.init(nibName: nil, bundle: nil)
        let strip = DashboardAccessoryHarnessStripView(height: height)
        strip.identifier = NSUserInterfaceItemIdentifier(identifier)
        strip.wantsLayer = true
        strip.layer?.backgroundColor = color.cgColor
        view = strip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class DashboardAccessoryHarnessStripView: NSView {
    private let stripHeight: CGFloat

    init(height: CGFloat) {
        stripHeight = height
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: stripHeight)
    }
}
