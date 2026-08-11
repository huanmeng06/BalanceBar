import AppKit
import Foundation

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

enum DashboardLogging {
    static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    static func rect(_ rect: NSRect) -> String {
        "x=\(number(rect.origin.x)),y=\(number(rect.origin.y)),w=\(number(rect.size.width)),h=\(number(rect.size.height))"
    }

    static func state(_ state: NSControl.StateValue) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .mixed: return "mixed"
        default: return "raw=\(state.rawValue)"
        }
    }
}

enum SwitchLog {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private static let queue = DispatchQueue(label: "local.balancebar.debug-log")
    // Keep at most about 1 MB on disk: one 512 KB active file and one rotated
    // predecessor. Diagnostic logs should never grow with the app's lifetime.
    private static let maximumSize = 512 * 1_024
    private static let viewerMaximumBytes: UInt64 = 160 * 1_024
    private static let viewerMaximumLines = 1_000
    private static var lastWriteDates: [String: Date] = [:]
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let fileURL = URL(fileURLWithPath: NSString(
        string: "~/Library/Logs/BalanceBar/debug.log"
    ).expandingTildeInPath)
    private static let previousFileURL = fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("debug.previous.log")

    static func write(
        _ message: String,
        level: Level = .info,
        category: String = "general",
        throttleKey: String? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        queue.async {
            let now = Date()
            if minimumInterval > 0 {
                let key = throttleKey ?? "\(level.rawValue)|\(category)|\(message)"
                if let previous = lastWriteDates[key],
                   now.timeIntervalSince(previous) < minimumInterval {
                    return
                }
                lastWriteDates[key] = now
                if lastWriteDates.count > 256 {
                    lastWriteDates = lastWriteDates.filter {
                        now.timeIntervalSince($0.value) < 3_600
                    }
                }
            }
            let line = "[\(timestampFormatter.string(from: now))] [\(level.rawValue)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                rotateIfNeeded(incomingBytes: data.count)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }
            } catch {
                NSLog("BalanceBar debug log error: %@", error.localizedDescription)
            }
        }
    }

    static func recentText() -> String? {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let handle = try? FileHandle(forReadingFrom: fileURL)
            else { return nil }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                let start = size > viewerMaximumBytes
                    ? size - viewerMaximumBytes
                    : 0
                try handle.seek(toOffset: start)
                guard let data = try handle.readToEnd(),
                      var text = String(data: data, encoding: .utf8)
                else { return nil }
                if start > 0, let newline = text.firstIndex(of: "\n") {
                    text.removeSubrange(...newline)
                }
                let lines = text.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                )
                if lines.count > viewerMaximumLines {
                    text = lines.suffix(viewerMaximumLines)
                        .joined(separator: "\n")
                }
                return text
            } catch {
                return nil
            }
        }
    }

    private static func rotateIfNeeded(incomingBytes: Int) {
        let size = (try? fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        guard size + incomingBytes > maximumSize else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
    }
}

private let productionBundleIdentifier = "com.huanmeng06.BalanceBar.app"
private let devBundleIdentifier = "com.huanmeng06.BalanceBar.dev"
private let legacyProductionBundleIdentifier = "com.huanmeng06.BalanceBar"
private let legacyBundleIdentifier = "local.balancebar"

struct PreferencesMigrationPlan {
    static let keys = ["appLanguage", "showMenuBarReset", "showMenuBarIcon", "showMenuBarAmount", "animateCodexActivity", "activityPollInterval", "codexUsageRefreshInterval", "postCodexRefreshDuration", "showQuickSwitchMenu", "showOpenChatGPTMenu", "showOpenCCSwitchMenu", "showStatusMenu", "statusLinks", "keepMenuOpenAfterRefresh", "sortProvidersAlphabetically", "menuBarHorizontalPadding", "openCodexDashboardPortOverride", "openCodexDashboardAutomaticDetection"]

    static func selectedValues(target: [String: Any], production: [String: Any], local: [String: Any]) -> [String: Any] {
        var selected: [String: Any] = [:]
        for key in keys where target[key] == nil { selected[key] = production[key] ?? local[key] }
        return selected
    }
}

private func migrateLegacyPreferencesIfNeeded() {
    let defaults = UserDefaults.standard
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    AppPreferencesMigration.migrate(
        defaults: defaults,
        bundleIdentifier: bundleIdentifier,
        productionDomain: defaults.persistentDomain(forName: legacyProductionBundleIdentifier) ?? [:],
        localDomain: defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
    )
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private var statusItemController: StatusItemController!
    private let dashboardProviderLabel = NSTextField(labelWithString: tr("正在读取…", "Loading…"))
    private let dashboardAmountLabel = NSTextField(labelWithString: "—")
    private let dashboardQuotaLabel = NSTextField(labelWithString: tr("等待额度信息", "Waiting for quota data"))
    private let dashboardResetLabel = NSTextField(labelWithString: "")
    private let dashboardRefreshLabel = NSTextField(labelWithString: "--:--:--")
    private let dashboardStatusLabel = NSTextField(labelWithString: tr("正在连接 CC Switch", "Connecting to CC Switch"))
    private let dashboardCurrentProviderSubtitle = NSTextField(wrappingLabelWithString: "")
    private let dashboardProvidersStack = NSStackView()
    private let dashboardProgressHost = NSView()
    private let dashboardContentHost = NSView()
    private let dashboardLogView = NSTextView()
    private let dashboardMenuPreviewIcon = PassthroughImageView()
    private let dashboardMenuPreviewIconSlot = NSView()
    private let dashboardMenuPreviewText = MenuBarTextView()
    private let dashboardMenuPreviewPrimary = NSTextField(labelWithString: "…")
    private let dashboardMenuPreviewSecondary = NSTextField(labelWithString: "")
    private let dashboardMenuPreviewCapsule = NSView()
    private weak var dashboardMenuBarIconSwitch: NSSwitch?
    private weak var dashboardMenuBarAmountSwitch: NSSwitch?
    private weak var openCodexAutomaticDetectionSwitch: NSSwitch?
    private weak var openCodexPortField: NSTextField?
    private weak var openCodexManualPortRow: NSView?
    private weak var openCodexManualPortRowHeightConstraint: NSLayoutConstraint?
    private weak var openCodexPortStatusLabel: NSTextField?
    private weak var openCodexPortErrorLabel: NSTextField?
    private weak var openCodexOpenButton: NSButton?
    private weak var openCodexSettingsRowsStack: NSStackView?
    private weak var openCodexSettingsCardHeightConstraint: NSLayoutConstraint?
    private var openCodexSettingsSeparators: [NSView] = []
    private var openCodexDashboardInteractionState = OpenCodexDashboardInteractionState(
        mode: OpenCodexDashboardMode(automaticDetection: true, manualPort: nil)
    )
    private var openCodexDashboardLastResolvedPort: Int {
        get { openCodexDashboardInteractionState.lastResolvedPort }
        set { openCodexDashboardInteractionState.updateResolvedPort(newValue) }
    }
    private var isEndingOpenCodexPortEditing = false
    private var dashboardMenuPreviewCapsuleLeadingConstraint: NSLayoutConstraint?
    private var dashboardMenuPreviewCapsuleTrailingConstraint: NSLayoutConstraint?
    private var dashboardMenuPreviewTextWidthConstraint: NSLayoutConstraint?
    private let dashboardMenuPreviewChromeInset: CGFloat = 10
    private let dashboardProviderSearch = NSSearchField()
    private let dashboardProviderList = NSStackView()
    private let dashboardProviderCountLabel = NSTextField(labelWithString: "")
    private let monitorQueue = DispatchQueue(label: "local.balancebar.monitor")
    private let activityMonitorQueue = DispatchQueue(
        label: "local.balancebar.activity-monitor",
        qos: .utility
    )
    private let codexActivityMonitor = CodexActivityMonitor()
    private let claudeActivityMonitor = ClaudeCodeActivityMonitor()
    private var dashboard: NSWindow?
    private var dashboardMouseMonitor: Any?
    private var dashboardNavigationButtons: [DashboardSection: NSButton] = [:]
    private var dashboardNavigationRows: [DashboardSection: DashboardNavigationRowView] = [:]
    private var dashboardProviderButtons: [String: NSButton] = [:]
    private var statusLinksEditorHostingView: StatusLinksEditorHostingView?
    private lazy var statusLinksScrollAnchorController = StatusLinksScrollAnchorController(
        dashboardProvider: { [weak self] in self?.dashboard },
        contentHostProvider: { [weak self] in self?.dashboardContentHost },
        sectionTitleProvider: { [weak self] in self?.dashboardSection.title ?? "" },
        linksCountProvider: { [weak self] in self?.statusLinks.count ?? 0 }
    )
    private var dashboardSection: DashboardSection = .general
    private var dashboardSelectedProviderID: String?
    private var timer: Timer?
    private var activityTimer: Timer?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var databaseWatchers: [DispatchSourceFileSystemObject] = []
    private var syncWorkItem: DispatchWorkItem?
    private var lastSuccessfulRefresh: Date?
    private var lastProviderID: String?
    private var lastBalanceFetch: Date?
    private var lastOfficialFetch: Date?
    private var lastQuickSwitchFetch: Date?
    private var lastOpenCodexFetch: Date?
    private let quickSwitchSummaryLock = NSLock()
    private var quickSwitchSummaries: [String: String] = [:]
    private var clientSnapshots: [
        AssistantClient: (providerID: String, snapshot: Snapshot)
    ] = [:]
    private var providerBalanceSnapshots = ProviderBalanceSnapshotCache()
    private var openCodexState: (providerID: String, state: OpenCodexRuntimeState)?
    private var openCodexCards: [OpenCodexModelCard] = []
    // OpenCodex card planning and data refresh run on monitorQueue. The array
    // above is published to the main queue because the status-menu view is a
    // UI object; these backing values never contain credentials.
    private var openCodexCardPlans: [OpenCodexCardPlan] = []
    private var openCodexCardData: [OpenCodexCardSource: OpenCodexCardData] = [:]
    private var openCodexCardRefreshCoordinator = OpenCodexCardRefreshCoordinator()
    private var openCodexCardRequestsInFlight: Set<OpenCodexCardSource> = []
    // These caches are owned by monitorQueue. They let a previously verified
    // OpenCodex remain special while its process is temporarily unavailable,
    // without treating an unverified loopback as OpenCodex.
    private var confirmedOpenCodexCandidates: [String: OpenCodexEndpointCandidate] = [:]
    private var confirmedOpenCodexStates: [String: OpenCodexRuntimeState] = [:]
    private var openCodexSwitchInFlight = false
    private var openCodexPortInputHasError = false
    private var snapshot = Snapshot.placeholder
    private var activeProviderWebsite: URL?
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
    private var isClaudeProcessAvailable = false
    private var isActivityCheckInFlight = false
    private var lastCodexUsageRefresh: Date?
    private var postCodexRefreshDeadline: Date?
    private let providerPollInterval: TimeInterval = 3
    private let ccSwitchRepository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let openCodexRepository: OpenCodexRepository
    private let balanceAPIClient = BalanceAPIClient()
    private let preferences = AppPreferences()
    private var showMenuBarReset: Bool { get { preferences.showMenuBarReset } set { preferences.showMenuBarReset = newValue } }
    private var showMenuBarIcon: Bool { get { preferences.showMenuBarIcon } set { preferences.showMenuBarIcon = newValue } }
    private var showMenuBarAmount: Bool { get { preferences.showMenuBarAmount } set { preferences.showMenuBarAmount = newValue } }
    private var animateCodexActivity: Bool { get { preferences.animateCodexActivity } set { preferences.animateCodexActivity = newValue } }
    private var activityPollInterval: TimeInterval { get { preferences.activityPollInterval } set { preferences.activityPollInterval = newValue } }
    private var codexUsageRefreshInterval: TimeInterval { get { preferences.codexUsageRefreshInterval } set { preferences.codexUsageRefreshInterval = newValue } }
    private var postCodexRefreshDuration: TimeInterval { get { preferences.postCodexRefreshDuration } set { preferences.postCodexRefreshDuration = newValue } }
    private var showQuickSwitchMenu: Bool { get { preferences.showQuickSwitchMenu } set { preferences.showQuickSwitchMenu = newValue } }
    private var showOpenCCSwitchMenu: Bool { get { preferences.showOpenCCSwitchMenu } set { preferences.showOpenCCSwitchMenu = newValue } }
    private var showOpenChatGPTMenu: Bool { get { preferences.showOpenChatGPTMenu } set { preferences.showOpenChatGPTMenu = newValue } }
    private var showStatusMenu: Bool { get { preferences.showStatusMenu } set { preferences.showStatusMenu = newValue } }
    private var statusLinks: [StatusLink] { get { preferences.statusLinks } set { preferences.statusLinks = newValue } }
    private var defaultStatusLinks: [StatusLink] { preferences.defaultStatusLinks }
    private var keepMenuOpenAfterRefresh: Bool { get { preferences.keepMenuOpenAfterRefresh } set { preferences.keepMenuOpenAfterRefresh = newValue } }
    private var sortProvidersAlphabetically: Bool { get { preferences.sortProvidersAlphabetically } set { preferences.sortProvidersAlphabetically = newValue } }
    private var menuBarHorizontalPadding: CGFloat { get { preferences.menuBarHorizontalPadding } set { preferences.menuBarHorizontalPadding = newValue } }
    private var openCodexDashboardPortOverride: Int? {
        get { preferences.openCodexDashboardPortOverride }
        set { preferences.openCodexDashboardPortOverride = newValue }
    }
    private var openCodexDashboardAutomaticDetection: Bool {
        get { preferences.openCodexDashboardAutomaticDetection }
        set { preferences.openCodexDashboardAutomaticDetection = newValue }
    }
    private var openCodexDashboardMode: OpenCodexDashboardMode {
        OpenCodexDashboardMode(
            automaticDetection: openCodexDashboardAutomaticDetection,
            manualPort: openCodexDashboardPortOverride
        )
    }

    init(
        repository: CCSwitchRepository = CCSwitchRepository(),
        officialQuotaClient: OfficialQuotaClient = OfficialQuotaClient(),
        openCodexRepository: OpenCodexRepository = OpenCodexRepository()
    ) {
        self.ccSwitchRepository = repository
        self.officialQuotaClient = officialQuotaClient
        self.openCodexRepository = openCodexRepository
        super.init()
        statusItemController = StatusItemController(
            actions: StatusItemController.Actions(
                manualRefresh: { [weak self] in
                    self?.performManualRefresh(source: "menu")
                },
                openDashboard: { [weak self] in
                    self?.openDashboard()
                },
                openChatGPT: { [weak self] in
                    self?.openChatGPT()
                },
                openCCSwitch: { [weak self] in
                    self?.openCCSwitch()
                },
                openOpenCodex: { [weak self] in
                    self?.openOpenCodex()
                },
                quit: { NSApp.terminate(nil) },
                switchProvider: { [weak self] providerID in
                    self?.switchProvider(providerID)
                },
                switchOpenCodexPreference: { [weak self] preference in
                    self?.performOpenCodexPreferenceSwitch(preference)
                },
                openProviderWebsite: { [weak self] in
                    self?.openProviderWebsite()
                },
                openStatusLink: { url in
                    NSWorkspace.shared.open(url)
                },
                iconChanged: { [weak self] image in
                    guard let self else { return }
                    self.dashboardMenuPreviewIcon.image = image
                    self.dashboardMenuPreviewIcon.contentTintColor = .labelColor
                }
            )
        )
    }

    private func makeStatusItemMenuInput() -> StatusItemController.MenuInput {
        StatusItemController.MenuInput(
            openCodexCards: openCodexCards,
            openCodexState: openCodexState?.state,
            openCodexSwitchInFlight: openCodexSwitchInFlight,
            choices: ccSwitchRepository.loadChoices(appType: activeClient.appType),
            quickSwitchSummaries: quickSwitchSummariesSnapshot(),
            activeClient: activeClient,
            statusLinks: statusLinks,
            showQuickSwitchMenu: showQuickSwitchMenu,
            showOpenChatGPTMenu: showOpenChatGPTMenu,
            showOpenCCSwitchMenu: showOpenCCSwitchMenu,
            showStatusMenu: showStatusMenu,
            currentOpenCodexDashboardAvailable: currentOpenCodexDashboardURL() != nil
        )
    }

    private func quickSwitchSummariesSnapshot() -> [String: String] {
        quickSwitchSummaryLock.lock()
        defer { quickSwitchSummaryLock.unlock() }
        return quickSwitchSummaries
    }

    private func makeStatusItemSettings() -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: showMenuBarIcon,
            showAmount: showMenuBarAmount,
            showReset: showMenuBarReset,
            horizontalPadding: menuBarHorizontalPadding,
            keepMenuOpenAfterRefresh: keepMenuOpenAfterRefresh
        )
    }

    private func updateStatusItemActivity() {
        statusItemController.updateActivity(
            activeClient: activeClient,
            codexTaskRunning: isCodexTaskRunning,
            claudeTaskRunning: isClaudeTaskRunning,
            animationEnabled: animateCodexActivity
        )
    }

    private func updateStatusItem(for snapshot: Snapshot) {
        statusItemController.update(
            snapshot: snapshot,
            refreshDate: refreshDate(for: snapshot),
            menuInput: makeStatusItemMenuInput(),
            settings: makeStatusItemSettings()
        )
        refreshDashboardMenuBarPage()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "BalanceBar", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        configureApplicationMenu()
        NSApp.appearance = nil
        startAppearanceObserver()
        let regularPolicyApplied = NSApp.setActivationPolicy(.regular)
        showDashboard()
        statusItemController.start(
            snapshot: snapshot,
            refreshDate: refreshDate(for: snapshot),
            menuInput: makeStatusItemMenuInput(),
            settings: makeStatusItemSettings()
        )
        updateStatusItemActivity()
        startDatabaseWatchers()
        startWorkspaceActivationObserver()
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        SwitchLog.write(
            "session started; version=\(version); os=\(ProcessInfo.processInfo.operatingSystemVersionString); database=\(ccSwitchRepository.databaseURL.path)",
            category: "lifecycle"
        )
        SwitchLog.write(
            "status chain startup; activation_policy=\(String(describing: NSApp.activationPolicy())); regular_applied=\(regularPolicyApplied); \(statusItemController.startupDiagnostic)",
            category: "ui.status-item"
        )
        SwitchLog.write(
            "preferences; language=\(AppLanguage.selected.rawValue); provider_poll=\(providerPollInterval)s; activity_poll=\(activityPollInterval)s; active_refresh=\(codexUsageRefreshInterval)s; trailing_refresh=\(postCodexRefreshDuration)s",
            level: .debug,
            category: "configuration"
        )
        SwitchLog.write(
            "database watchers started; count=\(databaseWatchers.count)",
            category: "database"
        )
        refresh(reason: .initial)
        refreshQuickSwitchSummaries(force: true)
        refreshQuickSwitchSummaries(force: true, for: .claude)
        prefetchCurrentBalance(for: .claude)
        refreshCodexActivity()
        // The file watcher handles normal CC Switch writes. This inexpensive
        // read is a fallback for a missed filesystem notification.
        configureRefreshTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwitchLog.write("session terminating", category: "lifecycle")
        timer?.invalidate()
        activityTimer?.invalidate()
        statusLinksScrollAnchorController.stop()
        statusLinksEditorHostingView?.teardown()
        statusItemController.teardown()
        if let dashboardMouseMonitor {
            NSEvent.removeMonitor(dashboardMouseMonitor)
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        databaseWatchers.forEach { $0.cancel() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDashboard() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        statusLinksScrollAnchorController.stop()
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            SwitchLog.write(
                "dashboard closed; activation_policy=\(String(describing: NSApp.activationPolicy())); status_visible=\(self.statusItemController.isVisible)",
                category: "ui.status-item"
            )
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        DispatchQueue.main.async { [weak self] in
            self?.clampDashboardScrollViewBounds()
        }
    }

    @objc private func dashboardManualRefresh() {
        performManualRefresh(source: "dashboard")
    }

    private func performManualRefresh(source: String) {
        SwitchLog.write(
            "manual refresh requested; source=\(source); client=\(activeClient.rawValue)",
            category: "refresh"
        )
        refresh(reason: .manual)
        refreshQuickSwitchSummaries(force: true)
    }

    private func switchProvider(_ providerID: String) {
        let appType = activeClient.appType
        // The menu-bar controller passes the stable Provider ID. Keep the
        // actual Provider name separate for logs and CC Switch synchronization.
        let providerName = ccSwitchRepository.loadChoices(appType: appType)
            .first(where: { $0.id == providerID })?.name ?? providerID
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let current = ccSwitchRepository.loadChoices(appType: appType)
                .first(where: { $0.isCurrent })
            SwitchLog.write("switch requested; from=\(current?.name ?? "none"); to=\(providerName); id=\(providerID)")
            if current?.id == providerID {
                SwitchLog.write("switch skipped; target is already current")
                return
            }

            let ccSwitch = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.ccswitch.desktop"
            ).first
            let ccSwitchURL = ccSwitch?.bundleURL ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.ccswitch.desktop"
            )
            if let ccSwitch {
                SwitchLog.write("CC Switch graceful stop requested; pid=\(ccSwitch.processIdentifier)")
                ccSwitch.terminate()
                let deadline = Date().addingTimeInterval(4)
                while !ccSwitch.isTerminated && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard ccSwitch.isTerminated else {
                    SwitchLog.write("switch failed; CC Switch did not terminate within 4s")
                    self.render(.error(tr(
                        "切换失败：CC Switch 未能正常重载",
                        "Switch failed: CC Switch could not reload normally"
                    )))
                    return
                }
                SwitchLog.write("CC Switch stopped cleanly")
            } else {
                SwitchLog.write("CC Switch was not running; switching live configuration directly")
            }

            do {
                try ccSwitchRepository.switchCurrent(to: providerID, appType: appType)
                let confirmed = ccSwitchRepository.loadChoices(appType: appType)
                    .first(where: { $0.isCurrent })
                guard confirmed?.id == providerID else {
                    throw NSError(
                        domain: "BalanceBar.SwitchValidation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: tr("数据库校验未通过", "Database verification failed")]
                    )
                }
                SwitchLog.write("database and \(appType) live config updated; current=\(confirmed?.name ?? providerName)")

                if ccSwitch != nil, let ccSwitchURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        configuration.addsToRecentItems = false
                        NSWorkspace.shared.openApplication(at: ccSwitchURL, configuration: configuration) { _, error in
                            if let error {
                                SwitchLog.write("CC Switch background reopen failed; error=\(error.localizedDescription)")
                            } else {
                                SwitchLog.write("CC Switch reopened hidden; target=\(providerName)")
                            }
                        }
                    }
                }
                self.lastProviderID = nil
                self.lastBalanceFetch = nil
                self.lastOfficialFetch = nil
                self.lastOpenCodexFetch = nil
                self.resetOpenCodexCards()
                DispatchQueue.main.async { [weak self] in
                    self?.openCodexState = nil
                    self?.openCodexCards = []
                    self?.openCodexSwitchInFlight = false
                }
                self.refresh(reason: .providerChanged)
            } catch {
                SwitchLog.write("switch failed; target=\(providerName); error=\(error.localizedDescription)")
                if ccSwitch != nil, let ccSwitchURL {
                    DispatchQueue.main.async {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        configuration.hides = true
                        NSWorkspace.shared.openApplication(at: ccSwitchURL, configuration: configuration) { _, _ in }
                    }
                }
                self.render(.error(tr(
                    "切换失败：\(error.localizedDescription)",
                    "Switch failed: \(error.localizedDescription)"
                )))
            }
        }
    }

    private func performOpenCodexPreferenceSwitch(_ preference: OpenCodexPreference) {
        guard activeClient == .codex,
              !openCodexSwitchInFlight,
              let entry = openCodexState,
              let current = ccSwitchRepository.loadCurrent(appType: activeClient.appType),
              current.id == entry.providerID,
              current.openCodexCandidate != nil else { return }

        openCodexSwitchInFlight = true
        let providerID = entry.providerID
        let providerName = current.name
        let oldState = entry.state
        monitorQueue.async { [weak self] in
            guard let self else { return }
            self.openCodexRepository.select(preference, from: oldState) { [weak self] result in
                guard let self else { return }
                self.monitorQueue.async {
                    guard self.activeClient == .codex,
                          self.ccSwitchRepository.loadCurrent(appType: AssistantClient.codex.appType)?.id == providerID else {
                        DispatchQueue.main.async { [weak self] in
                            self?.openCodexSwitchInFlight = false
                        }
                        return
                    }
                    switch result {
                    case .success(let state):
                        self.confirmedOpenCodexCandidates[providerID] = state.candidate
                        self.confirmedOpenCodexStates[providerID] = state
                        DispatchQueue.main.async { [weak self] in
                            self?.openCodexState = (providerID, state)
                            self?.openCodexSwitchInFlight = false
                        }
                        self.prepareOpenCodexCards(
                            providerID: providerID,
                            state: state
                        )
                        self.renderForCurrentProvider(
                            .openCodex(
                                providerName,
                                selector: state.currentSelector,
                                status: self.openCodexStatusText(for: state),
                                Date()
                            ),
                            providerID: providerID,
                            client: .codex
                        )
                    case .failure(let error):
                        DispatchQueue.main.async { [weak self] in
                            self?.openCodexSwitchInFlight = false
                        }
                        self.renderForCurrentProvider(
                            .openCodex(
                                providerName,
                                selector: oldState.currentSelector,
                                status: tr(
                                    "切换失败：\(error.simplifiedChineseMessage)",
                                    "Switch failed: \(error.englishMessage)"
                                ),
                                Date()
                            ),
                            providerID: providerID,
                            client: .codex
                        )
                    }
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func dashboardLanguageChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyLanguage(language)
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        SwitchLog.write(
            "language changed; value=\(language.rawValue)",
            category: "configuration"
        )
        AppLanguage.selected = language
        configureApplicationMenu()
        rebuildDashboardForLanguageChange()
        render(snapshot)
        refresh(reason: .configurationChanged)
        refreshQuickSwitchSummaries(force: true)
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu(title: "BalanceBar")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "BalanceBar")
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: tr("关于 BalanceBar", "About BalanceBar"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: tr("隐藏 BalanceBar", "Hide BalanceBar"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = applicationMenu.addItem(
            withTitle: tr("隐藏其他应用", "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(
            withTitle: tr("全部显示", "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(
            withTitle: tr("退出 BalanceBar", "Quit BalanceBar"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("编辑", "Edit"))
        editItem.submenu = editMenu
        editMenu.autoenablesItems = true
        editMenu.addItem(
            withTitle: tr("撤销", "Undo"),
            action: #selector(UndoManager.undo),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: tr("重做", "Redo"),
            action: #selector(UndoManager.redo),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: tr("剪切", "Cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: tr("拷贝", "Copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: tr("粘贴", "Paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: tr("全选", "Select All"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr("窗口", "Window"))
        windowItem.submenu = windowMenu
        let closeItem = windowMenu.addItem(
            withTitle: tr("关闭窗口", "Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = nil
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
    @objc private func openCCSwitch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ccswitch.desktop") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    @objc private func openOpenCodex() {
        guard let resolution = currentOpenCodexDashboardResolution() else { return }
        SwitchLog.write(
            "OpenCodex Dashboard launch requested; source=\(String(describing: resolution.source)); port=\(resolution.port); path=\(resolution.url.path); fragment=\(resolution.url.fragment ?? "none")",
            category: "open-codex.dashboard"
        )
        NSWorkspace.shared.open(resolution.url)
    }

    private func currentOpenCodexDashboardURL() -> URL? {
        currentOpenCodexDashboardResolution()?.url
    }

    private func currentOpenCodexDashboardResolution() -> OpenCodexDashboardResolution? {
        guard activeClient == .codex,
              let current = ccSwitchRepository.loadCurrent(appType: activeClient.appType) else {
            return nil
        }
        let runtimeCandidate: OpenCodexEndpointCandidate?
        if let entry = openCodexState, entry.providerID == current.id {
            runtimeCandidate = entry.state.candidate
        } else {
            runtimeCandidate = nil
        }
        guard current.openCodexCandidate != nil || runtimeCandidate != nil else { return nil }
        return OpenCodexDashboardResolver.resolve(
            manualPort: openCodexDashboardMode.effectiveManualPort,
            runtimeCandidate: runtimeCandidate
        )
    }

    @objc private func openChatGPT() {
        let applicationURLs: [URL] = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT Classic.app")
        ].compactMap { $0 }
        guard let url = applicationURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            SwitchLog.write(
                "open ChatGPT failed; reason=application-not-found",
                level: .warning,
                category: "ui.menu"
            )
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                SwitchLog.write(
                    "open ChatGPT failed; path=\(url.path); error=\(error.localizedDescription)",
                    level: .warning,
                    category: "ui.menu"
                )
            } else {
                SwitchLog.write(
                    "ChatGPT opened; path=\(url.path)",
                    category: "ui.menu"
                )
            }
        }
    }

    @objc private func openProviderWebsite() {
        guard let activeProviderWebsite else { return }
        NSWorkspace.shared.open(activeProviderWebsite)
    }

    private func openStatusLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @objc private func selectDashboardSection(_ sender: NSButton) {
        guard let section = DashboardSection(rawValue: sender.tag) else { return }
        showDashboardSection(section)
    }

    private func makeDashboardSwitch(identifier: String, isOn: Bool) -> NSSwitch {
        let control = NSSwitch()
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.state = isOn ? .on : .off
        control.target = self
        control.action = #selector(dashboardToggleChanged(_:))
        return control
    }

    @objc private func dashboardToggleChanged(_ sender: NSSwitch) {
        SwitchLog.write(
            "preference changed; key=\(sender.identifier?.rawValue ?? "unknown"); enabled=\(sender.state == .on)",
            category: "configuration"
        )
        switch sender.identifier?.rawValue {
        case "showMenuBarIcon":
            if sender.state == .off && !showMenuBarAmount {
                sender.state = .on
            }
            showMenuBarIcon = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarAmount":
            if sender.state == .off && !showMenuBarIcon {
                sender.state = .on
            }
            showMenuBarAmount = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarReset":
            showMenuBarReset = sender.state == .on
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showQuickSwitchMenu":
            showQuickSwitchMenu = sender.state == .on
            render(snapshot)
        case "showOpenCCSwitchMenu":
            showOpenCCSwitchMenu = sender.state == .on
            render(snapshot)
        case "showOpenChatGPTMenu":
            showOpenChatGPTMenu = sender.state == .on
            render(snapshot)
        case "showStatusMenu":
            showStatusMenu = sender.state == .on
            render(snapshot)
            if dashboardSection == .menu {
                // Let NSSwitch finish its native transition before replacing
                // the page. Rebuilding synchronously makes the control look
                // like it jumps instead of sliding smoothly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, self.dashboardSection == .menu else { return }
                    self.showDashboardSection(.menu)
                }
            }
        case "keepMenuOpenAfterRefresh":
            keepMenuOpenAfterRefresh = sender.state == .on
        case "animateCodexActivity":
            animateCodexActivity = sender.state == .on
            setCodexTaskRunning(isCodexTaskRunning, force: true)
        case "openCodexAutomaticDetection":
            let enabled = sender.state == .on
            // End the native field editor before hiding its row. In particular,
            // do not let an invalid in-progress edit re-enter the preference
            // path while the switch is being applied.
            endOpenCodexPortEditingForModeSwitch()
            setOpenCodexDashboardAutomaticDetection(enabled)
            openCodexPortInputHasError = false
            openCodexPortErrorLabel?.stringValue = ""
            openCodexPortErrorLabel?.isHidden = true
            openCodexManualPortRowHeightConstraint?.constant = 86
            updateOpenCodexDashboardModeUI()
            SwitchLog.write(
                "OpenCodex Dashboard detection mode changed; mode=\(enabled ? "automatic" : "manual")",
                category: "configuration"
            )
        default:
            break
        }
    }

    private func setOpenCodexDashboardAutomaticDetection(_ enabled: Bool) {
        openCodexDashboardInteractionState.mode = openCodexDashboardMode
        openCodexDashboardInteractionState.updateResolvedPort(openCodexDashboardLastResolvedPort)
        openCodexDashboardInteractionState.setAutomaticDetection(enabled)
        let nextMode = openCodexDashboardInteractionState.mode
        openCodexDashboardAutomaticDetection = nextMode.automaticDetection
        openCodexDashboardPortOverride = nextMode.manualPort
    }

    private func endOpenCodexPortEditingForModeSwitch() {
        guard let field = openCodexPortField,
              field.currentEditor() != nil else { return }
        openCodexDashboardInteractionState.markPortEditorActive(true)
        isEndingOpenCodexPortEditing = true
        _ = field.abortEditing()
        _ = dashboard?.makeFirstResponder(nil)
        isEndingOpenCodexPortEditing = false
        openCodexDashboardInteractionState.markPortEditorActive(false)
    }

    private func updateOpenCodexDashboardModeUI() {
        guard dashboard?.isVisible == true, dashboardSection == .advanced else { return }

        let mode = openCodexDashboardMode
        openCodexAutomaticDetectionSwitch?.state = mode.automaticDetection ? .on : .off
        openCodexManualPortRow?.isHidden = !mode.showsManualPortInput
        if openCodexSettingsSeparators.count >= 2 {
            // When the manual row is hidden, keep only the separator between
            // the automatic row and the independent open action.
            openCodexSettingsSeparators[0].isHidden = !mode.showsManualPortInput
            openCodexSettingsSeparators[1].isHidden = false
        }

        let resolution = OpenCodexDashboardResolver.resolve(
            manualPort: mode.effectiveManualPort,
            runtimeCandidate: openCodexState?.state.candidate
        )
        applyOpenCodexDashboardResolution(resolution, canOpen: nil)
        updateOpenCodexDashboardCardLayout()
    }

    private func updateOpenCodexDashboardCardLayout() {
        guard let rowsStack = openCodexSettingsRowsStack,
              let cardHeightConstraint = openCodexSettingsCardHeightConstraint else { return }

        rowsStack.layoutSubtreeIfNeeded()
        let visibleRows = rowsStack.arrangedSubviews.filter {
            !($0 is NSBox) && !$0.isHidden
        }
        let rowsHeight = visibleRows.reduce(CGFloat(0)) { partial, row in
            let explicitHeight = row.constraints.first {
                ($0.firstItem as? NSView) === row &&
                    $0.firstAttribute == .height &&
                    $0.relation == .equal
            }?.constant
            return partial + max(1, explicitHeight ?? row.fittingSize.height)
        }
        let separatorHeight = openCodexSettingsSeparators
            .filter { !$0.isHidden }
            .reduce(CGFloat(0)) { partial, separator in
                partial + max(1, separator.fittingSize.height)
            }
        cardHeightConstraint.constant = ceil(rowsHeight + separatorHeight)
        dashboardContentHost.layoutSubtreeIfNeeded()
        clampDashboardScrollViewBounds()
    }

    private func applyOpenCodexDashboardResolution(
        _ resolution: OpenCodexDashboardResolution,
        canOpen: Bool?
    ) {
        openCodexDashboardInteractionState.mode = openCodexDashboardMode
        openCodexDashboardLastResolvedPort = resolution.port
        let isEditing = openCodexPortField?.currentEditor() != nil
        if !isEditing, !openCodexPortInputHasError {
            openCodexPortField?.stringValue = String(
                openCodexDashboardMode.manualPort ?? resolution.port
            )
        }
        if let canOpen {
            openCodexOpenButton?.isEnabled = canOpen
        }

        let currentPort = tr(
            "当前端口：\(resolution.port)",
            "Current port: \(resolution.port)"
        )
        switch resolution.source {
        case .manual:
            openCodexPortStatusLabel?.stringValue = tr(
                "\(currentPort)\n手动端口只用于打开本机 Dashboard；不会修改 OpenCodex 配置",
                "\(currentPort)\nThe manual port only opens the local Dashboard; it does not modify OpenCodex configuration"
            )
        case .runtime:
            openCodexPortStatusLabel?.stringValue = tr(
                "\(currentPort)\n已自动检测 OpenCodex runtime 端口",
                "\(currentPort)\nOpenCodex runtime port detected automatically"
            )
        case .fallback:
            openCodexPortStatusLabel?.stringValue = tr(
                "\(currentPort)\n尚未自动检测；将使用默认端口 10100",
                "\(currentPort)\nNot detected yet; the default port 10100 will be used"
            )
        }
    }

    @objc private func openCodexDashboardPortChanged(_ sender: NSTextField) {
        guard !isEndingOpenCodexPortEditing else { return }
        switch OpenCodexDashboardPortInput.parse(sender.stringValue) {
        case .success(let port):
            openCodexPortInputHasError = false
            openCodexPortErrorLabel?.isHidden = true
            openCodexManualPortRowHeightConstraint?.constant = 86
            openCodexDashboardPortOverride = port
            openCodexDashboardAutomaticDetection = port == nil
            openCodexAutomaticDetectionSwitch?.state = port == nil ? .on : .off
            openCodexPortErrorLabel?.stringValue = ""
            SwitchLog.write(
                "OpenCodex Dashboard port preference changed; mode=\(port == nil ? "automatic" : "manual")",
                category: "configuration"
            )
            updateOpenCodexDashboardModeUI()
        case .failure:
            openCodexPortInputHasError = true
            openCodexPortErrorLabel?.isHidden = false
            openCodexPortErrorLabel?.stringValue = tr(
                "请输入 1 到 65535 的十进制端口；空值恢复自动检测",
                "Enter a decimal port from 1 to 65535; clear the field to restore automatic detection"
            )
            openCodexManualPortRowHeightConstraint?.constant = 112
            updateOpenCodexDashboardCardLayout()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === openCodexPortField,
              !isEndingOpenCodexPortEditing else { return }
        openCodexDashboardPortChanged(field)
    }

    private func refreshDashboardOpenCodexSettings() {
        guard dashboard?.isVisible == true, dashboardSection == .advanced else { return }

        let currentResolution = currentOpenCodexDashboardResolution()
        let resolution = currentResolution ?? OpenCodexDashboardResolver.resolve(
            manualPort: openCodexDashboardMode.effectiveManualPort,
            runtimeCandidate: nil
        )
        let canOpen = currentResolution != nil
        applyOpenCodexDashboardResolution(resolution, canOpen: canOpen)
        let showsManualPortInput = openCodexDashboardMode.showsManualPortInput
        openCodexAutomaticDetectionSwitch?.state = showsManualPortInput ? .off : .on
        openCodexManualPortRow?.isHidden = !showsManualPortInput
        if openCodexSettingsSeparators.count >= 2 {
            openCodexSettingsSeparators[0].isHidden = !showsManualPortInput
            openCodexSettingsSeparators[1].isHidden = false
        }
        updateOpenCodexDashboardCardLayout()
    }

    private func dashboardStatusLinkChanged(
        index: Int,
        field: StatusLinkField,
        value: String
    ) {
        guard index >= 0, index < statusLinks.count else { return }
        var links = statusLinks
        switch field {
        case .title:
            links[index].title = value
        case .url:
            links[index].url = value
        }
        statusLinks = links
        SwitchLog.write(
            "status link edited; index=\(index); field=\(field == .title ? "title" : "url"); length=\(value.count)",
            category: "configuration"
        )
        // Do not rebuild the dashboard while a native SwiftUI TextField is
        // editing. The binding already contains the new value; rebuilding
        // here would discard focus, selection, and the insertion point.
        statusItemController.updateMenu(input: makeStatusItemMenuInput())
    }

    private func addStatusLink() {
        let operation = "add"
        SwitchLog.write(
            "status-link button clicked; action=add; page=\(dashboardSection.title)",
            category: "ui.button"
        )
        statusLinksScrollAnchorController.logEditorGeometry(label: "before add")
        let scrollPosition = statusLinksScrollAnchorController.capture(
            captureLabel: "before add",
            operation: operation
        )
        var links = statusLinks
        links.append(StatusLink(title: "", url: ""))
        statusLinks = links
        SwitchLog.write(
            "status link model updated; action=add; count=\(links.count); page=\(dashboardSection.title)",
            category: "ui.layout"
        )
        SwitchLog.write("status link added; count=\(links.count)", category: "configuration")
        render(snapshot)
        if dashboardSection == .menu {
            if !statusLinksScrollAnchorController.refreshEditorInPlace(
                links: statusLinks,
                scrollPosition: scrollPosition,
                operation: operation
            ) {
                SwitchLog.write(
                    "status-link editor unavailable; action=add; fallback=page-rebuild; page=\(dashboardSection.title)",
                    level: .warning,
                    category: "ui.scroll"
                )
                showDashboardSection(.menu, restoringScrollPosition: scrollPosition)
            }
        } else {
            SwitchLog.write(
                "status-link button action ignored outside menu page; action=add; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.button"
            )
        }
    }

    private func removeStatusLink(at index: Int) {
        let operation = "remove"
        SwitchLog.write(
            "status-link button clicked; action=remove; page=\(dashboardSection.title); index=\(index)",
            category: "ui.button"
        )
        statusLinksScrollAnchorController.logEditorGeometry(label: "before remove")
        let scrollPosition = statusLinksScrollAnchorController.capture(
            captureLabel: "before remove",
            operation: operation
        )
        var links = statusLinks
        guard index >= 0, index < links.count else {
            SwitchLog.write(
                "status-link remove rejected; index=\(index); count=\(links.count)",
                level: .warning,
                category: "ui.button"
            )
            return
        }
        links.remove(at: index)
        statusLinks = links
        SwitchLog.write(
            "status link model updated; action=remove; index=\(index); count=\(links.count); page=\(dashboardSection.title)",
            category: "ui.layout"
        )
        SwitchLog.write("status link removed; index=\(index); count=\(links.count)", category: "configuration")
        render(snapshot)
        if dashboardSection == .menu {
            if !statusLinksScrollAnchorController.refreshEditorInPlace(
                links: statusLinks,
                scrollPosition: scrollPosition,
                operation: operation
            ) {
                SwitchLog.write(
                    "status-link editor unavailable; action=remove; fallback=page-rebuild; page=\(dashboardSection.title)",
                    level: .warning,
                    category: "ui.scroll"
                )
                showDashboardSection(.menu, restoringScrollPosition: scrollPosition)
            }
        } else {
            SwitchLog.write(
                "status-link button action ignored outside menu page; action=remove; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.button"
            )
        }
    }

    private func resetStatusLinks() {
        let operation = "reset"
        SwitchLog.write(
            "status-link button clicked; action=reset; page=\(dashboardSection.title)",
            category: "ui.button"
        )
        guard dashboardSection == .menu else {
            SwitchLog.write(
                "status-link reset ignored outside menu page; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.button"
            )
            return
        }

        statusLinksScrollAnchorController.logEditorGeometry(label: "before reset")
        let scrollPosition = statusLinksScrollAnchorController.capture(
            captureLabel: "before reset",
            operation: operation
        )
        statusLinks = defaultStatusLinks
        SwitchLog.write(
            "status link model reset; action=reset; count=\(defaultStatusLinks.count); page=\(dashboardSection.title)",
            category: "ui.layout"
        )
        SwitchLog.write(
            "status links restored to defaults; count=\(defaultStatusLinks.count)",
            category: "configuration"
        )
        render(snapshot)
        if !statusLinksScrollAnchorController.refreshEditorInPlace(
            links: statusLinks,
            scrollPosition: scrollPosition,
            operation: operation
        ) {
            SwitchLog.write(
                "status-link reset editor unavailable; fallback=page-rebuild; page=\(dashboardSection.title)",
                level: .warning,
                category: "ui.scroll"
            )
            showDashboardSection(.menu, restoringScrollPosition: scrollPosition)
        }
    }

    @objc private func dashboardIntervalChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? NSNumber else { return }
        SwitchLog.write(
            "interval changed; key=\(sender.identifier?.rawValue ?? "unknown"); value=\(value.doubleValue)s",
            category: "configuration"
        )
        var refreshTimers = false
        switch sender.identifier?.rawValue {
        case "activityPollInterval":
            activityPollInterval = value.doubleValue
            refreshTimers = true
        case "codexUsageRefreshInterval":
            codexUsageRefreshInterval = value.doubleValue
        case "postCodexRefreshDuration":
            postCodexRefreshDuration = value.doubleValue
            if !isCodexTaskRunning, postCodexRefreshDeadline != nil {
                postCodexRefreshDeadline = value.doubleValue > 0
                    ? Date().addingTimeInterval(value.doubleValue)
                    : nil
            }
        default: return
        }
        if refreshTimers {
            configureRefreshTimers()
        }
    }

    @objc private func dashboardMenuBarPaddingChanged(_ sender: NSSlider) {
        menuBarHorizontalPadding = CGFloat(sender.doubleValue)
        updateStatusItem(for: snapshot)
    }

    @objc private func dashboardSwitchProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        switchProvider(providerID)
    }

    @objc private func dashboardProviderSearchChanged(_ sender: NSSearchField) {
        rebuildDashboardProviderList()
    }

    @objc private func dashboardSortProviders(_ sender: NSButton) {
        sortProvidersAlphabetically.toggle()
        sender.contentTintColor = sortProvidersAlphabetically ? .controlAccentColor : .secondaryLabelColor
        rebuildDashboardProviderList()
    }

    @objc private func dashboardSelectProvider(_ sender: NSButton) {
        guard let providerID = sender.identifier?.rawValue else { return }
        showDashboardProvider(providerID)
    }

    @objc private func refreshDashboardLog() {
        let text = SwitchLog.recentText() ?? tr("暂无日志", "No logs yet")
        dashboardLogView.textStorage?.setAttributedString(
            styledDashboardLog(text)
        )
        resizeDashboardLogDocument()
        DispatchQueue.main.async { [weak self] in
            self?.resizeDashboardLogDocument()
        }
        dashboardLogView.scrollToEndOfDocument(nil)
    }

    private func resizeDashboardLogDocument() {
        guard let textContainer = dashboardLogView.textContainer,
              let layoutManager = dashboardLogView.layoutManager
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let viewport = dashboardLogView.enclosingScrollView?.contentSize
            ?? .zero
        let inset = dashboardLogView.textContainerInset
        dashboardLogView.setFrameSize(NSSize(
            width: max(
                viewport.width,
                ceil(used.width + (inset.width * 2) + 12)
            ),
            height: max(
                viewport.height,
                ceil(used.height + (inset.height * 2))
            )
        ))
    }

    private func vscodeColor(_ hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / CGFloat(255)
        let green = CGFloat((hex >> 8) & 0xFF) / CGFloat(255)
        let blue = CGFloat(hex & 0xFF) / CGFloat(255)
        return NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }

    private func styledDashboardLog(_ text: String) -> NSAttributedString {
        let foreground = vscodeColor(0xD4D4D4)
        let timestamp = vscodeColor(0x9DA5B4)
        let debug = vscodeColor(0xDCDCAA)
        let info = vscodeColor(0x23D18B)
        let warning = vscodeColor(0xF9F1A5)
        let error = vscodeColor(0xF14C4C)
        let number = vscodeColor(0x4FC1FF)
        let baseFont = NSFont.monospacedSystemFont(
            ofSize: 10.5,
            weight: .regular
        )
        let emphasizedFont = NSFont.monospacedSystemFont(
            ofSize: 10.5,
            weight: .semibold
        )
        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: foreground
            ]
        )
        let fullRange = NSRange(location: 0, length: output.length)

        func colorMatches(
            _ pattern: String,
            color: NSColor,
            emphasized: Bool = false
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern)
            else { return }
            expression.enumerateMatches(
                in: text,
                range: fullRange
            ) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound
                else { return }
                output.addAttributes([
                    .foregroundColor: color,
                    .font: emphasized ? emphasizedFont : baseFont
                ], range: range)
            }
        }

        // Highlight semantic values, not every run of digits. This avoids
        // fragmenting versions, UUIDs and mixed build identifiers into many
        // unrelated blue patches.
        colorMatches(#"(?<=[\$¥])-?\d+(?:\.\d+)?"#, color: number)
        colorMatches(#"(?<![\w.])-?\d+(?:\.\d+)?(?=%)"#, color: number)
        colorMatches(
            #"(?<==)-?\d+(?:\.\d+)?(?=(?:%|ms|s|m|h|d)?(?:[;,\s\)]|$))"#,
            color: number
        )
        colorMatches(#"(?m)^\[[^\]\n]+\]"#, color: timestamp)
        colorMatches(#"\[DEBUG\]"#, color: debug, emphasized: true)
        colorMatches(#"\[INFO\]"#, color: info, emphasized: true)
        colorMatches(#"\[WARN\]"#, color: warning, emphasized: true)
        colorMatches(#"\[ERROR\]"#, color: error, emphasized: true)

        if let categoryExpression = try? NSRegularExpression(
            pattern: #"(?m)^\[[^\]\n]+\] \[(?:DEBUG|INFO|WARN|ERROR)\] (\[[^\]\n]+\])"#
        ) {
            categoryExpression.enumerateMatches(
                in: text,
                range: fullRange
            ) { match, _, _ in
                guard let range = match?.range(at: 1),
                      range.location != NSNotFound
                else { return }
                output.addAttribute(
                    .foregroundColor,
                    value: foreground,
                    range: range
                )
            }
        }
        return output
    }

    @objc private func revealDashboardLog() {
        NSWorkspace.shared.activateFileViewerSelecting([SwitchLog.fileURL])
    }

    @objc private func openDashboard() {
        NSApp.setActivationPolicy(.regular)
        if let dashboard {
            dashboard.makeKeyAndOrderFront(nil)
            updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showDashboard()
    }

    private func startAppearanceObserver() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Let AppKit publish the new effective appearance before resolving
            // the small number of CALayer-backed adaptive colors.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dashboard?.appearance = nil
                self.rebuildDashboardForAppearanceChange()
            }
        }
    }

    private func rebuildDashboardForAppearanceChange() {
        guard let window = dashboard else { return }
        let selectedSection = dashboardSection
        let selectedProviderID = dashboardSelectedProviderID
        installDashboardLayout(in: window)
        if let selectedProviderID,
           ccSwitchRepository.loadChoices(appType: activeClient.appType)
               .contains(where: { $0.id == selectedProviderID }) {
            showDashboardProvider(selectedProviderID)
        } else {
            showDashboardSection(selectedSection)
        }
        window.displayIfNeeded()
    }

    private func showDashboard() {
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
        installDashboardLayout(in: window)
        dashboard = window
        installDashboardMouseMonitor()
        showDashboardSection(.general)
        window.makeKeyAndOrderFront(nil)
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installDashboardMouseMonitor() {
        guard dashboardMouseMonitor == nil else { return }
        dashboardMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            self?.finishDashboardEditingIfClickIsOutsideInput(event)
            return event
        }
    }

    private func finishDashboardEditingIfClickIsOutsideInput(_ event: NSEvent) {
        guard let dashboard,
              event.window === dashboard,
              let hitView = dashboard.contentView?.hitTest(event.locationInWindow)
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
        guard dashboard.firstResponder != nil else { return }
        dashboard.makeFirstResponder(nil)
    }

    private func installDashboardLayout(in window: NSWindow) {
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

        dashboardContentHost.removeFromSuperview()
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let sidebar = makeDashboardSidebar(titlebarHeight: titlebarHeight)
        let contentSurface = NSView()
        contentSurface.wantsLayer = true
        contentSurface.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor(calibratedWhite: 0.94, alpha: 0.82),
            dark: NSColor.black.withAlphaComponent(0.20)
        ).cgColor
        contentSurface.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        dashboardContentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentSurface)
        root.addSubview(sidebar)
        root.addSubview(dashboardContentHost)
        NSLayoutConstraint.activate([
            contentSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentSurface.topAnchor.constraint(equalTo: root.topAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 216),
            dashboardContentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            dashboardContentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dashboardContentHost.topAnchor.constraint(equalTo: root.topAnchor),
            dashboardContentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        window.contentView = root
        DashboardWindowDragPolicy.install(in: window, contentRoot: root)
    }

    private func rebuildDashboardForLanguageChange() {
        guard let window = dashboard else { return }
        let selectedSection = dashboardSection
        let selectedProviderID = dashboardSelectedProviderID
        installDashboardLayout(in: window)
        if let selectedProviderID,
           ccSwitchRepository.loadChoices(appType: activeClient.appType)
               .contains(where: { $0.id == selectedProviderID }) {
            showDashboardProvider(selectedProviderID)
        } else {
            showDashboardSection(selectedSection)
        }
    }

    private func makeGlassEffectView(contentView: NSView, cornerRadius: CGFloat) -> NSView? {
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

    private func makeDashboardSidebar(titlebarHeight: CGFloat) -> NSView {
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
        if let glassPanel = makeGlassEffectView(contentView: sidebarContent, cornerRadius: 22) {
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
        dashboardNavigationButtons.removeAll()
        dashboardNavigationRows.removeAll()

        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .general))
        navigation.setCustomSpacing(12, after: navigation.arrangedSubviews.last!)

        let appearanceLabel = makeDashboardSidebarGroupTitle(tr("外观", "Appearance"))
        navigation.addArrangedSubview(appearanceLabel)
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .menuBar))
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .menu))
        navigation.setCustomSpacing(12, after: navigation.arrangedSubviews.last!)

        let systemLabel = makeDashboardSidebarGroupTitle(tr("系统", "System"))
        navigation.addArrangedSubview(systemLabel)
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .advanced))
        navigation.addArrangedSubview(makeDashboardNavigationRow(for: .about))

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

    private func makeDashboardSidebarGroupTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return label
    }

    private func makeDashboardNavigationRow(for section: DashboardSection) -> NSView {
        let row = DashboardNavigationRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.clear.cgColor
        row.widthAnchor.constraint(equalToConstant: 168).isActive = true
        row.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let button = NSButton(title: "", target: self, action: #selector(selectDashboardSection(_:)))
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
        dashboardNavigationButtons[section] = button
        dashboardNavigationRows[section] = row
        row.updateAppearance(animated: false)
        return row
    }

    private func showDashboardSection(
        _ section: DashboardSection,
        restoringScrollPosition scrollPosition: StatusLinksScrollPosition? = nil
    ) {
        dashboardSection = section
        dashboardSelectedProviderID = nil
        dashboard?.title = section.title
        dashboardNavigationButtons.forEach {
            let isCurrent = $0.key == section
            $0.value.state = isCurrent ? .on : .off
            $0.value.isBordered = false
            $0.value.contentTintColor = .clear
            dashboardNavigationRows[$0.key]?.isSelected = isCurrent
        }
        rebuildDashboardProviderList()
        statusLinksScrollAnchorController.stop()
        statusLinksEditorHostingView?.teardown()
        statusLinksEditorHostingView = nil
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }

        let page: NSView
        switch section {
        case .general: page = makeGeneralDashboardPage()
        case .menuBar: page = makeMenuBarDashboardPage()
        case .menu: page = makeMenuDashboardPage()
        case .advanced: page = makeAdvancedDashboardPage()
        case .about: page = makeAboutDashboardPage()
        }
        page.frame = dashboardContentHost.bounds
            page.autoresizingMask = [.width, .height]
        dashboardContentHost.addSubview(page)
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))

        if let scrollPosition {
            // The new document view needs one layout pass before its maximum
            // scroll offset is known. Restore asynchronously so adding a row
            // keeps the user's current viewport instead of jumping to the top.
            statusLinksScrollAnchorController.restore(scrollPosition, attempt: 0)
        }
    }

    private func clampDashboardScrollViewBounds() {
        statusLinksScrollAnchorController.clampDashboardScrollViewBounds()
    }

    private func rebuildDashboardProviderList() {
        guard dashboard != nil else { return }
        for child in dashboardProviderList.arrangedSubviews {
            dashboardProviderList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        dashboardProviderButtons.removeAll()

        let query = dashboardProviderSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var choices = ccSwitchRepository.loadChoices(appType: activeClient.appType).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        if sortProvidersAlphabetically {
            choices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        dashboardProviderCountLabel.stringValue = tr(
            "\(ccSwitchRepository.loadChoices(appType: activeClient.appType).count) 个",
            "\(ccSwitchRepository.loadChoices(appType: activeClient.appType).count)"
        )

        for choice in choices {
            let button = NSButton(title: choice.name, target: self, action: #selector(dashboardSelectProvider(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            let isSelected = dashboardSelectedProviderID == choice.id
            button.isBordered = isSelected
            button.state = isSelected ? .on : .off
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            button.contentTintColor = isSelected ? .controlAccentColor : (choice.isCurrent ? .labelColor : .secondaryLabelColor)
            button.focusRingType = .none
            button.identifier = NSUserInterfaceItemIdentifier(choice.id)
            button.toolTip = choice.isCurrent
                ? tr("当前供应商", "Current Provider")
                : tr("查看 \(choice.name)", "View \(choice.name)")
            if let iconURL = Bundle.main.url(forResource: "CodexIcon", withExtension: "svg"),
               let image = NSImage(contentsOf: iconURL) {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                button.image = image
            }
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 228).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            dashboardProviderButtons[choice.id] = button
            dashboardProviderList.addArrangedSubview(button)
        }
    }

    private func showDashboardProvider(_ providerID: String) {
        guard let choice = ccSwitchRepository.loadChoices(appType: activeClient.appType)
            .first(where: { $0.id == providerID }) else { return }
        dashboardSelectedProviderID = providerID
        dashboard?.title = choice.name
        dashboardNavigationButtons.values.forEach {
            $0.state = .off
            $0.isBordered = false
            $0.contentTintColor = .labelColor
        }
        rebuildDashboardProviderList()
        dashboardContentHost.subviews.forEach { $0.removeFromSuperview() }
        let page = makeProviderDashboardPage(choice)
        page.frame = dashboardContentHost.bounds
        page.autoresizingMask = [.width, .height]
        dashboardContentHost.addSubview(page)
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private func makeSettingsPage(_ sections: [NSView]) -> NSView {
        let root = NSView()
        let scrollView = NSScrollView()
        scrollView.contentView = DashboardClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        // Keep the scrollbar discoverable on dense settings pages. The
        // document is taller than the viewport when the status-link editor is
        // present, so hiding the scroller makes the add control look missing.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        documentView.addSubview(stack)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 62),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -34),
            // The stack must fit inside the document, but it should keep its
            // natural height when the page is shorter than the viewport.
            // Using an equality here makes AppKit stretch the first card to
            // consume all remaining space.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -34)
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return root
    }

    private func makeSettingsSection(
        _ title: String,
        rows: [NSView],
        onLayoutCreated: ((NSStackView, NSLayoutConstraint, [NSView]) -> Void)? = nil
    ) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.94),
            dark: NSColor.white.withAlphaComponent(0.065)
        ).cgColor
        card.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.white.withAlphaComponent(0.95),
            dark: NSColor.white.withAlphaComponent(0.075)
        ).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = dashboardUsesDarkAppearance ? 0.20 : 0.08
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = NSSize(width: 0, height: -3)
        card.layer?.masksToBounds = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setContentHuggingPriority(.required, for: .vertical)
        // The card has an explicit height that changes when status-link rows
        // are added or removed. Let the stack follow that constraint instead
        // of preserving the previous intrinsic height and leaving an empty
        // gravity area below the editor.
        rowsStack.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        var separators: [NSView] = []
        for (index, row) in rows.enumerated() {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -32).isActive = true
                separators.append(separator)
            }
        }

        // NSView has no intrinsic height. Give the card the exact height of
        // its rows so a short settings page cannot stretch the first row to
        // fill the scroll viewport.
        let visibleRows = rows.filter { !$0.isHidden }
        let rowsHeight = visibleRows.reduce(CGFloat(0)) { partial, row in
            let explicitHeight = row.constraints.first {
                ($0.firstItem as? NSView) === row &&
                    $0.firstAttribute == .height &&
                    $0.relation == .equal
            }?.constant
            let fittingHeight: CGFloat
            if let editor = row as? StatusLinksEditorHostingView {
                fittingHeight = editor.layoutHeight
            } else {
                fittingHeight = row.fittingSize.height
            }
            return partial + max(1, explicitHeight ?? fittingHeight)
        }
        let separatorHeight = CGFloat(max(0, visibleRows.count - 1))
        let cardHeightConstraint = card.heightAnchor.constraint(
            equalToConstant: max(1, ceil(rowsHeight + separatorHeight))
        )
        cardHeightConstraint.isActive = true
        onLayoutCreated?(rowsStack, cardHeightConstraint, separators)

        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 11
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        if let editor = rows.first(where: { $0 is StatusLinksEditorHostingView }) as? StatusLinksEditorHostingView {
            DispatchQueue.main.async { [weak editor] in
                editor?.logGeometry(label: "initial")
            }
        }
        return section
    }

    private func makeSettingsRow(
        _ title: String,
        subtitle: String? = nil,
        subtitleLabel: NSTextField? = nil,
        control: NSView? = nil,
        minimumHeight: CGFloat = 58
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: max(62, minimumHeight)).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isEditable = false
        label.isSelectable = false
        let labels = NSStackView(views: [label])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let subtitle, !subtitle.isEmpty {
            let detail = subtitleLabel ?? NSTextField(wrappingLabelWithString: subtitle)
            detail.stringValue = subtitle
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.isEditable = false
            detail.isSelectable = false
            labels.addArrangedSubview(detail)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        var constraints = [
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 11),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -11)
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints.append(contentsOf: [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -20)
            ])
        } else {
            constraints.append(labels.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -20))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func makeOpenCodexManualPortRow(
        portField: NSTextField,
        errorLabel: NSTextField
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = row.heightAnchor.constraint(equalToConstant: 86)
        heightConstraint.isActive = true
        openCodexManualPortRowHeightConstraint = heightConstraint

        let title = NSTextField(labelWithString: tr("手动输入端口号", "Enter Port Manually"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: tr(
            "仅接受去空格后的十进制 1–65535；清空后恢复自动检测",
            "Only trimmed decimal 1–65535 is accepted; clear the field to restore automatic detection"
        ))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isEditable = false
        errorLabel.isSelectable = false
        errorLabel.isHidden = true

        let labels = NSStackView(views: [title, detail, errorLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)

        portField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(portField)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 11),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -11),
            portField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            portField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: portField.leadingAnchor, constant: -20)
        ])
        return row
    }

    private func makeGeneralDashboardPage() -> NSView {
        let openButton = NSButton(title: tr("打开 CC Switch", "Open CC Switch"), target: self, action: #selector(openCCSwitch))
        let currentName = ccSwitchRepository.loadChoices(appType: activeClient.appType)
            .first(where: { $0.isCurrent })?.name ?? tr("未找到", "Not Found")
        let currentProviderText = tr(
            "当前供应商：\(currentName)",
            "Current Provider: \(currentName)"
        )
        let system = makeSettingsSection(tr("系统", "System"), rows: [
            makeSettingsRow(
                "CC Switch",
                subtitle: currentProviderText,
                subtitleLabel: dashboardCurrentProviderSubtitle,
                control: openButton
            )
        ])

        let activeRefreshPopup = makeIntervalPopup(
            values: [
                (1, tr("每 1 秒", "Every 1 sec")),
                (2, tr("每 2 秒", "Every 2 sec")),
                (3, tr("每 3 秒", "Every 3 sec")),
                (5, tr("每 5 秒", "Every 5 sec")),
                (10, tr("每 10 秒", "Every 10 sec"))
            ],
            selected: codexUsageRefreshInterval,
            identifier: "codexUsageRefreshInterval"
        )
        let trailingRefreshPopup = makeIntervalPopup(
            values: [
                (0, tr("不继续", "Off")),
                (6, tr("持续 6 秒", "For 6 sec")),
                (12, tr("持续 12 秒", "For 12 sec")),
                (30, tr("持续 30 秒", "For 30 sec"))
            ],
            selected: postCodexRefreshDuration,
            identifier: "postCodexRefreshDuration"
        )
        let runningLabel = NSTextField(labelWithString: tr("运行中", "Running"))
        let trailingLabel = NSTextField(labelWithString: tr("结束后", "After"))
        [runningLabel, trailingLabel].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        [activeRefreshPopup, trailingRefreshPopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 108).isActive = true
        }
        let runningControls = NSStackView(views: [
            runningLabel, activeRefreshPopup
        ])
        runningControls.orientation = .horizontal
        runningControls.alignment = .centerY
        runningControls.spacing = 7
        let trailingControls = NSStackView(views: [
            trailingLabel, trailingRefreshPopup
        ])
        trailingControls.orientation = .horizontal
        trailingControls.alignment = .centerY
        trailingControls.spacing = 7
        let activeRefreshControls = NSStackView(views: [
            runningControls, trailingControls
        ])
        activeRefreshControls.orientation = .vertical
        activeRefreshControls.alignment = .trailing
        activeRefreshControls.spacing = 5
        let refreshButton = NSButton(title: tr("立即刷新", "Refresh Now"), target: self, action: #selector(dashboardManualRefresh))
        let refreshing = makeSettingsSection(tr("刷新", "Refresh"), rows: [
            makeSettingsRow(
                tr("任务期间余量更新频率", "Balance Updates During Tasks"),
                subtitle: tr(
                    "Agent 运行时请求当前供应商的余量",
                    "Requests the current Provider's balance while an Agent is running"
                ),
                control: activeRefreshControls,
                minimumHeight: 76
            ),
            makeSettingsRow(tr("余额数据", "Balance Data"), subtitle: tr("立即重新读取当前供应商", "Reload the current Provider now"), control: refreshButton)
        ])

        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.target = self
        languagePopup.action = #selector(dashboardLanguageChanged(_:))
        for (index, language) in AppLanguage.allCases.enumerated() {
            languagePopup.addItem(withTitle: language.localizedTitle)
            languagePopup.item(at: index)?.representedObject = language.rawValue
            if language == AppLanguage.selected {
                languagePopup.selectItem(at: index)
            }
        }
        let app = makeSettingsSection(tr("应用", "Application"), rows: [
            makeSettingsRow(
                tr("语言", "Language"),
                subtitle: tr("更改后立即应用到整个界面", "Changes apply to the entire interface immediately"),
                control: languagePopup
            ),
        ])
        return makeSettingsPage([system, refreshing, app])
    }

    private func makeStatusLinksEditor() -> NSView {
        let editor = StatusLinksEditorHostingView(
            links: statusLinks,
            onChange: { [weak self] index, field, value in
                self?.dashboardStatusLinkChanged(index: index, field: field, value: value)
            },
            onAdd: { [weak self] in
                self?.addStatusLink()
            },
            onRemove: { [weak self] index in
                self?.removeStatusLink(at: index)
            },
            onReset: { [weak self] in
                self?.resetStatusLinks()
            }
        )
        statusLinksEditorHostingView = editor
        return editor
    }

    private func makeMenuDashboardPage() -> NSView {
        let quickSwitch = makeDashboardSwitch(
            identifier: "showQuickSwitchMenu",
            isOn: showQuickSwitchMenu
        )
        let openCC = makeDashboardSwitch(
            identifier: "showOpenCCSwitchMenu",
            isOn: showOpenCCSwitchMenu
        )
        let keepOpen = makeDashboardSwitch(
            identifier: "keepMenuOpenAfterRefresh",
            isOn: keepMenuOpenAfterRefresh
        )

        let items = makeSettingsSection(tr("展开菜单", "Dropdown Menu"), rows: [
            makeSettingsRow(tr("快速切换", "Quick Switch"), subtitle: tr("显示 CC Switch 供应商子菜单", "Show the CC Switch Provider submenu"), control: quickSwitch),
            makeSettingsRow(tr("刷新后保持展开", "Keep Open After Refresh"), subtitle: tr("点击立即刷新后重新打开菜单", "Reopen the menu after Refresh Now"), control: keepOpen)
        ])
        let openMainWindow = makeDashboardSwitch(
            identifier: "showOpenDashboardMenu",
            isOn: true
        )
        openMainWindow.isEnabled = false
        openMainWindow.toolTip = tr(
            "打开主窗口入口始终显示",
            "The Open Main Window item is always shown"
        )

        var projectRows: [NSView] = [
            makeSettingsRow(
                tr("打开主窗口", "Open Main Window"),
                control: openMainWindow
            ),
            makeSettingsRow(
                tr("打开 ChatGPT", "Open ChatGPT"),
                subtitle: tr("显示 ChatGPT 启动项", "Show the ChatGPT launch item"),
                control: makeDashboardSwitch(
                    identifier: "showOpenChatGPTMenu",
                    isOn: showOpenChatGPTMenu
                )
            ),
            makeSettingsRow(
                tr("打开 CC Switch", "Open CC Switch"),
                subtitle: tr("显示 CC Switch 启动项", "Show the CC Switch launch item"),
                control: openCC
            )
        ]
        if showStatusMenu {
            projectRows.append(makeSettingsRow(
                tr("查看状态", "View Status"),
                subtitle: tr("显示可自定义的服务状态链接", "Show customizable service status links"),
                control: makeDashboardSwitch(identifier: "showStatusMenu", isOn: showStatusMenu)
            ))
            projectRows.append(makeStatusLinksEditor())
        } else {
            projectRows.append(makeSettingsRow(
                tr("查看状态", "View Status"),
                subtitle: tr("在菜单栏中显示状态链接", "Show status links in the menu bar"),
                control: makeDashboardSwitch(identifier: "showStatusMenu", isOn: showStatusMenu)
            ))
        }
        let projects = makeSettingsSection(tr("打开项目", "Open Project"), rows: projectRows)
        return makeSettingsPage([items, projects])
    }

    private func makeDashboardLogViewer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 190).isActive = true

        dashboardLogView.isEditable = false
        dashboardLogView.isSelectable = true
        dashboardLogView.isRichText = true
        dashboardLogView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let vscodeForeground = vscodeColor(0xD4D4D4)
        let vscodeBackground = vscodeColor(0x1E1E1E)
        let vscodeSelection = vscodeColor(0x264F78)
        dashboardLogView.textColor = vscodeForeground
        dashboardLogView.backgroundColor = vscodeBackground
        dashboardLogView.drawsBackground = true
        let selectionAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .backgroundColor: vscodeSelection
        ]
        dashboardLogView.selectedTextAttributes = selectionAttributes
        dashboardLogView.isVerticallyResizable = true
        dashboardLogView.isHorizontallyResizable = true
        dashboardLogView.autoresizingMask = []
        dashboardLogView.minSize = .zero
        dashboardLogView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        dashboardLogView.textContainerInset = NSSize(width: 8, height: 8)
        dashboardLogView.textContainer?.widthTracksTextView = false
        dashboardLogView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scroll = NSScrollView()
        scroll.documentView = dashboardLogView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = dashboardLogView.backgroundColor
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        refreshDashboardLog()
        return container
    }

    private func makeAdvancedDashboardPage() -> NSView {
        openCodexPortInputHasError = false
        openCodexAutomaticDetectionSwitch = nil
        openCodexPortField = nil
        openCodexManualPortRow = nil
        openCodexManualPortRowHeightConstraint = nil
        openCodexPortStatusLabel = nil
        openCodexPortErrorLabel = nil
        openCodexOpenButton = nil
        openCodexSettingsRowsStack = nil
        openCodexSettingsCardHeightConstraint = nil
        openCodexSettingsSeparators = []
        openCodexDashboardInteractionState.mode = openCodexDashboardMode
        openCodexDashboardInteractionState.markPortEditorActive(false)
        let animation = makeDashboardSwitch(
            identifier: "animateCodexActivity",
            isOn: animateCodexActivity
        )
        let activity = makeSettingsSection(tr("任务状态", "Task Status"), rows: [
            makeSettingsRow(
                tr("任务运行时播放图标动画", "Animate Icon While a Task Is Running"),
                control: animation
            )
        ])

        let automaticDetection = openCodexDashboardAutomaticDetection
        let currentResolution = currentOpenCodexDashboardResolution()
        let initialResolution = currentResolution
            ?? OpenCodexDashboardResolver.resolve(
                manualPort: openCodexDashboardMode.effectiveManualPort,
                runtimeCandidate: nil
            )
        let statusLabel = NSTextField(wrappingLabelWithString: tr("正在解析…", "Resolving…"))
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let automaticSwitch = makeDashboardSwitch(
            identifier: "openCodexAutomaticDetection",
            isOn: automaticDetection
        )
        let automaticRow = makeSettingsRow(
            tr("自动检测端口", "Detect Port Automatically"),
            subtitle: tr(
                "使用已验证的 OpenCodex runtime 端口；未检测时使用 10100",
                "Use the verified OpenCodex runtime port; use 10100 until one is detected"
            ),
            subtitleLabel: statusLabel,
            control: automaticSwitch,
            minimumHeight: 86
        )

        let portField = NSTextField()
        portField.stringValue = String(
            openCodexDashboardMode.manualPort ?? initialResolution.port
        )
        portField.placeholderString = "10100"
        portField.alignment = .right
        portField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        portField.isEditable = true
        portField.isSelectable = true
        portField.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true

        let manualPortRow = makeOpenCodexManualPortRow(
            portField: portField,
            errorLabel: errorLabel
        )
        manualPortRow.isHidden = automaticDetection

        let openButton = NSButton(
            title: tr("打开 OpenCodex", "Open OpenCodex"),
            target: self,
            action: #selector(openOpenCodex)
        )
        openButton.isEnabled = currentResolution != nil
        openCodexAutomaticDetectionSwitch = automaticSwitch
        openCodexPortField = portField
        openCodexManualPortRow = manualPortRow
        openCodexPortStatusLabel = statusLabel
        openCodexPortErrorLabel = errorLabel
        openCodexOpenButton = openButton
        let openButtonRow = makeSettingsRow(
            tr("OpenCodex Dashboard", "OpenCodex Dashboard"),
            subtitle: tr(
                "使用当前解析到的本机地址；固定打开 /#dashboard",
                "Uses the resolved local address and always opens /#dashboard"
            ),
            control: openButton,
            minimumHeight: 78
        )

        let openCodex = makeSettingsSection(
            tr("OpenCodex", "OpenCodex"),
            rows: [automaticRow, manualPortRow, openButtonRow],
            onLayoutCreated: { [weak self] rowsStack, cardHeightConstraint, separators in
                guard let self else { return }
                self.openCodexSettingsRowsStack = rowsStack
                self.openCodexSettingsCardHeightConstraint = cardHeightConstraint
                self.openCodexSettingsSeparators = separators
                if automaticDetection, !separators.isEmpty {
                    separators[0].isHidden = true
                }
            }
        )
        openCodexDashboardLastResolvedPort = initialResolution.port
        applyOpenCodexDashboardResolution(
            initialResolution,
            canOpen: currentResolution != nil
        )

        let refreshLog = NSButton(title: tr("重新载入", "Reload"), target: self, action: #selector(refreshDashboardLog))
        let revealLog = NSButton(title: tr("在 Finder 中显示", "Show in Finder"), target: self, action: #selector(revealDashboardLog))
        let logButtons = NSStackView(views: [refreshLog, revealLog])
        logButtons.orientation = .horizontal
        logButtons.spacing = 8
        let logs = makeSettingsSection(tr("诊断", "Diagnostics"), rows: [
            makeSettingsRow(
                tr("调试日志", "Debug Log"),
                subtitle: tr(
                    "记录运行状态与错误",
                    "Records runtime status and errors"
                ),
                control: logButtons
            ),
            makeDashboardLogViewer()
        ])
        return makeSettingsPage([activity, openCodex, logs])
    }

    private func makeAboutDashboardPage() -> NSView {
        let root = NSView()
        let icon = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "BalanceBar", withExtension: "icns") {
            icon.image = NSImage(contentsOf: iconURL)
        }
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "BalanceBar")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.11.14"
        let isDevBuild = Bundle.main.bundleIdentifier == devBundleIdentifier
        let version = NSTextField(labelWithString: tr(
            "版本 \(appVersion)",
            "Version \(appVersion)"
        ) + (isDevBuild ? " · Dev" : ""))
        version.textColor = .secondaryLabelColor
        let detail = NSTextField(labelWithString: tr(
            "基于 CC Switch 的菜单栏余量查看工具",
            "A CC Switch-based menu bar balance viewer"
        ))
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name, version, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 92)
        ])
        return root
    }

    private func makeProviderDashboardPage(_ choice: ProviderChoice) -> NSView {
        dashboardProviderLabel.stringValue = choice.name
        dashboardProviderLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(labelWithString: choice.isCurrent
            ? tr("当前供应商", "Current Provider")
            : tr("可用供应商", "Available Provider"))
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = choice.isCurrent ? .systemGreen : .secondaryLabelColor
        let heading = NSStackView(views: [dashboardProviderLabel, status])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        quickSwitchSummaryLock.lock()
        let cachedSummary = quickSwitchSummaries[choice.id]
        quickSwitchSummaryLock.unlock()
        dashboardAmountLabel.stringValue = choice.isCurrent ? snapshot.overviewLargeAmount : (cachedSummary ?? tr("正在读取…", "Loading…"))
        dashboardAmountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        dashboardQuotaLabel.stringValue = tr("剩余额度", "Remaining Balance")
        dashboardResetLabel.stringValue = choice.isCurrent
            ? snapshot.overviewReset(refreshDate: lastSuccessfulRefresh, formatter: Self.timeFormatter)
            : tr("选择为当前供应商后显示详细重置时间", "Select this Provider to display detailed reset information")
        let usage = makeSettingsSection(tr("用量", "Usage"), rows: [
            makeSettingsRow(tr("剩余额度", "Remaining Balance"), subtitle: dashboardResetLabel.stringValue, control: dashboardAmountLabel, minimumHeight: 76)
        ])

        let action: NSButton
        if choice.isCurrent {
            action = NSButton(title: tr("立即刷新", "Refresh Now"), target: self, action: #selector(dashboardManualRefresh))
        } else {
            action = NSButton(title: tr("切换到此供应商", "Switch to This Provider"), target: self, action: #selector(dashboardSwitchProvider(_:)))
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
        }
        let connection = makeSettingsSection("CC Switch", rows: [
            makeSettingsRow(tr("同步状态", "Sync Status"), subtitle: choice.isCurrent
                ? tr("正在跟随此供应商", "Following this Provider")
                : tr("当前未使用此供应商", "This Provider is not currently active"), control: action)
        ])
        return makeSettingsPage([heading, usage, connection])
    }

    private func makePageHeader(_ title: String, subtitle: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makeOverviewDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader(tr("概览", "Overview"), subtitle: tr("当前余额、同步状态和 Codex 供应商", "Current balance, sync status, and Codex Provider"))

        dashboardProviderLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        dashboardProviderLabel.lineBreakMode = .byTruncatingTail
        dashboardRefreshLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dashboardRefreshLabel.textColor = .secondaryLabelColor
        dashboardRefreshLabel.alignment = .right
        let providerSpacer = NSView()
        let providerRow = NSStackView(views: [dashboardProviderLabel, providerSpacer, dashboardRefreshLabel])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY

        dashboardQuotaLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dashboardResetLabel.font = .systemFont(ofSize: 13)
        dashboardResetLabel.textColor = .secondaryLabelColor
        let quotaStack = NSStackView(views: [dashboardQuotaLabel, dashboardResetLabel])
        quotaStack.orientation = .vertical
        quotaStack.alignment = .leading
        quotaStack.spacing = 5

        dashboardAmountLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        dashboardAmountLabel.alignment = .right
        let quotaSpacer = NSView()
        let quotaRow = NSStackView(views: [quotaStack, quotaSpacer, dashboardAmountLabel])
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .centerY

        dashboardProgressHost.translatesAutoresizingMaskIntoConstraints = false
        dashboardProgressHost.heightAnchor.constraint(equalToConstant: 6).isActive = true
        dashboardStatusLabel.font = .systemFont(ofSize: 12)
        dashboardStatusLabel.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        let providersTitle = NSTextField(labelWithString: tr("供应商", "Providers"))
        providersTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        dashboardProvidersStack.orientation = .vertical
        dashboardProvidersStack.alignment = .leading
        dashboardProvidersStack.spacing = 0

        let stack = NSStackView(views: [
            header, providerRow, quotaRow, dashboardProgressHost,
            dashboardStatusLabel, separator, providersTitle, dashboardProvidersStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(7, after: dashboardProgressHost)
        stack.setCustomSpacing(18, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            providerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quotaRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboardProgressHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboardProvidersStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func makeMenuBarDashboardPage() -> NSView {
        let previewContent = NSView()
        let preview: NSView
        if let glassPreview = makeGlassEffectView(contentView: previewContent, cornerRadius: 7) {
            preview = glassPreview
        } else {
            let visualEffectPreview = NSVisualEffectView()
            visualEffectPreview.material = .menu
            visualEffectPreview.state = .active
            visualEffectPreview.wantsLayer = true
            visualEffectPreview.layer?.cornerRadius = 7
            visualEffectPreview.layer?.backgroundColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.64),
                dark: NSColor.black.withAlphaComponent(0.18)
            ).cgColor
            visualEffectPreview.layer?.borderColor = dashboardAdaptiveColor(
                light: NSColor.white.withAlphaComponent(0.72),
                dark: NSColor.white.withAlphaComponent(0.08)
            ).cgColor
            visualEffectPreview.layer?.borderWidth = 0.5
            previewContent.translatesAutoresizingMaskIntoConstraints = false
            visualEffectPreview.addSubview(previewContent)
            NSLayoutConstraint.activate([
                previewContent.topAnchor.constraint(equalTo: visualEffectPreview.topAnchor),
                previewContent.leadingAnchor.constraint(equalTo: visualEffectPreview.leadingAnchor),
                previewContent.trailingAnchor.constraint(equalTo: visualEffectPreview.trailingAnchor),
                previewContent.bottomAnchor.constraint(equalTo: visualEffectPreview.bottomAnchor)
            ])
            preview = visualEffectPreview
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 190).isActive = true
        dashboardMenuPreviewIcon.imageScaling = .scaleProportionallyDown
        dashboardMenuPreviewIcon.translatesAutoresizingMaskIntoConstraints = false
        dashboardMenuPreviewIcon.wantsLayer = true
        dashboardMenuPreviewIcon.widthAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        dashboardMenuPreviewIcon.heightAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        dashboardMenuPreviewPrimary.font = MenuBarLayout.primaryFont
        dashboardMenuPreviewPrimary.textColor = .labelColor
        dashboardMenuPreviewSecondary.font = MenuBarLayout.secondaryFont
        dashboardMenuPreviewSecondary.textColor = .labelColor
        let previewText = dashboardMenuPreviewText
        previewText.addSubview(dashboardMenuPreviewPrimary)
        previewText.addSubview(dashboardMenuPreviewSecondary)
        previewText.wantsLayer = true
        previewText.layer?.setAffineTransform(.identity)
        let previewTextWidth = previewText.widthAnchor.constraint(equalToConstant: 32)
        previewTextWidth.priority = .defaultHigh
        previewTextWidth.isActive = true
        dashboardMenuPreviewTextWidthConstraint = previewTextWidth
        let previewIconSlot = dashboardMenuPreviewIconSlot
        previewIconSlot.translatesAutoresizingMaskIntoConstraints = false
        previewIconSlot.widthAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIconSlot.heightAnchor.constraint(equalToConstant: MenuBarLayout.iconSlotWidth).isActive = true
        previewIconSlot.addSubview(dashboardMenuPreviewIcon)
        NSLayoutConstraint.activate([
            dashboardMenuPreviewIcon.centerXAnchor.constraint(equalTo: previewIconSlot.centerXAnchor),
            dashboardMenuPreviewIcon.centerYAnchor.constraint(equalTo: previewIconSlot.centerYAnchor)
        ])
        let previewRow = NSStackView(views: [previewIconSlot, previewText])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = MenuBarLayout.iconTextSpacing
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        dashboardMenuPreviewCapsule.wantsLayer = true
        dashboardMenuPreviewCapsule.layer?.backgroundColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.08),
            dark: NSColor.white.withAlphaComponent(0.12)
        ).cgColor
        dashboardMenuPreviewCapsule.layer?.borderColor = dashboardAdaptiveColor(
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.08)
        ).cgColor
        dashboardMenuPreviewCapsule.layer?.borderWidth = 0.5
        dashboardMenuPreviewCapsule.layer?.cornerRadius = 12
        dashboardMenuPreviewCapsule.layer?.masksToBounds = true
        dashboardMenuPreviewCapsule.isHidden = true
        dashboardMenuPreviewCapsule.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(dashboardMenuPreviewCapsule)
        previewContent.addSubview(previewRow)
        let capsuleLeading = dashboardMenuPreviewCapsule.leadingAnchor.constraint(
            equalTo: previewRow.leadingAnchor,
            constant: -(menuBarHorizontalPadding + dashboardMenuPreviewChromeInset)
        )
        let capsuleTrailing = dashboardMenuPreviewCapsule.trailingAnchor.constraint(
            equalTo: previewRow.trailingAnchor,
            constant: menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        )
        dashboardMenuPreviewCapsuleLeadingConstraint = capsuleLeading
        dashboardMenuPreviewCapsuleTrailingConstraint = capsuleTrailing
        NSLayoutConstraint.activate([
            previewRow.centerXAnchor.constraint(equalTo: previewContent.centerXAnchor),
            previewRow.centerYAnchor.constraint(equalTo: previewContent.centerYAnchor),
            previewRow.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 14),
            previewRow.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -14),
            capsuleLeading,
            capsuleTrailing,
            dashboardMenuPreviewCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: previewContent.leadingAnchor, constant: 6),
            dashboardMenuPreviewCapsule.trailingAnchor.constraint(lessThanOrEqualTo: previewContent.trailingAnchor, constant: -6),
            dashboardMenuPreviewCapsule.topAnchor.constraint(equalTo: previewRow.topAnchor, constant: -3),
            dashboardMenuPreviewCapsule.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor, constant: 3),
            preview.heightAnchor.constraint(equalToConstant: 42)
        ])
        let iconToggle = makeDashboardSwitch(
            identifier: "showMenuBarIcon",
            isOn: showMenuBarIcon
        )
        let amountToggle = makeDashboardSwitch(
            identifier: "showMenuBarAmount",
            isOn: showMenuBarAmount
        )
        let resetToggle = makeDashboardSwitch(
            identifier: "showMenuBarReset",
            isOn: showMenuBarReset
        )
        dashboardMenuBarIconSwitch = iconToggle
        dashboardMenuBarAmountSwitch = amountToggle
        let previewSection = makeSettingsSection(tr("预览", "Preview"), rows: [
            makeSettingsRow(
                tr("当前布局", "Current Layout"),
                subtitle: tr(
                    "菜单栏会随供应商数据实时更新",
                    "The menu bar updates with Provider data in real time"
                ),
                control: preview,
                minimumHeight: 66
            )
        ])
        let displaySection = makeSettingsSection(tr("显示项目", "Display Items"), rows: [
            makeSettingsRow(tr("Agent 图标", "Agent Icon"), subtitle: tr("显示当前任务运行状态", "Shows the current task status"), control: iconToggle),
            makeSettingsRow(tr("额度数字", "Balance Amount"), subtitle: tr("显示百分比或 API 余额", "Shows a percentage or API balance"), control: amountToggle),
            makeSettingsRow(tr("重置倒计时", "Reset Countdown"), subtitle: tr("仅在官方额度可用时显示", "Only shown when official quota data is available"), control: resetToggle)
        ])
        refreshDashboardMenuBarPage()
        return makeSettingsPage([previewSection, displaySection])
    }

    private func refreshDashboardMenuBarPage() {
        guard dashboard?.isVisible == true, dashboardSection == .menuBar else { return }
        dashboardMenuPreviewIconSlot.isHidden = !showMenuBarIcon
        dashboardMenuPreviewText.isHidden = !showMenuBarAmount
        // Keep at least one visible status-item component. Disabling the last
        // active switch avoids instantly reversing an NSSwitch animation,
        // which can otherwise leave overlapping on/off layers on vibrancy.
        dashboardMenuBarIconSwitch?.isEnabled = showMenuBarAmount
        dashboardMenuBarAmountSwitch?.isEnabled = showMenuBarIcon
        let effectiveMenuBarSnapshot = menuBarSnapshot(for: snapshot)
        dashboardMenuPreviewPrimary.stringValue = showMenuBarAmount ? effectiveMenuBarSnapshot.menuBarPrimary : ""
        dashboardMenuPreviewSecondary.stringValue = effectiveMenuBarSnapshot.kind == .official
            ? effectiveMenuBarSnapshot.menuBarSecondary
            : ""
        let hasSecondary = showMenuBarAmount
            && showMenuBarReset
            && effectiveMenuBarSnapshot.kind == .official
            && !dashboardMenuPreviewSecondary.stringValue.isEmpty
        let geometry = MenuBarLayout.geometry(
            primarySize: dashboardMenuPreviewPrimary.intrinsicContentSize,
            secondarySize: dashboardMenuPreviewSecondary.intrinsicContentSize,
            showIcon: showMenuBarIcon,
            showAmount: showMenuBarAmount,
            hasSecondary: hasSecondary,
            isBalance: effectiveMenuBarSnapshot.kind == .balance,
        )
        MenuBarLayout.applyTextLayout(
            container: dashboardMenuPreviewText,
            primary: dashboardMenuPreviewPrimary,
            secondary: dashboardMenuPreviewSecondary,
            geometry: geometry,
            showAmount: showMenuBarAmount,
            hasSecondary: hasSecondary
        )
        dashboardMenuPreviewTextWidthConstraint?.constant = geometry.textWidth
        dashboardMenuPreviewCapsuleLeadingConstraint?.constant = -(
            menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        )
        dashboardMenuPreviewCapsuleTrailingConstraint?.constant =
            menuBarHorizontalPadding + dashboardMenuPreviewChromeInset
        dashboardMenuPreviewIcon.image = statusItemController.iconImage
        dashboardMenuPreviewIcon.contentTintColor = .labelColor
        dashboardMenuPreviewIcon.layer?.setAffineTransform(.identity)
        dashboardMenuPreviewText.layer?.setAffineTransform(.identity)
        if effectiveMenuBarSnapshot.kind == .balance,
           showMenuBarIcon,
           showMenuBarAmount {
            dashboardMenuPreviewIcon.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -MenuBarLayout.singleLineIconYOffset
            ))
            dashboardMenuPreviewText.layer?.setAffineTransform(CGAffineTransform(
                translationX: 0,
                y: -MenuBarLayout.singleLineTextYOffset
            ))
        }
    }

    private func makeRefreshDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader(tr("刷新设置", "Refresh Settings"), subtitle: tr("文件监听始终开启，轮询用于防止遗漏系统事件", "File monitoring is always active; polling prevents missed system events"))
        let pollingTitle = NSTextField(labelWithString: tr("CC Switch 轮询兜底", "CC Switch Fallback Polling"))
        pollingTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let pollingPopup = makeIntervalPopup(
            values: [(1, tr("每 1 秒", "Every 1 sec")), (3, tr("每 3 秒", "Every 3 sec")), (5, tr("每 5 秒", "Every 5 sec")), (10, tr("每 10 秒", "Every 10 sec"))],
            selected: providerPollInterval,
            identifier: "providerPollInterval"
        )
        let pollingSpacer = NSView()
        let pollingRow = NSStackView(views: [pollingTitle, pollingSpacer, pollingPopup])
        pollingRow.orientation = .horizontal
        pollingRow.alignment = .centerY

        let activityTitle = NSTextField(labelWithString: tr("Codex 任务状态检测", "Codex Task Status Detection"))
        activityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let activityPopup = makeIntervalPopup(
            values: [(0.25, tr("0.25 秒", "0.25 sec")), (0.5, tr("0.5 秒", "0.5 sec")), (1, tr("1 秒", "1 sec"))],
            selected: activityPollInterval,
            identifier: "activityPollInterval"
        )
        let activitySpacer = NSView()
        let activityRow = NSStackView(views: [activityTitle, activitySpacer, activityPopup])
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY

        let animationToggle = makeDashboardSwitch(
            identifier: "animateCodexActivity",
            isOn: animateCodexActivity
        )
        let animationTitle = NSTextField(labelWithString: tr(
            "Codex 有任务运行时旋转菜单栏图标",
            "Rotate the menu bar icon while a Codex task is running"
        ))
        let animationSpacer = NSView()
        let animationRow = NSStackView(views: [
            animationTitle, animationSpacer, animationToggle
        ])
        animationRow.orientation = .horizontal
        animationRow.alignment = .centerY
        let note = NSTextField(wrappingLabelWithString: tr(
            "供应商变化仍由 CC Switch 数据库事件即时触发；这里的秒数只是没有收到事件时的后备检查频率。",
            "Provider changes are still triggered immediately by CC Switch database events; this interval is only the fallback check frequency."
        ))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, pollingRow, activityRow, animationRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(30, after: header)
        stack.setCustomSpacing(24, after: activityRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            pollingRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func makeIntervalPopup(
        values: [(Double, String)],
        selected: TimeInterval,
        identifier: String
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        popup.target = self
        popup.action = #selector(dashboardIntervalChanged(_:))
        for (index, value) in values.enumerated() {
            popup.addItem(withTitle: value.1)
            popup.item(at: index)?.representedObject = NSNumber(value: value.0)
            if abs(value.0 - selected) < 0.001 { popup.selectItem(at: index) }
        }
        return popup
    }

    private func makeLogsDashboardPage() -> NSView {
        let root = NSView()
        let header = makePageHeader(tr("日志", "Logs"), subtitle: tr("供应商切换、同步和失败原因", "Provider switching, synchronization, and failure details"))
        let refreshButton = NSButton(title: tr("刷新", "Refresh"), target: self, action: #selector(refreshDashboardLog))
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: tr("刷新", "Refresh"))
        let revealButton = NSButton(title: tr("在 Finder 中显示", "Show in Finder"), target: self, action: #selector(revealDashboardLog))
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: tr("在 Finder 中显示", "Show in Finder"))
        let buttonSpacer = NSView()
        let buttons = NSStackView(views: [refreshButton, revealButton, buttonSpacer])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        dashboardLogView.isEditable = false
        dashboardLogView.isSelectable = true
        dashboardLogView.isVerticallyResizable = true
        dashboardLogView.isHorizontallyResizable = false
        dashboardLogView.autoresizingMask = [.width]
        dashboardLogView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dashboardLogView.textContainerInset = NSSize(width: 10, height: 10)
        dashboardLogView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = dashboardLogView

        [header, buttons, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            buttons.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            buttons.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        return root
    }

    private func configureRefreshTimers() {
        timer?.invalidate()
        activityTimer?.invalidate()

        let providerTimer = Timer(timeInterval: providerPollInterval, repeats: true) { [weak self] _ in
            self?.refresh(reason: .scheduled)
            self?.refreshQuickSwitchSummaries(force: false)
        }
        timer = providerTimer
        RunLoop.main.add(providerTimer, forMode: .common)

        let taskTimer = Timer(timeInterval: activityPollInterval, repeats: true) { [weak self] _ in
            self?.refreshCodexActivity()
        }
        activityTimer = taskTimer
        RunLoop.main.add(taskTimer, forMode: .common)
    }

    private func startWorkspaceActivationObserver() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleFrontmostApplicationChange()
        }
    }

    private func handleFrontmostApplicationChange() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if Self.isCodexApplication(frontmost) {
            setActiveClient(.codex)
        } else if Self.isTerminalApplication(frontmost) {
            if isClaudeProcessAvailable {
                setActiveClient(.claude)
            } else {
                refreshCodexActivity()
            }
        }
    }

    private func refreshCodexActivity() {
        // Focus switching is latency-sensitive and does not need to wait for
        // transcript scanning. Use the last process result immediately.
        handleFrontmostApplicationChangeWithoutRefresh()
        guard !isActivityCheckInFlight else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsCodex = Self.isCodexApplication(frontmost)
        let frontmostIsTerminal = Self.isTerminalApplication(frontmost)
        let clientBeforeCheck = activeClient
        isActivityCheckInFlight = true
        activityMonitorQueue.async { [weak self] in
            guard let self else { return }
            var codexRunning: Bool?
            var claudeStatus: (processRunning: Bool, taskRunning: Bool)?
            if frontmostIsCodex {
                codexRunning = self.codexActivityMonitor.isTaskRunning()
            } else if frontmostIsTerminal {
                let status = self.claudeActivityMonitor.status()
                claudeStatus = status
                if !status.processRunning {
                    codexRunning = self.codexActivityMonitor.isTaskRunning()
                }
            } else if clientBeforeCheck == .codex {
                codexRunning = self.codexActivityMonitor.isTaskRunning()
            } else {
                claudeStatus = self.claudeActivityMonitor.status()
            }
            DispatchQueue.main.async {
                self.isActivityCheckInFlight = false
                if let claudeStatus {
                    if self.isClaudeProcessAvailable != claudeStatus.processRunning {
                        self.isClaudeProcessAvailable = claudeStatus.processRunning
                        SwitchLog.write(
                            "claude process availability changed; running=\(claudeStatus.processRunning)"
                        )
                    }
                }

                // Re-read the current application after the background check;
                // the user may have changed focus while it was running.
                let frontmost = NSWorkspace.shared.frontmostApplication
                if Self.isCodexApplication(frontmost) {
                    self.setActiveClient(.codex)
                } else if Self.isTerminalApplication(frontmost),
                          claudeStatus?.processRunning == true {
                    self.setActiveClient(.claude)
                }
                if let codexRunning {
                    self.setCodexTaskRunning(codexRunning)
                }
                if let claudeStatus {
                    self.setClaudeTaskRunning(claudeStatus.taskRunning)
                }
            }
        }
    }

    private func handleFrontmostApplicationChangeWithoutRefresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if Self.isCodexApplication(frontmost) {
            setActiveClient(.codex)
        } else if Self.isTerminalApplication(frontmost),
                  isClaudeProcessAvailable {
            setActiveClient(.claude)
        }
    }

    private func setCodexTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isCodexTaskRunning
        let stateChanged = running != wasRunning
        isCodexTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=codex; running=\(running)")
        }
        if activeClient == .codex {
            updateActiveUsageRefresh(running: running, wasRunning: wasRunning)
        }
        guard force || stateChanged else { return }
        updateStatusItemActivity()
    }

    private func setClaudeTaskRunning(_ running: Bool, force: Bool = false) {
        let wasRunning = isClaudeTaskRunning
        let stateChanged = running != wasRunning
        isClaudeTaskRunning = running
        if stateChanged {
            SwitchLog.write("task state changed; client=claude; running=\(running)")
        }
        if activeClient == .claude {
            updateActiveUsageRefresh(running: running, wasRunning: wasRunning)
        }
        guard force || stateChanged else { return }
        updateStatusItemActivity()
    }

    private func updateActiveUsageRefresh(running: Bool, wasRunning: Bool) {
        let now = Date()
        let stateChanged = running != wasRunning

        if running {
            postCodexRefreshDeadline = nil
        } else if stateChanged && wasRunning {
            // Third-party relays may post usage a few seconds after Codex has
            // finished. Keep a short trailing refresh window so the final
            // balance appears without requiring a manual refresh.
            postCodexRefreshDeadline = now.addingTimeInterval(postCodexRefreshDuration)
        }

        let inTrailingWindow = postCodexRefreshDeadline.map { now < $0 } ?? false
        let shouldRefreshUsage = running || inTrailingWindow || stateChanged
        let refreshIsDue = lastCodexUsageRefresh.map {
            now.timeIntervalSince($0) >= codexUsageRefreshInterval
        } ?? true
        if shouldRefreshUsage && (stateChanged || refreshIsDue) {
            lastCodexUsageRefresh = now
            refresh(reason: .activityUsage)
        } else if !shouldRefreshUsage {
            lastCodexUsageRefresh = nil
            postCodexRefreshDeadline = nil
        }
    }

    private func setActiveClient(_ client: AssistantClient) {
        guard client != activeClient else { return }
        activeClient = client
        SwitchLog.write("active client changed; client=\(client.rawValue)")
        lastProviderID = nil
        lastBalanceFetch = nil
        lastOfficialFetch = nil
        lastQuickSwitchFetch = nil
        lastOpenCodexFetch = nil
        openCodexState = nil
        openCodexCards = []
        resetOpenCodexCards()
        refreshOpenCodexMenuBar()
        openCodexSwitchInFlight = false
        lastCodexUsageRefresh = nil
        postCodexRefreshDeadline = nil
        updateStatusItemActivity()
        // Never flash the generic ellipsis during a focus switch. Reuse the
        // last successful snapshot for this client while the live refresh runs.
        // Startup prefetch normally makes this available before the first switch.
        if let cached = clientSnapshots[client],
           ccSwitchRepository.loadCurrent(appType: client.appType)?.id == cached.providerID {
            lastProviderID = cached.providerID
            render(cached.snapshot)
        }
        refresh(reason: .clientChanged)
        refreshQuickSwitchSummaries(force: true)
        if dashboard != nil {
            showDashboardSection(dashboardSection)
        }
    }

    private static func isCodexApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let name = (application.localizedName ?? "").lowercased()
        if name == "codex" { return true }
        return identifier == "com.openai.codex"
            || (identifier.contains("codex") && !identifier.contains("codexbar"))
    }

    private static func isTerminalApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let name = (application.localizedName ?? "").lowercased()
        let knownIdentifiers = [
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "dev.warp.warp-stable",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "com.github.wez.wezterm",
            "co.zeit.hyper"
        ]
        if knownIdentifiers.contains(identifier) { return true }
        return ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm"]
            .contains(where: { name.contains($0) })
    }

    private func snapshotKindDiagnosticName(_ kind: Snapshot.Kind) -> String {
        switch kind {
        case .placeholder: return "placeholder"
        case .official: return "official"
        case .balance: return "balance"
        case .openCodex: return "openCodex"
        case .error: return "error"
        }
    }

    private func openCodexCardDiagnostic(
        _ card: OpenCodexModelCard,
        index: Int
    ) -> String {
        "\(index){selector=\(card.selector),isCurrent=\(card.isCurrent),data=\(card.data.diagnosticName)}"
    }

    private func menuBarSnapshot(for snapshot: Snapshot) -> Snapshot {
        let effective = OpenCodexCardPresentation.menuBarSnapshot(
            for: snapshot,
            cards: openCodexCards
        )
        guard snapshot.kind == .openCodex else { return effective }

        let match = OpenCodexCardPresentation.menuBarCardMatch(from: openCodexCards)
        let cardSummary = openCodexCards.enumerated()
            .map { openCodexCardDiagnostic($0.element, index: $0.offset) }
            .joined(separator: ";")
        let selection = match.card?.selector ?? "none"
        let signature = [
            snapshot.unit ?? "none",
            cardSummary,
            match.diagnosticReason,
            snapshotKindDiagnosticName(effective.kind),
            effective.menuBarPrimary,
            effective.menuBarSecondary
        ].joined(separator: "|")
        SwitchLog.write(
            "OpenCodex menu bar resolution; runtime_selector=\(snapshot.unit ?? "none"); cards=[\(cardSummary)]; match=\(match.diagnosticReason); selected_selector=\(selection); effective_kind=\(snapshotKindDiagnosticName(effective.kind)); primary=\(effective.menuBarPrimary); secondary=\(effective.menuBarSecondary)",
            level: .debug,
            category: "open-codex.menu-bar",
            throttleKey: "open-codex-menu-resolution-\(signature)",
            minimumInterval: 1
        )
        return effective
    }

    private func updateDashboard(for snapshot: Snapshot, refreshDate: Date?) {
        guard dashboard?.isVisible == true else { return }
        if let currentName = ccSwitchRepository.loadChoices(appType: activeClient.appType)
            .first(where: { $0.isCurrent })?.name {
            updateDashboardCurrentProvider(currentName)
        }
        if let selectedID = dashboardSelectedProviderID,
           let choice = ccSwitchRepository.loadChoices(appType: activeClient.appType)
               .first(where: { $0.id == selectedID }) {
            dashboardProviderLabel.stringValue = choice.name
            if choice.isCurrent {
                dashboardAmountLabel.stringValue = snapshot.overviewLargeAmount
                dashboardResetLabel.stringValue = snapshot.overviewReset(
                    refreshDate: refreshDate,
                    formatter: Self.timeFormatter
                )
            } else {
                quickSwitchSummaryLock.lock()
                let cached = quickSwitchSummaries[selectedID]
                quickSwitchSummaryLock.unlock()
                dashboardAmountLabel.stringValue = cached ?? tr("正在读取…", "Loading…")
                dashboardResetLabel.stringValue = tr(
                    "选择为当前供应商后显示详细重置时间",
                    "Select this Provider to display detailed reset information"
                )
            }
        }
        rebuildDashboardProviderList()
        refreshDashboardMenuBarPage()
        refreshDashboardOpenCodexSettings()
    }

    private func updateDashboardCurrentProvider(_ name: String) {
        dashboardCurrentProviderSubtitle.stringValue = tr(
            "当前供应商：\(name)",
            "Current Provider: \(name)"
        )
    }

    private func refreshDashboardProviderRows() {
        guard dashboard != nil else { return }
        for child in dashboardProvidersStack.arrangedSubviews {
            dashboardProvidersStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        let choices = ccSwitchRepository.loadChoices(appType: activeClient.appType)
        if choices.isEmpty {
            let empty = NSTextField(labelWithString: tr("未找到 Codex 供应商", "No Codex Provider Found"))
            empty.textColor = .secondaryLabelColor
            dashboardProvidersStack.addArrangedSubview(empty)
            return
        }

        quickSwitchSummaryLock.lock()
        let summaries = quickSwitchSummaries
        quickSwitchSummaryLock.unlock()
        for (index, choice) in choices.enumerated() {
            let name = NSTextField(labelWithString: choice.name)
            name.font = .systemFont(ofSize: 13, weight: choice.isCurrent ? .semibold : .regular)
            name.lineBreakMode = .byTruncatingTail
            let summary = NSTextField(labelWithString: summaries[choice.id] ?? tr("正在读取…", "Loading…"))
            summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.alignment = .right
            summary.translatesAutoresizingMaskIntoConstraints = false
            summary.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let spacer = NSView()
            let action = NSButton(
                title: choice.isCurrent ? tr("当前", "Current") : tr("切换", "Switch"),
                target: self,
                action: #selector(dashboardSwitchProvider(_:))
            )
            action.bezelStyle = .roundRect
            action.controlSize = .small
            action.isEnabled = !choice.isCurrent
            action.identifier = NSUserInterfaceItemIdentifier(choice.id)
            action.toolTip = choice.name
            action.translatesAutoresizingMaskIntoConstraints = false
            action.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let row = NSStackView(views: [name, spacer, summary, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 34).isActive = true
            dashboardProvidersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: dashboardProvidersStack.widthAnchor).isActive = true

            if index < choices.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(equalTo: dashboardProvidersStack.widthAnchor).isActive = true
                dashboardProvidersStack.addArrangedSubview(separator)
            }
        }
    }

    private func refresh(reason: BalanceRefreshReason) {
        let client = activeClient
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let current = ccSwitchRepository.loadCurrent(appType: client.appType)
            guard let current else {
                SwitchLog.write(
                    "refresh failed; client=\(client.rawValue); current provider not found",
                    level: .error,
                    category: "provider"
                )
                self.render(.error(tr(
                    "未找到 CC Switch 当前 \(client.displayName) 供应商",
                    "The current CC Switch \(client.displayName) Provider was not found"
                )))
                return
            }

            // The Provider name is local CC Switch state, so reflect it in the
            // dashboard immediately instead of waiting for the remote balance
            // request to finish.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeClient == client else { return }
                self.updateDashboardCurrentProvider(current.name)
            }

            let switched = current.id != self.lastProviderID
            if switched {
                SwitchLog.write("provider observed; app=\(client.appType); id=\(current.id); name=\(current.name); source=database watcher/poll")
                self.lastOpenCodexFetch = nil
                self.resetOpenCodexCards()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeClient == client else { return }
                    self.openCodexState = nil
                    self.openCodexSwitchInFlight = false
                    self.openCodexCards = []
                    self.refreshOpenCodexMenuBar()
                }
            }
            self.lastProviderID = current.id
            if client == .codex, let candidate = current.openCodexCandidate {
                let due = self.lastOpenCodexFetch.map {
                    Date().timeIntervalSince($0) >= 5
                } ?? true
                guard reason.forcesStandardProviderBalance || switched || due else { return }
                self.lastOpenCodexFetch = Date()
                self.refreshOpenCodex(
                    providerID: current.id,
                    providerName: current.name,
                    candidate: candidate,
                    client: client,
                    reason: reason,
                    switched: switched
                )
                return
            }

            if client == .codex {
                self.confirmedOpenCodexCandidates.removeValue(forKey: current.id)
                self.confirmedOpenCodexStates.removeValue(forKey: current.id)
                self.resetOpenCodexCards()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.openCodexState?.providerID == current.id else { return }
                    self.openCodexState = nil
                    self.openCodexCards = []
                    self.openCodexSwitchInFlight = false
                    self.refreshOpenCodexMenuBar()
                }
            }

            self.refreshStandardProvider(
                current: current,
                client: client,
                forceBalance: reason.forcesStandardProviderBalance,
                switched: switched
            )
        }
    }

    private func refreshStandardProvider(
        current: CCSwitchProvider,
        client: AssistantClient,
        forceBalance: Bool,
        switched: Bool
    ) {
        guard let query = current.query else {
            guard current.isOfficial else {
                let failure = current.queryFailure ?? .unknown
                SwitchLog.write(
                    "balance query unavailable; client=\(client.rawValue); provider_id=\(current.id); provider=\(current.name); \(failure.diagnostic)",
                    level: .warning,
                    category: "network",
                    throttleKey: "balance-query-unavailable-\(client.rawValue)-\(current.id)-\(failure.rawValue)",
                    minimumInterval: 60
                )
                let reason = failure.userVisibleReason(
                    usesSimplifiedChinese: AppLanguage.usesSimplifiedChinese
                )
                self.renderBalanceErrorForCurrentProvider(
                    providerID: current.id,
                    providerName: current.name,
                    reason: reason,
                    client: client
                )
                return
            }
            let due = self.lastOfficialFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
            guard forceBalance || switched || due else { return }
            self.lastOfficialFetch = Date()
            SwitchLog.write(
                "quota fetch started; client=\(client.rawValue); provider=\(current.name)",
                level: .debug,
                category: "network",
                throttleKey: "quota-fetch-\(client.rawValue)-\(current.id)",
                minimumInterval: 10
            )
            self.fetchOfficialQuota(
                providerID: current.id,
                providerName: current.name,
                client: client
            )
            return
        }

        let interval = TimeInterval(max(query.intervalMinutes, 1) * 60)
        let due = self.lastBalanceFetch.map { Date().timeIntervalSince($0) >= interval } ?? true
        guard forceBalance || switched || due else { return }
        self.lastBalanceFetch = Date()
        SwitchLog.write(
            "balance fetch started; client=\(client.rawValue); provider=\(current.name)",
            level: .debug,
            category: "network",
            throttleKey: "balance-fetch-\(client.rawValue)-\(current.id)",
            minimumInterval: 10
        )
        self.fetchBalance(
            providerID: current.id,
            providerName: current.name,
            query: query,
            client: client
        )
    }

    private func refreshOpenCodex(
        providerID: String,
        providerName: String,
        candidate: OpenCodexEndpointCandidate,
        client: AssistantClient,
        reason: BalanceRefreshReason,
        switched: Bool
    ) {
        openCodexRepository.readState(for: candidate) { [weak self] result in
            guard let self else { return }
            self.monitorQueue.async {
                guard self.activeClient == client,
                      self.ccSwitchRepository.loadCurrent(appType: client.appType)?.id == providerID else { return }
                switch result {
                case .notRecognized:
                    self.confirmedOpenCodexCandidates.removeValue(forKey: providerID)
                    self.confirmedOpenCodexStates.removeValue(forKey: providerID)
                    self.resetOpenCodexCards()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.openCodexState?.providerID == providerID else { return }
                        self.openCodexState = nil
                        self.openCodexCards = []
                        self.openCodexSwitchInFlight = false
                        self.refreshOpenCodexMenuBar()
                    }
                    guard let current = self.ccSwitchRepository.loadCurrent(appType: client.appType) else { return }
                    self.refreshStandardProvider(
                        current: current,
                        client: client,
                        forceBalance: reason.forcesStandardProviderBalance,
                        switched: switched
                    )
                case .unavailable:
                    if self.confirmedOpenCodexCandidates[providerID] == candidate,
                       let previous = self.confirmedOpenCodexStates[providerID] {
                        let unavailable = self.unavailableOpenCodexState(from: previous)
                        self.confirmedOpenCodexStates[providerID] = unavailable
                        self.publishOpenCodexCardsUnavailable(
                            providerID: providerID,
                            reason: tr(
                                "OpenCodex 管理接口不可用",
                                "OpenCodex management API is unavailable"
                            )
                        )
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.openCodexState = (providerID, unavailable)
                            self.openCodexSwitchInFlight = false
                        }
                        self.renderForCurrentProvider(
                            .openCodex(
                                providerName,
                                selector: unavailable.currentSelector,
                                status: self.openCodexStatusText(for: unavailable),
                                Date()
                            ),
                            providerID: providerID,
                            client: client
                        )
                    } else {
                        self.resetOpenCodexCards()
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.openCodexState?.providerID == providerID else { return }
                            self.openCodexState = nil
                            self.openCodexCards = []
                            self.openCodexSwitchInFlight = false
                            self.refreshOpenCodexMenuBar()
                        }
                        guard let current = self.ccSwitchRepository.loadCurrent(appType: client.appType) else { return }
                        self.refreshStandardProvider(
                            current: current,
                            client: client,
                            forceBalance: reason.forcesStandardProviderBalance,
                            switched: switched
                        )
                    }
                case .recognized(let state):
                    self.confirmedOpenCodexCandidates[providerID] = candidate
                    self.confirmedOpenCodexStates[providerID] = state
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.openCodexState = (providerID, state)
                        self.openCodexSwitchInFlight = false
                    }
                    self.prepareOpenCodexCards(
                        providerID: providerID,
                        state: state,
                        force: reason.forcesOpenCodexCardSources || switched
                    )
                    self.renderForCurrentProvider(
                        .openCodex(
                            providerName,
                            selector: state.currentSelector,
                            status: self.openCodexStatusText(for: state),
                            Date()
                        ),
                        providerID: providerID,
                        client: client
                    )
                }
            }
        }
    }

    private func resetOpenCodexCards() {
        openCodexCardPlans = []
        openCodexCardData = [:]
        openCodexCardRefreshCoordinator.reset()
        openCodexCardRequestsInFlight.removeAll()
    }

    private func prepareOpenCodexCards(
        providerID: String,
        state: OpenCodexRuntimeState,
        force: Bool = false
    ) {
        let sources = ccSwitchRepository.loadSummarySources(appType: AssistantClient.codex.appType)
        let plans = OpenCodexCardPlanner.plans(state: state, sources: sources)
        let refreshSources = makeOpenCodexCardRefreshSources(
            plans: plans,
            state: state,
            sources: sources
        )
        let refreshPlan = openCodexCardRefreshCoordinator.plan(
            sources: refreshSources,
            now: Date(),
            force: force,
            allowRequests: state.managementAvailable,
            inFlight: openCodexCardRequestsInFlight
        )
        let inFlightBefore = openCodexCardRequestsInFlight
            .map(\.diagnosticName)
            .sorted()
            .joined(separator: ",")
        let activeSources = Set(refreshSources.map(\OpenCodexCardRefreshSource.source))
        openCodexCardRequestsInFlight.formIntersection(activeSources)
        openCodexCardRequestsInFlight.subtract(refreshPlan.configurationChanged)
        let plannedSources = refreshSources
            .map { $0.source.diagnosticName }
            .joined(separator: ",")
        let dueSources = refreshPlan.dueSources
            .map { $0.source.diagnosticName }
            .joined(separator: ",")
        let changedSources = refreshPlan.configurationChanged
            .map(\.diagnosticName)
            .sorted()
            .joined(separator: ",")
        let inFlightAfter = openCodexCardRequestsInFlight
            .map(\.diagnosticName)
            .sorted()
            .joined(separator: ",")
        SwitchLog.write(
            "OpenCodex card refresh plan; provider_id=\(providerID); current_selector=\(state.currentSelector ?? "none"); management=\(state.managementAvailable); force=\(force); planned=[\(plannedSources)]; due=[\(dueSources)]; configuration_changed=[\(changedSources)]; in_flight_before=[\(inFlightBefore)]; in_flight_after=[\(inFlightAfter)]",
            level: .debug,
            category: "open-codex.coordinator",
            throttleKey: "open-codex-plan-\(providerID)-\(plannedSources)-\(dueSources)-\(changedSources)-\(inFlightAfter)",
            minimumInterval: 1
        )
        openCodexCardPlans = plans
        var nextData: [OpenCodexCardSource: OpenCodexCardData] = [:]
        for plan in plans {
            switch plan.source {
            case .unavailable:
                continue
            default:
                if let cached = openCodexCardRefreshCoordinator.visibleData(for: plan.source) {
                    nextData[plan.source] = cached
                } else if state.managementAvailable {
                    nextData[plan.source] = .loading(category: plan.source.category)
                } else {
                    nextData[plan.source] = .unavailable(
                        category: plan.source.category,
                        reason: tr(
                            "OpenCodex 管理接口不可用",
                            "OpenCodex management API is unavailable"
                        )
                    )
                }
            }
        }
        openCodexCardData = nextData
        publishOpenCodexCards(providerID: providerID, plans: plans)

        guard state.managementAvailable else { return }
        for refreshSource in refreshPlan.dueSources {
            let source = refreshSource.source
            guard let generation = openCodexCardRefreshCoordinator.generation(for: source) else {
                SwitchLog.write(
                    "OpenCodex card request skipped; provider_id=\(providerID); source=\(source.diagnosticName); reason=missing-generation",
                    level: .warning,
                    category: "open-codex.coordinator"
                )
                continue
            }
            openCodexCardRequestsInFlight.insert(source)
            SwitchLog.write(
                "OpenCodex card request started; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); in_flight=\(openCodexCardRequestsInFlight.map(\.diagnosticName).sorted().joined(separator: ","))",
                level: .debug,
                category: "open-codex.request"
            )
            switch source {
            case .official:
                fetchOpenCodexOfficialCard(
                    providerID: providerID,
                    generation: generation
                )
            case .balance(let sourceID):
                guard let summary = sources.first(where: { $0.id == sourceID }),
                      let query = summary.query else {
                    SwitchLog.write(
                        "OpenCodex balance card request completed; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); result=unavailable/balance; reason=missing-query",
                        level: .warning,
                        category: "open-codex.request"
                    )
                    updateOpenCodexCard(
                        providerID: providerID,
                        generation: generation,
                        source: source,
                        data: .unavailable(
                            category: .balance,
                            reason: tr(
                                "余额来源配置不完整",
                                "The balance source configuration is incomplete"
                            )
                        )
                    )
                    continue
                }
                let requestStartedAt = Date()
                let transportStarted = balanceAPIClient.fetchBalance(
                    query: query,
                    client: .codex,
                    providerID: "opencodex-card:\(sourceID)"
                ) { [weak self] result in
                    guard let self else { return }
                    let data: OpenCodexCardData
                    switch result {
                    case .success(let response):
                        data = .balance(
                            amount: response.output.amount,
                            unit: response.output.unit,
                            websiteURL: Self.secureOpenCodexWebsiteURL(
                                summary.websiteURL ?? query.websiteURL
                            ),
                            updatedAt: Date()
                        )
                    case .failure(.nonHTTPS):
                        data = .unavailable(
                            category: .balance,
                            reason: tr(
                                "余额不可用：余额接口不是 HTTPS",
                                "Balance unavailable: the balance endpoint is not HTTPS"
                            )
                        )
                    default:
                        data = .unavailable(
                            category: .balance,
                            reason: tr(
                                "余额不可用：无法读取上游余额",
                                "Balance unavailable: the upstream balance could not be read"
                            )
                        )
                    }
                    SwitchLog.write(
                        "OpenCodex balance card request completed; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); result=\(data.diagnosticName); duration=\(String(format: "%.3f", Date().timeIntervalSince(requestStartedAt)))s",
                        level: data.isSuccessful ? .debug : .warning,
                        category: "open-codex.request"
                    )
                    self.monitorQueue.async {
                        self.updateOpenCodexCard(
                            providerID: providerID,
                            generation: generation,
                            source: source,
                            data: data
                        )
                    }
                }
                SwitchLog.write(
                    "OpenCodex balance card request registered; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); transport_started=\(transportStarted)",
                    level: .debug,
                    category: "open-codex.request"
                )
            case .unavailable:
                openCodexCardRequestsInFlight.remove(source)
                continue
            }
        }
    }

    private func makeOpenCodexCardRefreshSources(
        plans: [OpenCodexCardPlan],
        state: OpenCodexRuntimeState,
        sources: [ProviderSummarySource]
    ) -> [OpenCodexCardRefreshSource] {
        var result: [OpenCodexCardRefreshSource] = []
        var seen = Set<OpenCodexCardSource>()

        for plan in plans {
            guard seen.insert(plan.source).inserted else { continue }
            switch plan.source {
            case .official:
                result.append(
                    OpenCodexCardRefreshSource(
                        source: .official,
                        interval: 60,
                        configurationFingerprint: officialOpenCodexCardFingerprint(
                            plans: plans,
                            state: state,
                            sources: sources
                        )
                    )
                )
            case .balance(let sourceID):
                guard let summary = sources.first(where: { $0.id == sourceID }),
                      let query = summary.query else { continue }
                result.append(
                    OpenCodexCardRefreshSource(
                        source: plan.source,
                        interval: TimeInterval(max(query.intervalMinutes, 1) * 60),
                        configurationFingerprint: balanceOpenCodexCardFingerprint(
                            summary: summary,
                            query: query,
                            state: state,
                            plans: plans
                        )
                    )
                )
            case .unavailable:
                continue
            }
        }
        return result
    }

    private func officialOpenCodexCardFingerprint(
        plans: [OpenCodexCardPlan],
        state: OpenCodexRuntimeState,
        sources: [ProviderSummarySource]
    ) -> String {
        let providerFingerprint = plans.compactMap { plan in
            guard let descriptor = state.providers[plan.provider], descriptor.isOfficial else {
                return nil
            }
            return openCodexProviderFingerprint(descriptor)
        }.joined(separator: ";")
        let sourceFingerprint = sources.filter(\.isOfficial).map {
            [
                $0.id,
                $0.name,
                $0.websiteURL?.absoluteString ?? "",
                $0.officialAccessToken.map { String($0.hashValue) } ?? "missing"
            ].joined(separator: "|")
        }.joined(separator: ";")
        return "official:\(providerFingerprint):\(sourceFingerprint)"
    }

    private func balanceOpenCodexCardFingerprint(
        summary: ProviderSummarySource,
        query: BalanceQuery,
        state: OpenCodexRuntimeState,
        plans: [OpenCodexCardPlan]
    ) -> String {
        let providerFingerprint = plans.compactMap { plan in
            guard case .balance(let sourceID) = plan.source,
                  sourceID == summary.id,
                  let descriptor = state.providers[plan.provider] else { return nil }
            return openCodexProviderFingerprint(descriptor)
        }.joined(separator: ";")
        let headerNames = query.additionalHeaders.keys.sorted().joined(separator: ",")
        return [
            summary.id,
            summary.name,
            query.url,
            String(query.intervalMinutes),
            summary.websiteURL?.absoluteString ?? query.websiteURL?.absoluteString ?? "",
            String(query.apiKey.hashValue),
            headerNames,
            String(query.isRightCode),
            query.subscriptionPrefix,
            String(query.isNewAPI),
            String(describing: query.nativeBalanceProvider),
            providerFingerprint
        ].joined(separator: "|")
    }

    private func openCodexProviderFingerprint(
        _ descriptor: OpenCodexProviderDescriptor
    ) -> String {
        [
            descriptor.id,
            descriptor.adapter,
            descriptor.authMode,
            descriptor.baseURL.absoluteString,
            descriptor.defaultModel ?? "",
            descriptor.models.joined(separator: ","),
            String(descriptor.isOfficial)
        ].joined(separator: "|")
    }

    private func fetchOpenCodexOfficialCard(
        providerID: String,
        generation: UUID
    ) {
        let requestStartedAt = Date()
        officialQuotaClient.fetchQuota(
            client: .codex,
            providerID: providerID,
            storedAccessToken: nil
        ) { [weak self] result in
            guard let self else { return }
            let cardData: OpenCodexCardData
            let status: Int
            let dataSize: Int
            let transportError: Bool
            switch result {
            case .success(let response):
                let quota = response.output
                cardData = .official(
                    remaining: quota.remaining,
                    label: quota.label,
                    reset: quota.reset,
                    updatedAt: Date()
                )
                status = 200
                dataSize = response.dataSize
                transportError = false
            case .failure(.missingCredentials):
                cardData = .unavailable(
                    category: .quota,
                    reason: tr(
                        "额度不可用：未找到官方登录态",
                        "Quota unavailable: official sign-in credentials were not found"
                    )
                )
                status = -1
                dataSize = 0
                transportError = false
            case .failure(.httpStatus(let statusCode, let responseSize)):
                cardData = .unavailable(
                    category: .quota,
                    reason: tr(
                        "额度不可用：官方额度接口暂时不可用",
                        "Quota unavailable: the official quota endpoint is temporarily unavailable"
                    )
                )
                status = statusCode
                dataSize = responseSize
                transportError = false
            case .failure(.transport(_)):
                cardData = .unavailable(
                    category: .quota,
                    reason: tr(
                        "额度不可用：官方额度接口暂时不可用",
                        "Quota unavailable: the official quota endpoint is temporarily unavailable"
                    )
                )
                status = -1
                dataSize = 0
                transportError = true
            case .failure(.invalidJSON(let responseSize)),
                 .failure(.unsupportedFormat(let responseSize)):
                cardData = .unavailable(
                    category: .quota,
                    reason: tr(
                        "额度不可用：官方额度接口暂时不可用",
                        "Quota unavailable: the official quota endpoint is temporarily unavailable"
                    )
                )
                status = 200
                dataSize = responseSize
                transportError = false
            }
            SwitchLog.write(
                "OpenCodex official card request completed; provider_id=\(providerID); source=official; generation=\(generation.uuidString); result=\(cardData.diagnosticName); status=\(status); bytes=\(dataSize); transport_error=\(transportError); duration=\(String(format: "%.3f", Date().timeIntervalSince(requestStartedAt)))s",
                level: cardData.isSuccessful ? .debug : .warning,
                category: "open-codex.request"
            )
            self.monitorQueue.async {
                self.updateOpenCodexCard(
                    providerID: providerID,
                    generation: generation,
                    source: .official,
                    data: cardData
                )
            }
        }
    }

    private func publishOpenCodexCards(
        providerID: String,
        plans: [OpenCodexCardPlan]
    ) {
        let cards = OpenCodexCardPlanner.cards(
            plans: plans,
            data: openCodexCardData
        )
        let cardSummary = cards.enumerated()
            .map { index, card in
                let source = plans.indices.contains(index)
                    ? plans[index].source.diagnosticName
                    : "unknown"
                return "\(openCodexCardDiagnostic(card, index: index));source=\(source)"
            }
            .joined(separator: ";")
        SwitchLog.write(
            "OpenCodex cards publish prepared; provider_id=\(providerID); cards=[\(cardSummary)]",
            level: .debug,
            category: "open-codex.publish",
            throttleKey: "open-codex-publish-\(providerID)-\(cardSummary)",
            minimumInterval: 1
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.activeClient == .codex,
                  self.openCodexState?.providerID == providerID else {
                SwitchLog.write(
                    "OpenCodex cards publish discarded on main; provider_id=\(providerID); active_client=\(self.activeClient.rawValue); state_provider_id=\(self.openCodexState?.providerID ?? "none")",
                    level: .warning,
                    category: "open-codex.publish"
                )
                return
            }
            self.openCodexCards = cards
            if self.snapshot.kind == .openCodex {
                self.refreshOpenCodexMenuBar()
            }
        }
    }

    private func refreshOpenCodexMenuBar() {
        guard snapshot.kind == .openCodex else { return }
        SwitchLog.write(
            "OpenCodex menu bar refresh requested after card publish; card_count=\(openCodexCards.count); snapshot_selector=\(snapshot.unit ?? "none")",
            level: .debug,
            category: "open-codex.menu-bar",
            throttleKey: "open-codex-menu-refresh-\(snapshot.unit ?? "none")-\(openCodexCards.map { $0.data.diagnosticName }.joined(separator: ","))",
            minimumInterval: 1
        )
        updateStatusItem(for: snapshot)
    }

    private func updateOpenCodexCard(
        providerID: String,
        generation: UUID,
        source: OpenCodexCardSource,
        data: OpenCodexCardData
    ) {
        guard let currentGeneration = openCodexCardRefreshCoordinator.generation(for: source) else {
            SwitchLog.write(
                "OpenCodex card completion discarded; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); result=\(data.diagnosticName); reason=source-removed",
                level: .warning,
                category: "open-codex.coordinator"
            )
            return
        }
        guard currentGeneration == generation else {
            SwitchLog.write(
                "OpenCodex card completion discarded; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); current_generation=\(currentGeneration.uuidString); result=\(data.diagnosticName); reason=stale-generation",
                level: .warning,
                category: "open-codex.coordinator"
            )
            return
        }
        guard let visibleData = openCodexCardRefreshCoordinator.store(
            data,
            for: source,
            generation: generation
        ) else {
            SwitchLog.write(
                "OpenCodex card completion discarded; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); result=\(data.diagnosticName); reason=store-rejected",
                level: .warning,
                category: "open-codex.coordinator"
            )
            return
        }
        openCodexCardRequestsInFlight.remove(source)
        openCodexCardData[source] = visibleData
        SwitchLog.write(
            "OpenCodex card completion accepted; provider_id=\(providerID); source=\(source.diagnosticName); generation=\(generation.uuidString); incoming=\(data.diagnosticName); visible=\(visibleData.diagnosticName); in_flight=\(openCodexCardRequestsInFlight.map(\.diagnosticName).sorted().joined(separator: ","))",
            level: .debug,
            category: "open-codex.coordinator"
        )
        publishOpenCodexCards(
            providerID: providerID,
            plans: openCodexCardPlans
        )
    }

    private func publishOpenCodexCardsUnavailable(
        providerID: String,
        reason: String
    ) {
        for plan in openCodexCardPlans {
            switch plan.source {
            case .unavailable:
                continue
            default:
                if let cached = openCodexCardRefreshCoordinator.visibleData(for: plan.source) {
                    openCodexCardData[plan.source] = cached
                } else {
                    openCodexCardData[plan.source] = .unavailable(
                        category: plan.source.category,
                        reason: reason
                    )
                }
            }
        }
        publishOpenCodexCards(
            providerID: providerID,
            plans: openCodexCardPlans
        )
    }

    private func openCodexStatusText(for state: OpenCodexRuntimeState) -> String {
        if !state.managementAvailable {
            return tr(
                "管理接口不可用，等待 OpenCodex 恢复",
                "Management API unavailable; waiting for OpenCodex"
            )
        }
        if !state.preferenceDataAvailable {
            return tr(
                "暂未读取到 OpenCodex 偏好",
                "OpenCodex preferences are not available yet"
            )
        }
        if state.preferences.isEmpty {
            return tr(
                "没有配置 OpenCodex 子项",
                "No OpenCodex preferences configured"
            )
        }
        if let current = state.currentSelector {
            return tr("当前：\(current)", "Current: \(current)")
        }
        return tr(
            "已读取 OpenCodex 偏好",
            "OpenCodex preferences loaded"
        )
    }

    private func unavailableOpenCodexState(
        from state: OpenCodexRuntimeState
    ) -> OpenCodexRuntimeState {
        OpenCodexRuntimeState(
            candidate: state.candidate,
            defaultProvider: state.defaultProvider,
            providerDefaultModels: state.providerDefaultModels,
            providers: state.providers,
            chosenSelectors: state.chosenSelectors,
            availableSelectors: state.availableSelectors,
            preferences: state.preferences,
            managementAvailable: false,
            preferenceDataAvailable: state.preferenceDataAvailable
        )
    }

    private func prefetchCurrentBalance(for client: AssistantClient) {
        monitorQueue.async { [weak self] in
            guard let self,
                  let current = ccSwitchRepository.loadCurrent(appType: client.appType)
            else { return }

            if client == .codex,
               let candidate = current.openCodexCandidate,
               self.confirmedOpenCodexCandidates[current.id] == candidate {
                return
            }

            if let query = current.query {
                SwitchLog.write(
                    "balance prefetch started; client=\(client.rawValue); provider=\(current.name)",
                    level: .debug,
                    category: "network",
                    throttleKey: "balance-prefetch-\(client.rawValue)-\(current.id)",
                    minimumInterval: 10
                )
                self.fetchBalance(
                    providerID: current.id,
                    providerName: current.name,
                    query: query,
                    client: client
                )
            } else if current.isOfficial, client != .claude {
                SwitchLog.write(
                    "quota prefetch started; client=\(client.rawValue); provider=\(current.name)",
                    level: .debug,
                    category: "network",
                    throttleKey: "quota-prefetch-\(client.rawValue)-\(current.id)",
                    minimumInterval: 10
                )
                self.fetchOfficialQuota(
                    providerID: current.id,
                    providerName: current.name,
                    client: client
                )
            }
        }
    }

    private func startDatabaseWatchers() {
        // SQLite commits usually update the WAL file; watching both the main DB
        // and its WAL gives near-instant provider-switch detection.
        let databasePath = ccSwitchRepository.databaseURL.path
        let ccSwitchDirectory = ccSwitchRepository.databaseURL.deletingLastPathComponent().path
        let paths = [databasePath, "\(databasePath)-wal", ccSwitchDirectory]
        databaseWatchers = paths.compactMap { makeWatcher(for: $0) }
    }

    private func makeWatcher(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: monitorQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleImmediateSync()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleImmediateSync() {
        syncWorkItem?.cancel()
        SwitchLog.write(
            "CC Switch database change observed; coalescing refresh",
            level: .debug,
            category: "database",
            throttleKey: "database-change",
            minimumInterval: 2
        )
        let workItem = DispatchWorkItem { [weak self] in
            // A CC Switch database write may represent either a Provider
            // switch or a credential/configuration update. Bypass the normal
            // provider interval so the menu follows it immediately.
            self?.refresh(reason: .configurationChanged)
            self?.refreshQuickSwitchSummaries(force: true)
        }
        syncWorkItem = workItem
        // CC Switch commits several SQLite/WAL writes per action. Coalesce
        // them, while keeping the post-switch refresh visually immediate.
        monitorQueue.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    private func refreshQuickSwitchSummaries(
        force: Bool,
        for requestedClient: AssistantClient? = nil
    ) {
        let client = requestedClient ?? activeClient
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let due = self.lastQuickSwitchFetch.map { Date().timeIntervalSince($0) >= 60 } ?? true
            guard force || due else { return }
            self.lastQuickSwitchFetch = Date()

            for source in ccSwitchRepository.loadSummarySources(appType: client.appType) {
                if client == .codex,
                   let candidate = source.openCodexCandidate,
                   self.confirmedOpenCodexCandidates[source.id] == candidate {
                    continue
                }
                if source.isOfficial {
                    // Avoid querying the macOS Keychain merely to decorate the
                    // quick-switch list. Official Claude quota is still loaded
                    // when it is the current Provider.
                    if client == .claude { continue }
                    self.officialQuotaClient.fetchQuota(
                        client: client,
                        providerID: source.id,
                        storedAccessToken: source.officialAccessToken
                    ) { [weak self] result in
                        guard let self, case .success(let response) = result else { return }
                        self.updateQuickSwitchSummary(
                            providerID: source.id,
                            text: "\(Int(response.output.remaining))% / \(response.output.daysText)"
                        )
                    }
                    continue
                }

                guard let query = source.query else { continue }
                self.balanceAPIClient.fetchBalance(
                    query: query,
                    client: client,
                    providerID: source.id,
                    completion: { [weak self] result in
                        guard let self,
                              case .success(let response) = result else { return }
                        self.updateQuickSwitchSummary(
                            providerID: source.id,
                            text: Self.formatBalanceSummary(
                                response.output.amount,
                                unit: response.output.unit
                            )
                        )
                    }
                )
            }
        }
    }

    private func updateQuickSwitchSummary(providerID: String, text: String) {
        quickSwitchSummaryLock.lock()
        let previous = quickSwitchSummaries[providerID]
        guard previous != text else {
            quickSwitchSummaryLock.unlock()
            return
        }
        quickSwitchSummaries[providerID] = text
        quickSwitchSummaryLock.unlock()
        SwitchLog.write(
            "quick-switch balance changed; provider_id=\(providerID); value=\(text)",
            category: "balance"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItemController.updateMenu(input: self.makeStatusItemMenuInput())
            self.rebuildDashboardProviderList()
            self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot))
        }
    }

    private static func formatBalanceSummary(_ amount: Double, unit: String) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(2)))
        switch unit.uppercased() {
        case "USD":
            return "$\(number)"
        case "CNY", "CNH", "RMB":
            return "¥\(number)"
        default:
            return "\(number) \(unit)"
        }
    }

    private static func secureOpenCodexWebsiteURL(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              host != "localhost",
              host != "::1",
              !(host == "127.0.0.1" || host.hasPrefix("127.")) else {
            return nil
        }
        return url
    }

    private static func localizedBalanceNetworkErrorReason(
        _ error: Error,
        usesSimplifiedChinese: Bool
    ) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return usesSimplifiedChinese ? "网络请求失败" : "Network request failed"
        }

        let messages: (simplifiedChinese: String, english: String)
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            messages = ("网络请求超时", "Network request timed out")
        case .notConnectedToInternet:
            messages = ("无网络连接", "No internet connection")
        case .networkConnectionLost:
            messages = ("网络连接已中断", "Network connection was lost")
        case .cannotFindHost:
            messages = ("找不到主机", "Host could not be found")
        case .cannotConnectToHost:
            messages = ("无法连接主机", "Could not connect to host")
        case .secureConnectionFailed:
            messages = ("安全连接失败", "Secure connection failed")
        default:
            messages = ("网络请求失败", "Network request failed")
        }
        return usesSimplifiedChinese ? messages.simplifiedChinese : messages.english
    }

    private func fetchBalance(
        providerID: String,
        providerName: String,
        query: BalanceQuery,
        client: AssistantClient
    ) {
        let requestStartedAt = Date()
        guard balanceAPIClient.fetchBalance(
            query: query,
            client: client,
            providerID: providerID,
            completion: { [weak self] result in
                guard let self else { return }
                let duration = Date().timeIntervalSince(requestStartedAt)
                switch result {
                case .success(let response):
                    let output = response.output
                    SwitchLog.write(
                        "balance request succeeded; client=\(client.rawValue); provider=\(providerName); amount=\(output.amount); unit=\(output.unit); bytes=\(response.dataSize); duration=\(String(format: "%.3f", duration))s",
                        level: .debug,
                        category: "network",
                        throttleKey: "balance-success-\(client.rawValue)-\(providerID)",
                        minimumInterval: 10
                    )
                    self.updateQuickSwitchSummary(
                        providerID: providerID,
                        text: Self.formatBalanceSummary(output.amount, unit: output.unit)
                    )
                    self.renderForCurrentProvider(
                        .balance(
                            providerName,
                            output.amount,
                            output.unit,
                            query.websiteURL,
                            Date()
                        ),
                        providerID: providerID,
                        client: client
                    )
                case .failure(.nonHTTPS):
                    SwitchLog.write(
                        "balance request rejected; client=\(client.rawValue); provider=\(providerName); reason=non-HTTPS endpoint",
                        level: .error,
                        category: "network"
                    )
                    self.renderBalanceErrorForCurrentProvider(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr("余额接口不是 HTTPS", "The balance endpoint is not HTTPS"),
                        client: client
                    )
                case .failure(.transport(let error)):
                    SwitchLog.write(
                        "balance request failed; client=\(client.rawValue); provider=\(providerName); duration=\(String(format: "%.3f", duration))s; error=\(error.localizedDescription)",
                        level: .error,
                        category: "network"
                    )
                    let reason = Self.localizedBalanceNetworkErrorReason(
                        error,
                        usesSimplifiedChinese: AppLanguage.usesSimplifiedChinese
                    )
                    self.renderBalanceErrorForCurrentProvider(
                        providerID: providerID,
                        providerName: providerName,
                        reason: reason,
                        client: client
                    )
                case .failure(.httpStatus(let status)):
                    SwitchLog.write(
                        "balance request failed; client=\(client.rawValue); provider=\(providerName); status=\(status); duration=\(String(format: "%.3f", duration))s",
                        level: .error,
                        category: "network"
                    )
                    self.renderBalanceErrorForCurrentProvider(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr("余额接口返回异常", "The balance endpoint returned an error"),
                        client: client
                    )
                case .failure(.unsupportedFormat(let dataSize)):
                    SwitchLog.write(
                        "balance parse failed; client=\(client.rawValue); provider=\(providerName); bytes=\(dataSize); duration=\(String(format: "%.3f", duration))s",
                        level: .error,
                        category: "parsing"
                    )
                    self.renderBalanceErrorForCurrentProvider(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr("未识别余额格式", "Unrecognized balance format"),
                        client: client
                    )
                case .failure(.invalidJSON(let dataSize, let underlying)):
                    SwitchLog.write(
                        "balance JSON decode failed; client=\(client.rawValue); provider=\(providerName); bytes=\(dataSize); duration=\(String(format: "%.3f", duration))s; error=\(underlying.localizedDescription)",
                        level: .error,
                        category: "parsing"
                    )
                    self.renderBalanceErrorForCurrentProvider(
                        providerID: providerID,
                        providerName: providerName,
                        reason: tr("余额响应无法解析", "The balance response could not be parsed"),
                        client: client
                    )
                }
            }
        ) else {
            // A request for this client/provider key is already in flight;
            // BalanceAPIClient intentionally suppresses the duplicate.
            return
        }
    }

    private func fetchOfficialQuota(
        providerID: String,
        providerName: String,
        client: AssistantClient
    ) {
        let requestStartedAt = Date()
        officialQuotaClient.fetchQuota(
            client: client,
            providerID: providerID
        ) { [weak self] result in
            guard let self else { return }
            let duration = Date().timeIntervalSince(requestStartedAt)
            switch result {
            case .failure(.missingCredentials):
                SwitchLog.write(
                    "official quota request unavailable; client=\(client.rawValue); provider=\(providerName); reason=missing local credentials",
                    level: .error,
                    category: "authentication"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：未找到本机登录态",
                    "Official \(client.displayName): Local sign-in credentials were not found"
                )), providerID: providerID, client: client)
            case .failure(.transport(let error)):
                SwitchLog.write(
                    "official quota request failed; client=\(client.rawValue); provider=\(providerName); duration=\(String(format: "%.3f", duration))s; error=\(error.localizedDescription)",
                    level: .error,
                    category: "network"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：\(error.localizedDescription)",
                    "Official \(client.displayName): \(error.localizedDescription)"
                )), providerID: providerID, client: client)
            case .failure(.httpStatus(let status, let dataSize)):
                SwitchLog.write(
                    "official quota request failed; client=\(client.rawValue); provider=\(providerName); status=\(status); bytes=\(dataSize); duration=\(String(format: "%.3f", duration))s",
                    level: .error,
                    category: "network"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：额度接口返回异常",
                    "Official \(client.displayName): The quota endpoint returned an error"
                )), providerID: providerID, client: client)
            case .failure(.invalidJSON(let dataSize)):
                SwitchLog.write(
                    "official quota request failed; client=\(client.rawValue); provider=\(providerName); status=200; bytes=\(dataSize); duration=\(String(format: "%.3f", duration))s",
                    level: .error,
                    category: "network"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：额度接口返回异常",
                    "Official \(client.displayName): The quota endpoint returned an error"
                )), providerID: providerID, client: client)
            case .failure(.unsupportedFormat(let dataSize)):
                SwitchLog.write(
                    "official quota parse failed; client=\(client.rawValue); provider=\(providerName); bytes=\(dataSize); duration=\(String(format: "%.3f", duration))s",
                    level: .error,
                    category: "parsing"
                )
                self.renderForCurrentProvider(.error(tr(
                    "\(client.displayName) 官方账号：未识别额度格式",
                    "Official \(client.displayName): Unrecognized quota format"
                )), providerID: providerID, client: client)
            case .success(let response):
                let quota = response.output
                SwitchLog.write(
                    "official quota request succeeded; client=\(client.rawValue); provider=\(providerName); remaining=\(quota.remaining); label=\(quota.label); duration=\(String(format: "%.3f", duration))s",
                    level: .debug,
                    category: "network",
                    throttleKey: "quota-success-\(client.rawValue)-\(providerID)",
                    minimumInterval: 10
                )
                self.updateQuickSwitchSummary(providerID: providerID, text: "\(Int(quota.remaining))% / \(quota.daysText)")
                self.renderForCurrentProvider(
                    .official(providerName, quota.remaining, quota.label, quota.reset, Date()),
                    providerID: providerID,
                    client: client
                )
            }
        }
    }

    private func renderForCurrentProvider(
        _ next: Snapshot,
        providerID: String,
        client: AssistantClient
    ) {
        monitorQueue.async { [weak self] in
            guard let self,
                  ccSwitchRepository.loadCurrent(appType: client.appType)?.id == providerID
            else { return }
            if next.kind == .balance {
                self.providerBalanceSnapshots.store(
                    next,
                    clientID: client.rawValue,
                    providerID: providerID
                )
            }
            DispatchQueue.main.async {
                switch next.kind {
                case .official, .balance:
                    self.clientSnapshots[client] = (providerID, next)
                case .placeholder, .openCodex, .error:
                    break
                }
                guard self.activeClient == client,
                      self.lastProviderID == providerID else { return }
                SwitchLog.write(
                    "balance render completed; client=\(client.rawValue); provider_id=\(providerID); kind=\(next.kind)",
                    level: .debug,
                    category: "render",
                    throttleKey: "render-\(client.rawValue)-\(providerID)-\(next.kind)",
                    minimumInterval: 10
                )
                self.render(next)
            }
        }
    }

    private func renderBalanceErrorForCurrentProvider(
        providerID: String,
        providerName: String,
        reason: String,
        client: AssistantClient
    ) {
        monitorQueue.async { [weak self] in
            guard let self,
                  ccSwitchRepository.loadCurrent(appType: client.appType)?.id == providerID
            else { return }
            let next = self.providerBalanceSnapshots.errorSnapshot(
                clientID: client.rawValue,
                providerID: providerID,
                providerName: providerName,
                reason: reason
            )
            DispatchQueue.main.async {
                guard self.activeClient == client,
                      self.lastProviderID == providerID else { return }
                self.render(next)
            }
        }
    }

    private func render(_ next: Snapshot) {
        DispatchQueue.main.async {
            self.snapshot = next
            self.activeProviderWebsite = next.websiteURL
            if next.kind != .error, next.kind != .placeholder { self.lastSuccessfulRefresh = next.date }
            self.updateStatusItem(for: next)
            let refreshDate = self.refreshDate(for: next)
            self.updateDashboard(for: next, refreshDate: refreshDate)
        }
    }

    private func refreshDate(for snapshot: Snapshot) -> Date? {
        if snapshot.kind == .error, !snapshot.provider.isEmpty {
            return snapshot.date
        }
        return lastSuccessfulRefresh ?? snapshot.date
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@main
enum BalanceBarMain {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApplication.shared.run()
            return
        }
        migrateLegacyPreferencesIfNeeded()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? productionBundleIdentifier
        let duplicate = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).contains { $0.processIdentifier != currentPID }
        if duplicate {
            NSLog("BalanceBar: refusing duplicate instance; pid=%d", currentPID)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

// Layout rules for the balance error overview card. The error detail must be
// readable in full without truncation. Normal English words stay whole (word
// wrapping); only over-wide unbreakable tokens such as URLs or continuous
// error codes get character-level break opportunities so they cannot overflow.
// The detail occupies the balance card's left column so the amount placeholder
// can remain in the right column without overlap. Kept as a small pure helper
// so the probe can verify wrapping and overlap headlessly.
enum ErrorCardLayout {
    static let cardWidth: CGFloat = 304
    static let horizontalInset: CGFloat = 14
    static let contentWidth: CGFloat = cardWidth - horizontalInset * 2
    static let detailWidth: CGFloat = 128
    static let amountWidth: CGFloat = 141
    static let amountX: CGFloat = cardWidth - horizontalInset - amountWidth
    static let refreshTimeWidth: CGFloat = 81
    static let refreshTimeX: CGFloat = cardWidth - horizontalInset - refreshTimeWidth

    // Match the compact third-party balance card for a single-line error.
    static let minimumCardHeight: CGFloat = 86
    static let singleLineDetailHeight: CGFloat = 17

    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let quotaFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let detailFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
    static let refreshTimeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    struct ErrorFrames {
        let cardSize: NSSize
        let title: NSRect
        let refreshTime: NSRect
        let quotaDetail: NSRect
        let amount: NSRect
        let detail: NSRect
        let detailText: String
    }

    /// Prepares the detail text for word wrapping. Whitespace-delimited tokens
    /// that fit on one line are left untouched, so normal English words stay
    /// whole. Tokens wider than `width` (URLs, continuous error codes, long
    /// unbroken runs) get a zero-width space between every character so they
    /// always have safe break points and can never overflow or be truncated.
    static func detailText(for message: String, width: CGFloat) -> String {
        guard !message.isEmpty else { return message }
        var result = ""
        var token = ""
        for character in message {
            if character.isWhitespace {
                result += wrapIfNeeded(token, width: width)
                result.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        result += wrapIfNeeded(token, width: width)
        return result
    }

    private static func wrapIfNeeded(_ token: String, width: CGFloat) -> String {
        guard !token.isEmpty else { return token }
        let tokenWidth = (token as NSString).size(withAttributes: [.font: detailFont]).width
        guard tokenWidth > width else { return token }
        return token.map(String.init).joined(separator: "\u{200B}")
    }

    /// Minimum height that renders the full `message` at `width` using word
    /// wrapping on the break-opportunity text from `detailText(for:width:)`.
    /// Empty and short text keep the compact single-line height.
    static func detailHeight(for message: String, width: CGFloat) -> CGFloat {
        return measuredHeight(of: detailText(for: message, width: width), width: width)
    }

    private static func measuredHeight(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return singleLineDetailHeight }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: detailFont, .paragraphStyle: paragraph]
        )
        let measured = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(singleLineDetailHeight, ceil(measured.height) + 1)
    }

    /// Frames for the error card. A single-line detail follows the same three
    /// row rhythm as the compact balance card; additional detail lines shift
    /// the rows above upward by only the extra measured height.
    static func errorFrames(for message: String) -> ErrorFrames {
        let text = detailText(for: message, width: detailWidth)
        let detailH = measuredHeight(of: text, width: detailWidth)
        let extraDetailHeight = max(0, detailH - singleLineDetailHeight)
        let cardHeight = minimumCardHeight + extraDetailHeight
        // The compact one-line amount center is 1pt above the geometric center
        // of the left status/detail region. As that region grows, move the
        // amount by half the extra height to preserve the same optical center.
        let amountY = 5 + extraDetailHeight / 2
        return ErrorFrames(
            cardSize: NSSize(width: cardWidth, height: cardHeight),
            title: NSRect(x: horizontalInset, y: 58 + extraDetailHeight, width: 127, height: 20),
            refreshTime: NSRect(x: refreshTimeX, y: 59 + extraDetailHeight, width: refreshTimeWidth, height: 17),
            quotaDetail: NSRect(x: horizontalInset, y: 31 + extraDetailHeight, width: 128, height: 18),
            amount: NSRect(x: amountX, y: amountY, width: amountWidth, height: 48),
            detail: NSRect(x: horizontalInset, y: 7, width: detailWidth, height: detailH),
            detailText: text
        )
    }

    /// Wrapping label for the error detail. Uses word wrapping on text prepared
    /// by `detailText(for:width:)`, so normal English words stay whole while
    /// over-wide tokens still have safe character-level break points. Never
    /// truncates.
    static func makeRefreshTimeLabel(_ text: String, showsCachedBalance: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = refreshTimeFont
        label.textColor = showsCachedBalance ? .systemRed : .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func makeDetailLabel(
        _ text: String,
        textColor: NSColor = .secondaryLabelColor
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = detailFont
        label.textColor = textColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}
