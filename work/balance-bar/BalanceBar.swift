import AppKit
import Foundation

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
    static let keys = ["appLanguage", "showMenuBarReset", "showMenuBarIcon", "showMenuBarAmount", "animateCodexActivity", "activityPollInterval", "codexUsageRefreshInterval", "postCodexRefreshDuration", "showQuickSwitchMenu", "showOpenChatGPTMenu", "showOpenCCSwitchMenu", AppPreferences.showOpenCodexMenuKey, "showStatusMenu", "statusLinks", "keepMenuOpenAfterRefresh", "sortProvidersAlphabetically", "menuBarHorizontalPadding", "openCodexDashboardPortOverride", "openCodexDashboardAutomaticDetection"]

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var statusItemController: StatusItemController!
    private let monitorQueue = DispatchQueue(label: "local.balancebar.monitor")
    private let activityMonitorQueue = DispatchQueue(
        label: "local.balancebar.activity-monitor",
        qos: .utility
    )
    private let codexActivityMonitor = CodexActivityMonitor()
    private let claudeActivityMonitor = ClaudeCodeActivityMonitor()
    private var dashboardWindowController: DashboardWindowController!
    private var dashboard: NSWindow? { dashboardWindowController?.window }
    private var dashboardContentHost: NSView { dashboardWindowController.contentHost }
    private var dashboardSection: DashboardSection { dashboardWindowController.section }
    private var dashboardSelectedProviderID: String? { dashboardWindowController.selectedProviderID }
    private lazy var statusLinksScrollAnchorController = StatusLinksScrollAnchorController(
        dashboardProvider: { [weak self] in self?.dashboard },
        contentHostProvider: { [weak self] in self?.dashboardContentHost },
        sectionTitleProvider: { [weak self] in self?.dashboardSection.title ?? "" },
        linksCountProvider: { [weak self] in self?.statusLinks.count ?? 0 }
    )
    private var timer: Timer?
    private var activityTimer: Timer?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var databaseWatchers: [DispatchSourceFileSystemObject] = []
    private var syncWorkItem: DispatchWorkItem?
    private var lastSuccessfulRefresh: Date?
    private var dashboardProviderPageRevision: UInt64 = 0
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
    private lazy var dashboardProviderPages = DashboardProviderPages(
        actions: DashboardProviderPageActions(
            onRefresh: { [weak self] in
                self?.performManualRefresh(source: "dashboard")
            },
            onSwitchProvider: { [weak self] providerID in
                self?.switchProvider(providerID)
            },
            onOpenProvider: { [weak self] providerID in
                self?.dashboardWindowController.showProvider(providerID)
            },
            onSelectProvider: { [weak self] providerID in
                self?.showDashboardProvider(providerID)
            },
            isSortAlphabetically: { [weak self] in
                self?.sortProvidersAlphabetically ?? false
            },
            setSortAlphabetically: { [weak self] enabled in
                self?.sortProvidersAlphabetically = enabled
            }
        )
    )
    private lazy var dashboardPreferencePages = DashboardPreferencePages(
        preferences: preferences,
        devBundleIdentifier: devBundleIdentifier,
        actions: DashboardPreferencePageActions(
            onToggle: { [weak self] identifier, enabled in
                self?.handleDashboardToggle(identifier: identifier, enabled: enabled)
            },
            onInterval: { [weak self] identifier, value in
                self?.handleDashboardInterval(identifier: identifier, value: value)
            },
            onLanguage: { [weak self] language in
                self?.applyLanguage(language)
            },
            onOpenCCSwitch: { [weak self] in
                self?.openCCSwitch()
            },
            onManualRefresh: { [weak self] in
                self?.performManualRefresh(source: "dashboard")
            },
            onOpenOpenCodex: { [weak self] in
                self?.openOpenCodex()
            },
            makeStatusLinksEditor: { [weak self] in
                self?.makeStatusLinksEditor() ?? StatusLinksEditorHostingView(links: [], onChange: { _, _, _ in }, onAdd: {}, onRemove: { _ in }, onReset: {})
            },
            onOpenCodexModeChanged: { [weak self] mode in
                self?.openCodexDashboardAutomaticDetection = mode.automaticDetection
                self?.openCodexDashboardPortOverride = mode.manualPort
            },
            onClamp: { [weak self] in
                self?.clampDashboardScrollViewBounds()
            }
        )
    )
    private var showMenuBarReset: Bool { get { preferences.showMenuBarReset } set { preferences.showMenuBarReset = newValue } }
    private var showMenuBarIcon: Bool { get { preferences.showMenuBarIcon } set { preferences.showMenuBarIcon = newValue } }
    private var showMenuBarAmount: Bool { get { preferences.showMenuBarAmount } set { preferences.showMenuBarAmount = newValue } }
    private var animateCodexActivity: Bool { get { preferences.animateCodexActivity } set { preferences.animateCodexActivity = newValue } }
    private var activityPollInterval: TimeInterval { get { preferences.activityPollInterval } set { preferences.activityPollInterval = newValue } }
    private var codexUsageRefreshInterval: TimeInterval { get { preferences.codexUsageRefreshInterval } set { preferences.codexUsageRefreshInterval = newValue } }
    private var postCodexRefreshDuration: TimeInterval { get { preferences.postCodexRefreshDuration } set { preferences.postCodexRefreshDuration = newValue } }
    private var showQuickSwitchMenu: Bool { get { preferences.showQuickSwitchMenu } set { preferences.showQuickSwitchMenu = newValue } }
    private var showOpenCCSwitchMenu: Bool { get { preferences.showOpenCCSwitchMenu } set { preferences.showOpenCCSwitchMenu = newValue } }
    private var showOpenCodexMenu: Bool { get { preferences.showOpenCodexMenu } set { preferences.showOpenCodexMenu = newValue } }
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
        dashboardWindowController = DashboardWindowController(
            actions: DashboardWindowControllerActions(
                makeSectionPage: { [weak self] section in
                    self?.makeDashboardPage(for: section) ?? NSView()
                },
                makeProviderPage: { [weak self] choice in
                    guard let self else { return NSView() }
                    return self.dashboardProviderPages.makeProviderPage(
                        choice: choice,
                        input: self.makeDashboardProviderPageInput()
                    )
                },
                providerChoices: { [weak self] in
                    self?.ccSwitchRepository.loadChoices(
                        appType: self?.activeClient.appType ?? AssistantClient.codex.appType
                    ) ?? []
                },
                prepareForPageReplacement: { [weak self] in
                    guard let self else { return }
                    self.statusLinksScrollAnchorController.stop()
                    self.dashboardPreferencePages.teardown()
                },
                didShowPage: { [weak self] in
                    guard let self else { return }
                    self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot))
                },
                didClose: { [weak self] in
                    guard let self else { return }
                    self.statusLinksScrollAnchorController.stop()
                    DispatchQueue.main.async {
                        NSApp.setActivationPolicy(.accessory)
                        SwitchLog.write(
                            "dashboard closed; activation_policy=\(String(describing: NSApp.activationPolicy())); status_visible=\(self.statusItemController.isVisible)",
                            category: "ui.status-item"
                        )
                    }
                },
                didResize: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.clampDashboardScrollViewBounds()
                    }
                }
            )
        )
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
                    self.dashboardPreferencePages.refreshMenuBar(
                        snapshot: self.snapshot,
                        menuBarSnapshot: { [weak self] snapshot in
                            self?.menuBarSnapshot(for: snapshot) ?? snapshot
                        },
                        iconImage: image
                    )
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
            showOpenCodexMenu: showOpenCodexMenu,
            showStatusMenu: showStatusMenu
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
        dashboardWindowController.start()
        let regularPolicyApplied = NSApp.setActivationPolicy(.regular)
        statusItemController.start(
            snapshot: snapshot,
            refreshDate: refreshDate(for: snapshot),
            menuInput: makeStatusItemMenuInput(),
            settings: makeStatusItemSettings()
        )
        updateStatusItemActivity()
        showDashboard()
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
        dashboardProviderPages.teardown()
        dashboardPreferencePages.teardown()
        statusItemController.teardown()
        dashboardWindowController.teardown()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
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
        let resolution = openCodexDashboardLaunchResolution()
        SwitchLog.write(
            "OpenCodex Dashboard launch requested; source=\(String(describing: resolution.source)); port=\(resolution.port); path=\(resolution.url.path); fragment=\(resolution.url.fragment ?? "none")",
            category: "open-codex.dashboard"
        )
        NSWorkspace.shared.open(resolution.url)
    }

    private func currentOpenCodexDashboardResolution() -> OpenCodexDashboardResolution? {
        guard let runtimeCandidate = openCodexDashboardCandidate() else { return nil }
        return OpenCodexDashboardResolver.resolve(
            manualPort: openCodexDashboardMode.effectiveManualPort,
            runtimeCandidate: runtimeCandidate
        )
    }

    private func openCodexDashboardLaunchResolution() -> OpenCodexDashboardResolution {
        OpenCodexDashboardResolver.resolve(
            manualPort: openCodexDashboardMode.effectiveManualPort,
            runtimeCandidate: openCodexDashboardCandidate()
        )
    }

    private func openCodexDashboardCandidate() -> OpenCodexEndpointCandidate? {
        let codexAppType = AssistantClient.codex.appType
        let currentCodex = ccSwitchRepository.loadCurrent(appType: codexAppType)
        if activeClient == .codex,
           let currentCodex,
           let entry = openCodexState,
           entry.providerID == currentCodex.id {
            return entry.state.candidate
        }
        if let candidate = currentCodex?.openCodexCandidate {
            return candidate
        }
        return ccSwitchRepository.loadSummarySources(appType: codexAppType)
            .compactMap(\.openCodexCandidate)
            .first
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

    private func handleDashboardToggle(identifier: String, enabled: Bool) {
        SwitchLog.write(
            "preference changed; key=\(identifier); enabled=\(enabled)",
            category: "configuration"
        )
        switch identifier {
        case "showMenuBarIcon":
            if !enabled && !showMenuBarAmount {
                dashboardPreferencePages.restoreRequiredMenuBarToggle(identifier: identifier)
                return
            }
            showMenuBarIcon = enabled
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarAmount":
            if !enabled && !showMenuBarIcon {
                dashboardPreferencePages.restoreRequiredMenuBarToggle(identifier: identifier)
                return
            }
            showMenuBarAmount = enabled
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarReset":
            showMenuBarReset = enabled
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showQuickSwitchMenu":
            showQuickSwitchMenu = enabled
            render(snapshot)
        case "showOpenCCSwitchMenu":
            showOpenCCSwitchMenu = enabled
            render(snapshot)
        case "showOpenCodexMenu":
            showOpenCodexMenu = enabled
            render(snapshot)
        case "showOpenChatGPTMenu":
            showOpenChatGPTMenu = enabled
            render(snapshot)
        case "showStatusMenu":
            showStatusMenu = enabled
            render(snapshot)
            if dashboardSection == .menu {
                dashboardPreferencePages.updateMenuStatusVisibility(enabled, animated: true)
            }
        case "keepMenuOpenAfterRefresh":
            keepMenuOpenAfterRefresh = enabled
        case "animateCodexActivity":
            animateCodexActivity = enabled
            setCodexTaskRunning(isCodexTaskRunning, force: true)
        case "openCodexAutomaticDetection":
            dashboardPreferencePages.handleAutomaticDetection(enabled)
        default:
            break
        }
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

    private func handleDashboardInterval(identifier: String, value: TimeInterval) {
        SwitchLog.write(
            "interval changed; key=\(identifier); value=\(value)s",
            category: "configuration"
        )
        var refreshTimers = false
        switch identifier {
        case "activityPollInterval":
            activityPollInterval = value
            refreshTimers = true
        case "codexUsageRefreshInterval":
            codexUsageRefreshInterval = value
        case "postCodexRefreshDuration":
            postCodexRefreshDuration = value
            if !isCodexTaskRunning, postCodexRefreshDeadline != nil {
                postCodexRefreshDeadline = value > 0
                    ? Date().addingTimeInterval(value)
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

    @objc private func openDashboard() {
        dashboardWindowController.open()
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private func makeDashboardPage(for section: DashboardSection) -> NSView {
        let currentName = ccSwitchRepository.loadChoices(appType: activeClient.appType)
            .first(where: { $0.isCurrent })?.name ?? tr("未找到", "Not Found")
        return dashboardPreferencePages.makePage(
            for: section,
            currentProviderName: currentName,
            providerPollInterval: providerPollInterval,
            snapshot: snapshot,
            menuBarSnapshot: { [weak self] snapshot in
                self?.menuBarSnapshot(for: snapshot) ?? snapshot
            },
            iconImage: statusItemController?.iconImage,
            currentOpenCodexResolution: currentOpenCodexDashboardResolution(),
            runtimeCandidate: openCodexState?.state.candidate
        )
    }

    func dashboardPageForTesting(_ section: DashboardSection) -> NSView {
        makeDashboardPage(for: section)
    }

    func dashboardWindowForTesting(showing section: DashboardSection) -> NSWindow? {
        dashboardWindowController.open()
        dashboardWindowController.showSection(section)
        return dashboardWindowController.window
    }

    func addStatusLinkForTesting() {
        addStatusLink()
    }

    func teardownDashboardForTesting() {
        dashboardProviderPages.teardown()
        dashboardWindowController.teardown()
    }

    private func showDashboard() {
        dashboardWindowController.open()
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private func rebuildDashboardForLanguageChange() {
        dashboardWindowController.rebuild()
    }

    private func showDashboardSection(
        _ section: DashboardSection,
        restoringScrollPosition scrollPosition: StatusLinksScrollPosition? = nil
    ) {
        dashboardWindowController.showSection(section)
        dashboardProviderPages.refreshProviderList(input: makeDashboardProviderPageInput())
        if let scrollPosition {
            statusLinksScrollAnchorController.restore(scrollPosition, attempt: 0)
        }
    }

    private func clampDashboardScrollViewBounds() {
        statusLinksScrollAnchorController.clampDashboardScrollViewBounds()
    }

    private func showDashboardProvider(_ providerID: String) {
        dashboardWindowController.showProvider(providerID)
        dashboardProviderPages.refreshProviderList(input: makeDashboardProviderPageInput())
    }

    private func makeStatusLinksEditor() -> StatusLinksEditorHostingView {
        StatusLinksEditorHostingView(
            links: statusLinks,
            onChange: { [weak self] index, field, value in
                self?.dashboardStatusLinkChanged(index: index, field: field, value: value)
            },
            onAdd: { [weak self] in self?.addStatusLink() },
            onRemove: { [weak self] index in self?.removeStatusLink(at: index) },
            onReset: { [weak self] in self?.resetStatusLinks() }
        )
    }

    private func makeDashboardProviderPageInput(
        snapshot: Snapshot? = nil,
        refreshDate: Date? = nil,
        useLastSuccessfulRefresh: Bool = true,
        revision: UInt64? = nil
    ) -> DashboardProviderPageInput {
        quickSwitchSummaryLock.lock()
        let summaries = quickSwitchSummaries
        quickSwitchSummaryLock.unlock()
        return DashboardProviderPageInput(
            choices: ccSwitchRepository.loadChoices(appType: activeClient.appType),
            selectedProviderID: dashboardSelectedProviderID,
            snapshot: snapshot ?? self.snapshot,
            quickSwitchSummaries: summaries,
            refreshDate: useLastSuccessfulRefresh ? lastSuccessfulRefresh : refreshDate,
            revision: revision ?? dashboardProviderPageRevision
        )
    }

    private func refreshDashboardMenuBarPage() {
        guard dashboard?.isVisible == true, dashboardSection == .menuBar else { return }
        dashboardPreferencePages.refreshMenuBar(
            snapshot: snapshot,
            menuBarSnapshot: { [weak self] snapshot in
                self?.menuBarSnapshot(for: snapshot) ?? snapshot
            },
            iconImage: statusItemController?.iconImage
        )
    }

    private func refreshDashboardOpenCodexSettings() {
        guard dashboard?.isVisible == true, dashboardSection == .advanced else { return }
        dashboardPreferencePages.refreshAdvanced(
            currentOpenCodexResolution: currentOpenCodexDashboardResolution(),
            runtimeCandidate: openCodexState?.state.candidate
        )
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
        dashboardProviderPageRevision &+= 1
        dashboardProviderPages.refreshOverview(
            input: makeDashboardProviderPageInput(
                snapshot: snapshot,
                refreshDate: refreshDate,
                useLastSuccessfulRefresh: false,
                revision: dashboardProviderPageRevision
            )
        )
        refreshDashboardMenuBarPage()
        refreshDashboardOpenCodexSettings()
    }

    private func updateDashboardCurrentProvider(_ name: String) {
        dashboardProviderPages.updateCurrentProvider(name)
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
