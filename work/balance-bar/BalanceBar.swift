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
    static let keys = ["appLanguage", "showMenuBarReset", "showMenuBarIcon", "showMenuBarAmount", "animateCodexActivity", "activityPollInterval", "codexUsageRefreshInterval", "postCodexRefreshDuration", "showQuickSwitchMenu", "showOpenChatGPTMenu", "showOpenCCSwitchMenu", AppPreferences.showOpenCodexMenuKey, "showStatusMenu", "statusLinks", "keepMenuOpenAfterRefresh", "sortProvidersAlphabetically", "menuBarHorizontalPadding", "openCodexDashboardPortOverride", "openCodexDashboardAutomaticDetection", AppPreferences.menuBarIconOffsetXKey, AppPreferences.menuBarIconOffsetYKey, AppPreferences.menuBarAmountOffsetXKey, AppPreferences.menuBarAmountOffsetYKey]

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
    private lazy var dashboardComposition = DashboardCompositionController(
        state: DashboardCompositionState(
            preferences: preferences,
            devBundleIdentifier: devBundleIdentifier,
            providerPollInterval: providerPollInterval,
            currentProviderName: { [weak self] in self?.currentProviderName() ?? tr("未找到", "Not Found", "找不到", "見つかりません") },
            providerChoices: { [weak self] in self?.ccSwitchRepository.loadChoices(appType: self?.activeClient.appType ?? AssistantClient.codex.appType) ?? [] },
            snapshot: { [weak self] in self?.snapshot ?? .placeholder },
            quickSwitchSummaries: { [weak self] in self?.quickSwitchSummariesSnapshot() ?? [:] },
            refreshDate: { [weak self] in self?.refreshDate(for: self?.snapshot ?? .placeholder) },
            menuBarSnapshot: { [weak self] snapshot in self?.menuBarSnapshot(for: snapshot) ?? snapshot },
            iconImage: { [weak self] in self?.statusItemController?.iconImage },
            currentOpenCodexResolution: { [weak self] in self?.currentOpenCodexDashboardResolution() },
            runtimeCandidate: { [weak self] in self?.openCodexState?.state.candidate },
            updateState: { [weak self] in self?.updateService.state ?? .failed(.invalidCurrentVersion) },
            statusLinks: { [weak self] in self?.statusLinks ?? [] },
            defaultStatusLinks: { [weak self] in self?.defaultStatusLinks ?? [] },
            setStatusLinks: { [weak self] links in self?.statusLinks = links }
        ),
        actions: DashboardCompositionActions(
            onManualRefresh: { [weak self] in self?.performManualRefresh(source: "dashboard") },
            onSwitchProvider: { [weak self] providerID in self?.switchProvider(providerID) },
            onOpenProvider: { [weak self] providerID in self?.showDashboardProvider(providerID) },
            onSelectProvider: { [weak self] providerID in self?.showDashboardProvider(providerID) },
            isSortAlphabetically: { [weak self] in self?.sortProvidersAlphabetically ?? false },
            setSortAlphabetically: { [weak self] enabled in self?.sortProvidersAlphabetically = enabled },
            onToggle: { [weak self] identifier, enabled in self?.handleDashboardToggle(identifier: identifier, enabled: enabled) },
            onInterval: { [weak self] identifier, value in self?.handleDashboardInterval(identifier: identifier, value: value) },
            onOffsetAdjust: { [weak self] identifier, delta in
                self?.handleDashboardOffsetAdjust(identifier: identifier, delta: delta)
            },
            onOffsetReset: { [weak self] identifier in
                self?.handleDashboardOffsetReset(identifier: identifier)
            },
            onLanguage: { [weak self] language in self?.applyLanguage(language) },
            onOpenCCSwitch: { [weak self] in self?.openCCSwitch() },
            onCheckForUpdates: { [weak self] in self?.updateService.checkForUpdates() },
            onInstallUpdate: { [weak self] in self?.updateService.installAvailableUpdate() },
            onOpenOpenCodex: { [weak self] in self?.openOpenCodex() },
            onOpenCodexModeChanged: { [weak self] mode in
                self?.openCodexDashboardAutomaticDetection = mode.automaticDetection
                self?.openCodexDashboardPortOverride = mode.manualPort
            },
            onClamp: { [weak self] in self?.clampDashboardScrollViewBounds() },
            onStatusLinksChanged: { [weak self] in
                guard let self else { return }
                self.render(self.snapshot)
                self.statusItemController.updateMenu(input: self.makeStatusItemMenuInput())
            },
            onDidShowPage: { [weak self] in
                guard let self else { return }
                self.updateDashboard(for: self.snapshot, refreshDate: self.refreshDate(for: self.snapshot))
            },
            onDidClose: { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                    SwitchLog.write(
                        "dashboard closed; activation_policy=\(String(describing: NSApp.activationPolicy())); status_visible=\(self.statusItemController.isVisible)",
                        category: "ui.status-item"
                    )
                }
            },
            onDidResize: { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.clampDashboardScrollViewBounds() }
            }
        )
    )
    private var dashboardIsVisible: Bool { dashboardComposition.isVisible }
    private var dashboardSection: DashboardSection { dashboardComposition.section }
    private var timer: Timer?
    private var activityCoordinator: ActivityCoordinator!
    private var databaseWatcher: CCSwitchDatabaseWatcher!
    private var lastSuccessfulRefresh: Date?
    private var dashboardProviderPageRevision: UInt64 = 0
    private var lastProviderID: String?
    private var lastOpenCodexFetch: Date?
    private var clientSnapshots: [
        AssistantClient: (providerID: String, snapshot: Snapshot)
    ] = [:]
    private var openCodexState: (providerID: String, state: OpenCodexRuntimeState)?
    private var openCodexCards: [OpenCodexModelCard] = []
    private var openCodexSwitchInFlight = false
    private var snapshot = Snapshot.placeholder
    private var activeProviderWebsite: URL?
    private var activeClient: AssistantClient = .codex
    private var isCodexTaskRunning = false
    private var isClaudeTaskRunning = false
    private var isClaudeProcessAvailable = false
    private var lifecycle = ApplicationLifecycleState()
    private var lastCodexUsageRefresh: Date?
    private var postCodexRefreshDeadline: Date?
    private let providerPollInterval: TimeInterval = 3
    private let ccSwitchRepository: CCSwitchRepository
    private let officialQuotaClient: OfficialQuotaClient
    private let balanceAPIClient = BalanceAPIClient()
    private var providerRefreshCoordinator: ProviderRefreshCoordinator!
    private var openCodexRefreshCoordinator: OpenCodexRefreshCoordinator!
    private var providerSwitchCoordinator: ProviderSwitchCoordinator!
    private let preferences = AppPreferences()
    private let updateService: UpdateService
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
    private var menuBarIconOffsetX: Double { get { preferences.menuBarIconOffsetX } set { preferences.menuBarIconOffsetX = newValue } }
    private var menuBarIconOffsetY: Double { get { preferences.menuBarIconOffsetY } set { preferences.menuBarIconOffsetY = newValue } }
    private var menuBarAmountOffsetX: Double { get { preferences.menuBarAmountOffsetX } set { preferences.menuBarAmountOffsetX = newValue } }
    private var menuBarAmountOffsetY: Double { get { preferences.menuBarAmountOffsetY } set { preferences.menuBarAmountOffsetY = newValue } }
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
        openCodexRepository: OpenCodexRepository = OpenCodexRepository(),
        updateService: UpdateService? = nil
    ) {
        self.ccSwitchRepository = repository
        self.officialQuotaClient = officialQuotaClient
        self.updateService = updateService ?? UpdateService()
        super.init()
        self.updateService.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.dashboardComposition.refreshUpdateState()
            }
        }
        databaseWatcher = CCSwitchDatabaseWatcher(
            databaseURL: repository.databaseURL,
            onChange: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshStatusItemMenuInput()
                }
                self?.refresh(reason: .configurationChanged)
                self?.providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: self?.activeClient ?? .codex)
            }
        )
        providerRefreshCoordinator = ProviderRefreshCoordinator(
            repository: repository,
            officialQuotaClient: officialQuotaClient,
            balanceAPIClient: balanceAPIClient,
            queue: DispatchQueue(label: "local.balancebar.provider-refresh"),
            actions: ProviderRefreshActions(
                currentProvider: { [weak self] client in
                    self?.ccSwitchRepository.loadCurrent(appType: client.appType)
                },
                isActiveClient: { [weak self] client in
                    self?.activeClient == client
                },
                render: { [weak self] snapshot in self?.render(snapshot) },
                storeClientSnapshot: { [weak self] client, providerID, snapshot in
                    self?.clientSnapshots[client] = (providerID, snapshot)
                },
                updateQuickSwitchSummary: { [weak self] providerID, text in
                    self?.publishQuickSwitchSummary(providerID: providerID, text: text)
                },
                isOpenCodexConfirmed: { [weak self] providerID in
                    guard let self,
                          let current = self.ccSwitchRepository.loadCurrent(appType: AssistantClient.codex.appType),
                          let candidate = current.openCodexCandidate else { return false }
                    return self.openCodexRefreshCoordinator?.isConfirmed(providerID: providerID, candidate: candidate) ?? false
                }
            )
        )
        openCodexRefreshCoordinator = OpenCodexRefreshCoordinator(
            repository: repository,
            officialQuotaClient: officialQuotaClient,
            balanceAPIClient: balanceAPIClient,
            openCodexRepository: openCodexRepository,
            queue: DispatchQueue(label: "local.balancebar.open-codex-refresh"),
            actions: OpenCodexRefreshActions(
                activeClient: { [weak self] in self?.activeClient ?? .codex },
                currentProvider: { [weak self] client in self?.ccSwitchRepository.loadCurrent(appType: client.appType) },
                setState: { [weak self] providerID, state in
                    DispatchQueue.main.async {
                        self?.openCodexState = state.map { (providerID, $0) }
                        self?.openCodexSwitchInFlight = false
                    }
                },
                setCards: { [weak self] cards in
                    DispatchQueue.main.async { self?.openCodexCards = cards }
                },
                refreshMenu: { [weak self] in
                    DispatchQueue.main.async { self?.refreshOpenCodexMenuBar() }
                },
                render: { [weak self] snapshot, providerID, client in
                    self?.renderOpenCodexSnapshot(snapshot, providerID: providerID, client: client)
                },
                refreshStandard: { [weak self] current, client, reason, switched in
                    self?.providerRefreshCoordinator.refreshStandardProvider(current: current, client: client, forceBalance: reason.forcesStandardProviderBalance, switched: switched)
                }
            )
        )
        providerSwitchCoordinator = ProviderSwitchCoordinator(
            repository: repository,
            actions: ProviderSwitchActions(
                changed: { [weak self] in
                    guard let self else { return }
                    self.providerRefreshCoordinator.resetCadence()
                    self.lastProviderID = nil
                    self.lastOpenCodexFetch = nil
                    self.openCodexRefreshCoordinator.clear()
                    DispatchQueue.main.async {
                        self.refreshStatusItemMenuInput()
                        self.openCodexState = nil
                        self.openCodexCards = []
                        self.openCodexSwitchInFlight = false
                    }
                    self.refresh(reason: .providerChanged)
                },
                failed: { [weak self] message in
                    self?.render(.error(message))
                }
            )
        )
        activityCoordinator = ActivityCoordinator(
            actions: ActivityCoordinatorActions(
                activeClient: { [weak self] in self?.activeClient ?? .codex },
                claudeProcessAvailable: { [weak self] in self?.isClaudeProcessAvailable ?? false },
                setClaudeProcessAvailable: { [weak self] available in
                    guard let self else { return }
                    if self.isClaudeProcessAvailable != available {
                        self.isClaudeProcessAvailable = available
                        SwitchLog.write("claude process availability changed; running=\(available)")
                    }
                },
                setActiveClient: { [weak self] client in self?.setActiveClient(client) },
                setCodexTaskRunning: { [weak self] running in self?.setCodexTaskRunning(running) },
                setClaudeTaskRunning: { [weak self] running in self?.setClaudeTaskRunning(running) }
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
                    self.dashboardComposition.refreshMenuBarPage(snapshot: self.snapshot)
                }
            )
        )
    }

    private func makeStatusItemMenuInput() -> StatusItemController.MenuInput {
        let currentProvider = ccSwitchRepository.loadCurrent(appType: activeClient.appType)
        let isOfficialOpenAICodex = activeClient == .codex && currentProvider?.isOfficial == true
        let openAIAccount = OpenAIAccountPresentation.current(
            activeClient: activeClient,
            providerIsOfficial: isOfficialOpenAICodex,
            email: isOfficialOpenAICodex
                ? officialQuotaClient.codexAccountEmail()
                : nil
        )
        return StatusItemController.MenuInput(
            openCodexCards: openCodexCards,
            openCodexState: openCodexState?.state,
            openCodexSwitchInFlight: openCodexSwitchInFlight,
            choices: ccSwitchRepository.loadChoices(appType: activeClient.appType),
            quickSwitchSummaries: quickSwitchSummariesSnapshot(),
            activeClient: activeClient,
            openAIAccount: openAIAccount,
            statusLinks: statusLinks,
            showQuickSwitchMenu: showQuickSwitchMenu,
            showOpenChatGPTMenu: showOpenChatGPTMenu,
            showOpenCCSwitchMenu: showOpenCCSwitchMenu,
            showOpenCodexMenu: showOpenCodexMenu,
            showStatusMenu: showStatusMenu
        )
    }

    private func currentProviderName() -> String {
        ccSwitchRepository.loadChoices(appType: activeClient.appType)
            .first(where: { $0.isCurrent })?.name ?? tr("未找到", "Not Found", "找不到", "見つかりません")
    }

    private func quickSwitchSummariesSnapshot() -> [String: String] {
        providerRefreshCoordinator?.quickSwitchSummariesSnapshot() ?? [:]
    }

    private func publishQuickSwitchSummary(providerID: String, text: String) {
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

    private func makeStatusItemSettings() -> StatusItemController.MenuBarSettings {
        StatusItemController.MenuBarSettings(
            showIcon: showMenuBarIcon,
            showAmount: showMenuBarAmount,
            showReset: showMenuBarReset,
            horizontalPadding: menuBarHorizontalPadding,
            keepMenuOpenAfterRefresh: keepMenuOpenAfterRefresh,
            iconOffsetX: CGFloat(menuBarIconOffsetX),
            iconOffsetY: CGFloat(menuBarIconOffsetY),
            amountOffsetX: CGFloat(menuBarAmountOffsetX),
            amountOffsetY: CGFloat(menuBarAmountOffsetY)
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
        guard lifecycle.beginStart() else { return }
        if let iconURL = Bundle.main.url(forResource: "BalanceBar", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        configureApplicationMenu()
        NSApp.appearance = nil
        dashboardComposition.start()
        let regularPolicyApplied = NSApp.setActivationPolicy(.regular)
        showDashboard()
        statusItemController.start(
            snapshot: snapshot,
            refreshDate: refreshDate(for: snapshot),
            menuInput: makeStatusItemMenuInput(),
            settings: makeStatusItemSettings()
        )
        updateStatusItemActivity()
        databaseWatcher.start()
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
            "database watchers started; count=\(databaseWatcher.startCount)",
            category: "database"
        )
        refresh(reason: .initial)
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: activeClient)
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: .claude)
        providerRefreshCoordinator.prefetchCurrentBalance(for: .claude)
        activityCoordinator.start(interval: activityPollInterval)
        activityCoordinator.pollNow()
        // The file watcher handles normal CC Switch writes. This inexpensive
        // read is a fallback for a missed filesystem notification.
        configureRefreshTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard lifecycle.beginTerminate() else { return }
        SwitchLog.write("session terminating", category: "lifecycle")
        timer?.invalidate()
        activityCoordinator.stop()
        dashboardComposition.teardown()
        statusItemController.teardown()
        databaseWatcher.stop()
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
        refreshStatusItemMenuInput()
        refresh(reason: .manual)
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: activeClient)
    }

    private func refreshStatusItemMenuInput() {
        statusItemController.updateMenu(input: makeStatusItemMenuInput())
    }

    private func switchProvider(_ providerID: String) {
        let appType = activeClient.appType
        let providerName = ccSwitchRepository.loadChoices(appType: appType)
            .first(where: { $0.id == providerID })?.name ?? providerID
        providerSwitchCoordinator.switchProvider(
            providerID: providerID,
            appType: appType,
            providerName: providerName
        )
    }
    private func performOpenCodexPreferenceSwitch(_ preference: OpenCodexPreference) {
        guard activeClient == .codex,
              !openCodexSwitchInFlight,
              let entry = openCodexState,
              let current = ccSwitchRepository.loadCurrent(appType: activeClient.appType),
              current.id == entry.providerID,
              current.openCodexCandidate != nil else { return }

        openCodexSwitchInFlight = true
        openCodexRefreshCoordinator.switchPreference(
            preference,
            providerID: entry.providerID,
            oldState: entry.state
        )
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
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: activeClient)
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu(title: "BalanceBar")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "BalanceBar")
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: tr("关于 BalanceBar", "About BalanceBar", "關於 BalanceBar", "BalanceBar について"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: tr("隐藏 BalanceBar", "Hide BalanceBar", "隱藏 BalanceBar", "BalanceBar を隠す"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = applicationMenu.addItem(
            withTitle: tr("隐藏其他应用", "Hide Others", "隱藏其他應用程式", "ほかのアプリを隠す"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(
            withTitle: tr("全部显示", "Show All", "全部顯示", "すべてを表示"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(
            withTitle: tr("退出 BalanceBar", "Quit BalanceBar", "結束 BalanceBar", "BalanceBar を終了"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("编辑", "Edit", "編輯", "編集"))
        editItem.submenu = editMenu
        editMenu.autoenablesItems = true
        editMenu.addItem(
            withTitle: tr("撤销", "Undo", "還原", "取り消す"),
            action: #selector(UndoManager.undo),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: tr("重做", "Redo", "重做", "やり直す"),
            action: #selector(UndoManager.redo),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: tr("剪切", "Cut", "剪切", "カット"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: tr("拷贝", "Copy", "拷貝", "コピー"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: tr("粘贴", "Paste", "貼上", "ペースト"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: tr("全选", "Select All", "全選", "すべてを選択"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr("窗口", "Window", "視窗", "ウインドウ"))
        windowItem.submenu = windowMenu
        let closeItem = windowMenu.addItem(
            withTitle: tr("关闭窗口", "Close Window", "關閉視窗", "ウインドウを閉じる"),
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
        openCodexRefreshCoordinator.currentCandidate
    }

    private func refreshOpenCodexMenuBar() {
        guard snapshot.kind == .openCodex else { return }
        updateStatusItem(for: snapshot)
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
                dashboardComposition.restoreRequiredMenuBarToggle(identifier: identifier)
                return
            }
            showMenuBarIcon = enabled
            updateStatusItem(for: snapshot)
            refreshDashboardMenuBarPage()
        case "showMenuBarAmount":
            if !enabled && !showMenuBarIcon {
                dashboardComposition.restoreRequiredMenuBarToggle(identifier: identifier)
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
                dashboardComposition.updateMenuStatusVisibility(enabled, animated: true)
            }
        case "keepMenuOpenAfterRefresh":
            keepMenuOpenAfterRefresh = enabled
        case "animateCodexActivity":
            animateCodexActivity = enabled
            setCodexTaskRunning(isCodexTaskRunning, force: true)
        case "openCodexAutomaticDetection":
            dashboardComposition.handleAutomaticDetection(enabled)
        default:
            break
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

    private func handleDashboardOffsetAdjust(identifier: String, delta: Int) {
        let pointDelta = Double(delta) * AppPreferences.menuBarOffsetStep
        switch identifier {
        case AppPreferences.menuBarIconOffsetXKey:
            preferences.menuBarIconOffsetX += pointDelta
        case AppPreferences.menuBarIconOffsetYKey:
            preferences.menuBarIconOffsetY += pointDelta
        case AppPreferences.menuBarAmountOffsetXKey:
            preferences.menuBarAmountOffsetX += pointDelta
        case AppPreferences.menuBarAmountOffsetYKey:
            preferences.menuBarAmountOffsetY += pointDelta
        default:
            return
        }
        SwitchLog.write(
            "preference changed; key=\(identifier); delta=\(delta) step; point_delta=\(pointDelta); icon_x=\(preferences.menuBarIconOffsetX); icon_y=\(preferences.menuBarIconOffsetY); amount_x=\(preferences.menuBarAmountOffsetX); amount_y=\(preferences.menuBarAmountOffsetY)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    private func handleDashboardOffsetReset(identifier: String) {
        switch identifier {
        case DashboardMenuBarPage.iconOffsetsResetIdentifier:
            preferences.menuBarIconOffsetX = 0
            preferences.menuBarIconOffsetY = 0
        case DashboardMenuBarPage.amountOffsetsResetIdentifier:
            preferences.menuBarAmountOffsetX = 0
            preferences.menuBarAmountOffsetY = 0
        default:
            return
        }
        SwitchLog.write(
            "preference reset; identifier=\(identifier); icon_x=\(preferences.menuBarIconOffsetX); icon_y=\(preferences.menuBarIconOffsetY); amount_x=\(preferences.menuBarAmountOffsetX); amount_y=\(preferences.menuBarAmountOffsetY)",
            category: "configuration"
        )
        updateStatusItem(for: snapshot)
    }

    @objc private func dashboardMenuBarPaddingChanged(_ sender: NSSlider) {
        menuBarHorizontalPadding = CGFloat(sender.doubleValue)
        updateStatusItem(for: snapshot)
    }

    @objc private func openDashboard() {
        dashboardComposition.open()
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    var dashboardCompositionForTesting: DashboardCompositionController { dashboardComposition }

    var lifecycleStatsForTesting: ApplicationLifecycleStats {
        lifecycle.stats
    }

    private func showDashboard() {
        dashboardComposition.open()
        updateDashboard(for: snapshot, refreshDate: refreshDate(for: snapshot))
    }

    private func rebuildDashboardForLanguageChange() {
        dashboardComposition.rebuild()
    }

    private func showDashboardSection(
        _ section: DashboardSection,
        restoringScrollPosition scrollPosition: StatusLinksScrollPosition? = nil
    ) {
        dashboardComposition.showSection(section, restoringScrollPosition: scrollPosition)
    }

    private func clampDashboardScrollViewBounds() {
        dashboardComposition.clampScrollBounds()
    }

    private func showDashboardProvider(_ providerID: String) {
        dashboardComposition.showProvider(providerID)
    }

    private func refreshDashboardMenuBarPage() {
        dashboardComposition.refreshMenuBarPage(snapshot: snapshot)
    }

    private func refreshDashboardOpenCodexSettings() {
        dashboardComposition.refreshOpenCodexSettings()
    }

    private func configureRefreshTimers() {
        timer?.invalidate()

        let providerTimer = Timer(timeInterval: providerPollInterval, repeats: true) { [weak self] _ in
            self?.refreshStatusItemMenuInput()
            self?.refresh(reason: .scheduled)
            self?.providerRefreshCoordinator.refreshQuickSwitchSummaries(force: false, for: self?.activeClient ?? .codex)
        }
        timer = providerTimer
        RunLoop.main.add(providerTimer, forMode: .common)
        activityCoordinator.updateInterval(activityPollInterval)
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
        providerRefreshCoordinator.resetCadence()
        lastOpenCodexFetch = nil
        openCodexState = nil
        openCodexCards = []
        openCodexRefreshCoordinator.clear()
        refreshOpenCodexMenuBar()
        openCodexSwitchInFlight = false
        lastCodexUsageRefresh = nil
        postCodexRefreshDeadline = nil
        updateStatusItemActivity()
        refreshStatusItemMenuInput()
        // Never flash the generic ellipsis during a focus switch. Reuse the
        // last successful snapshot for this client while the live refresh runs.
        // Startup prefetch normally makes this available before the first switch.
        if let cached = clientSnapshots[client],
           ccSwitchRepository.loadCurrent(appType: client.appType)?.id == cached.providerID {
            lastProviderID = cached.providerID
            render(cached.snapshot)
        }
        refresh(reason: .clientChanged)
        providerRefreshCoordinator.refreshQuickSwitchSummaries(force: true, for: activeClient)
        if dashboardIsVisible {
            showDashboardSection(dashboardSection)
        }
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
        guard dashboardIsVisible else { return }
        dashboardProviderPageRevision &+= 1
        dashboardComposition.refreshMountedPage(
            snapshot: snapshot,
            refreshDate: refreshDate,
            revision: dashboardProviderPageRevision
        )
    }

    private func refresh(reason: BalanceRefreshReason) {
        let client = activeClient
        providerRefreshCoordinator.performAsync { [weak self] in
            guard let self else { return }
            let current = self.ccSwitchRepository.loadCurrent(appType: client.appType)
            guard let current else {
                SwitchLog.write(
                    "refresh failed; client=\(client.rawValue); current provider not found",
                    level: .error,
                    category: "provider"
                )
                self.render(.error(tr(
                    "未找到 CC Switch 当前 \(client.displayName) 供应商",
                    "The current CC Switch \(client.displayName) Provider was not found",
                    "找不到 CC Switch 目前的 \(client.displayName) 供應商",
                    "現在の CC Switch \(client.displayName) プロバイダーが見つかりません"
                )))
                return
            }

            // The Provider name is local CC Switch state, so reflect it in the
            // dashboard immediately instead of waiting for the remote balance
            // request to finish.
            let switched = current.id != self.lastProviderID
            if switched {
                SwitchLog.write("provider observed; app=\(client.appType); id=\(current.id); name=\(current.name); source=database watcher/poll")
                self.lastOpenCodexFetch = nil
                self.openCodexRefreshCoordinator.clear()
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
                self.openCodexRefreshCoordinator.refresh(
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
                self.openCodexRefreshCoordinator.clear()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.openCodexState?.providerID == current.id else { return }
                    self.openCodexState = nil
                    self.openCodexCards = []
                    self.openCodexSwitchInFlight = false
                    self.refreshOpenCodexMenuBar()
                }
            }

            self.providerRefreshCoordinator.refreshStandardProvider(
                current: current,
                client: client,
                forceBalance: reason.forcesStandardProviderBalance,
                switched: switched
            )
        }
    }

    private func renderOpenCodexSnapshot(
        _ next: Snapshot,
        providerID: String,
        client: AssistantClient
    ) {
        providerRefreshCoordinator.performAsync { [weak self] in
            guard let self,
                  self.ccSwitchRepository.loadCurrent(appType: client.appType)?.id == providerID
            else { return }
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

struct ApplicationLifecycleStats: Equatable {
    let startCount: Int
    let terminateCount: Int
}

/// Small, main-thread-owned lifecycle gate used by the composition root.
/// Keeping the gate independent makes the single-install/single-teardown
/// contract testable without starting AppKit's event loop.
final class ApplicationLifecycleState {
    private(set) var hasStarted = false
    private(set) var hasTerminated = false
    private(set) var startCount = 0
    private(set) var terminateCount = 0

    var stats: ApplicationLifecycleStats {
        ApplicationLifecycleStats(
            startCount: startCount,
            terminateCount: terminateCount
        )
    }

    func beginStart() -> Bool {
        guard !hasStarted, !hasTerminated else { return false }
        hasStarted = true
        startCount += 1
        return true
    }

    func beginTerminate() -> Bool {
        guard hasStarted, !hasTerminated else { return false }
        hasTerminated = true
        terminateCount += 1
        return true
    }
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
        let account: NSRect?
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
    static func errorFrames(
        for message: String,
        includesAccount: Bool = false
    ) -> ErrorFrames {
        let text = detailText(for: message, width: detailWidth)
        let detailH = measuredHeight(of: text, width: detailWidth)
        let extraDetailHeight = max(0, detailH - singleLineDetailHeight)
        let accountShift: CGFloat = includesAccount ? 19 : 0
        let cardHeight = minimumCardHeight + extraDetailHeight + accountShift
        // The compact one-line amount center is 1pt above the geometric center
        // of the left status/detail region. As that region grows, move the
        // amount by half the extra height to preserve the same optical center.
        let amountY = 5 + extraDetailHeight / 2
        return ErrorFrames(
            cardSize: NSSize(width: cardWidth, height: cardHeight),
            title: NSRect(x: horizontalInset, y: 58 + extraDetailHeight + accountShift, width: 127, height: 20),
            refreshTime: NSRect(x: refreshTimeX, y: 59 + extraDetailHeight + accountShift, width: refreshTimeWidth, height: 17),
            account: includesAccount
                ? NSRect(x: horizontalInset, y: 58 + extraDetailHeight, width: contentWidth, height: 17)
                : nil,
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
