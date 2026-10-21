import AppKit

/// What the status menu shows for the real-time boost.
enum ModMenuRow: Equatable {
    case none
    /// The accent-tinted prompt under the quota card; opens the explanation window. `headless` switches to the
    /// wording for a user whose HUD does not follow headless runs.
    case prompt(headless: Bool)
    /// "数据来源": the quiet gray entry that replaces the prompt; opens Settings › Advanced.
    case dataSources
}

/// The Mod's entry in Claude Code's plugin registry.
struct ModInstallRecord: Equatable {
    var installedAt: Date?
}

/// Reads `~/.claude/plugins/installed_plugins.json` (read-only) to learn whether the Mod is installed.
enum ClaudePluginRegistry {
    static func defaultURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".claude/plugins/installed_plugins.json")
    }

    /// Returns the install record of `pluginID`, or `nil` when the registry does not list it.
    static func record(from data: Data, pluginID: String) -> ModInstallRecord? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let entries = plugins[pluginID] as? [Any], !entries.isEmpty else { return nil }
        let dates = entries.compactMap { ($0 as? [String: Any])?["installedAt"] as? String }.compactMap(parseDate)
        return ModInstallRecord(installedAt: dates.max())
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Persists when Mod data last arrived, so the 7-day rule survives restarts.
protocol ModDataTimestampStoring: AnyObject {
    var lastModDataAt: Date? { get set }
}

final class UserDefaultsModDataTimestamp: ModDataTimestampStoring {
    static let key = "modOnboarding.lastModDataAt"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var lastModDataAt: Date? {
        get { defaults.object(forKey: Self.key) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: Self.key)) }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: Self.key) }
    }
}

/// Headless Claude Code time accumulated within the current day, persisted across launches.
struct ModHeadlessAccumulation: Equatable {
    var windowStart: Date?
    var seconds: TimeInterval = 0
}

protocol ModHeadlessStoring: AnyObject {
    var accumulation: ModHeadlessAccumulation { get set }
}

final class UserDefaultsModHeadlessStore: ModHeadlessStoring {
    static let startKey = "modOnboarding.headlessWindowStart"
    static let secondsKey = "modOnboarding.headlessSeconds"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var accumulation: ModHeadlessAccumulation {
        get {
            ModHeadlessAccumulation(
                windowStart: defaults.object(forKey: Self.startKey) == nil
                    ? nil : Date(timeIntervalSince1970: defaults.double(forKey: Self.startKey)),
                seconds: defaults.double(forKey: Self.secondsKey))
        }
        set {
            defaults.set(newValue.windowStart?.timeIntervalSince1970, forKey: Self.startKey)
            defaults.set(newValue.seconds, forKey: Self.secondsKey)
        }
    }
}

/// Forwards the prompt-dismissal preference and tells the coordinator when it changes.
private final class NotifyingPromptPreference: ModPromptPreferenceStoring {
    private let base: ModPromptPreferenceStoring
    var onChange: (() -> Void)?
    init(base: ModPromptPreferenceStoring) { self.base = base }
    var isPromptDismissed: Bool {
        get { base.isPromptDismissed }
        set {
            guard base.isPromptDismissed != newValue else { return }
            base.isPromptDismissed = newValue
            onChange?()
        }
    }
}

/// Owns the real-time boost onboarding state shared by the menu row, the explanation panel and
/// Settings › Advanced: Claude Code version, plugin installation, Mod data arrival and Claude activity.
///
/// Everything slow (running `claude --version`, reading the plugin registry) happens on a private
/// utility queue; the accessors the menu uses only read memory. `onChange` fires on the main thread.
final class ModOnboardingCoordinator {
    struct Environment {
        /// Blocking; called off the main thread.
        var detectClaudeCode: () -> ClaudeCodeVersionStatus
        /// Blocking; called off the main thread. `nil` means the Mod is not installed.
        var readInstallRecord: () -> ModInstallRecord?
        /// A Claude HUD usage snapshot has been read.
        var hasHUDSnapshot: () -> Bool
        /// Headless Claude Code time seen by the HUD source since launch.
        var headlessDuration: () -> TimeInterval

        static func production(plan: ModInstallPlan, hud: ClaudeHUDSource?) -> Environment {
            Environment(
                detectClaudeCode: {
                    guard let path = DefaultClaudeExecutableLocator().locate(),
                          let result = ProcessModCommandRunner(timeout: 15).run(executablePath: path, arguments: ["--version"]),
                          result.exitCode == 0,
                          let version = ClaudeCodeVersion.parse(result.stdout) else { return .unknown }
                    return .detected(version)
                },
                readInstallRecord: {
                    (try? Data(contentsOf: ClaudePluginRegistry.defaultURL()))
                        .flatMap { ClaudePluginRegistry.record(from: $0, pluginID: plan.pluginID) }
                },
                hasHUDSnapshot: {
                    guard let diagnostics = hud?.diagnostics, case .exporting = diagnostics.status else { return false }
                    if case .unavailable = diagnostics.health { return false }
                    return true
                },
                headlessDuration: { hud?.headlessDuration ?? 0 })
        }
    }

    let controller: ModOnboardingController
    /// Fires on the main thread whenever anything the menu row or the settings page shows may have changed.
    var onChange: (() -> Void)?

    private let environment: Environment
    private let timestamps: ModDataTimestampStoring
    private let headlessStore: ModHeadlessStoring
    private var lastHeadlessSeen: TimeInterval = 0
    private let preference: NotifyingPromptPreference
    private let now: () -> Date
    private let queue = DispatchQueue(label: "balancebar.mod-environment", qos: .utility)
    private let lock = NSLock()
    private var claudeCode: ClaudeCodeVersionStatus = .unknown
    private var installRecord: ModInstallRecord?
    private var installChecked = false
    private var environmentRefreshing = false
    private var lastEnvironmentRefresh: Date?
    private var claudeActive = false
    private var activityStartedAt: Date?
    private var lastModDataAt: Date?
    private var settingsRows: RealtimeBoostSettingsRows?
    private(set) lazy var windowController = ModOnboardingWindowController(makeView: { [unowned self] in self.makePanelView() })

    init(
        plan: ModInstallPlan = .resolved(),
        environment: Environment,
        promptPreference: ModPromptPreferenceStoring = UserDefaultsModPromptPreference(),
        timestamps: ModDataTimestampStoring = UserDefaultsModDataTimestamp(),
        headlessStore: ModHeadlessStoring = UserDefaultsModHeadlessStore(),
        installer: ModInstaller? = nil,
        copyToPasteboard: ((String) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.environment = environment
        self.timestamps = timestamps
        self.headlessStore = headlessStore
        self.now = now
        preference = NotifyingPromptPreference(base: promptPreference)
        if let copyToPasteboard {
            controller = ModOnboardingController(
                plan: plan, installer: installer, preference: preference, copyToPasteboard: copyToPasteboard)
        } else {
            controller = ModOnboardingController(plan: plan, installer: installer, preference: preference)
        }
        lastModDataAt = timestamps.lastModDataAt
        preference.onChange = { [weak self] in self?.notify() }
        controller.silenceCheck = { [weak self] in self?.enhancementStatus() == .enabledButSilent }
        controller.onInstallFinished = { [weak self] result in
            switch result {
            case .success: SwitchLog.write("mod install finished; result=success", category: "mod.install")
            case let .failure(failure):
                SwitchLog.write("mod install finished; result=failure; \(failure.summary)", level: .warning, category: "mod.install")
            }
            guard let self, case .success = result else { return }
            // The registry now lists the plugin: pick up the install time that starts the silence clock.
            self.refreshEnvironment(force: true)
        }
    }

    // MARK: Queries (memory only)

    /// The menu row for the current state; only meaningful for the official Claude provider.
    func menuRow(isOfficialDirect: Bool) -> ModMenuRow {
        guard isOfficialDirect else { return .none }
        guard promptVisibility(isOfficialDirect: true).isVisible else { return .dataSources }
        return .prompt(headless: environment.hasHUDSnapshot())
    }

    func promptVisibility(isOfficialDirect: Bool) -> ModPromptVisibility {
        let (claudeCode, lastModDataAt) = lock.withLock { (self.claudeCode, self.lastModDataAt) }
        let hasSnapshot = environment.hasHUDSnapshot()
        let inputs = ModPromptInputs(
            isOfficialDirect: isOfficialDirect,
            lastModDataAt: lastModDataAt,
            claudeCode: claudeCode,
            promptDismissed: controller.isPromptDismissed,
            hasHUDSnapshot: hasSnapshot,
            headlessSignalSatisfied: accumulatedHeadlessTime() > ModOnboardingConfig.headlessDurationThreshold)
        return ModPromptVisibility.evaluate(inputs, now: now())
    }

    /// Headless time within the last day. The HUD source reports time since launch, so only the growth since the
    /// previous look is added; the sum survives restarts and restarts its day once the window is over.
    private func accumulatedHeadlessTime() -> TimeInterval {
        let current = environment.headlessDuration()
        return lock.withLock {
            let delta = current >= lastHeadlessSeen ? current - lastHeadlessSeen : current
            lastHeadlessSeen = current
            var accumulation = headlessStore.accumulation
            let date = now()
            if let start = accumulation.windowStart, date.timeIntervalSince(start) <= ModOnboardingConfig.headlessAccumulationWindow,
               date >= start {
                accumulation.seconds += delta
            } else {
                accumulation = ModHeadlessAccumulation(windowStart: date, seconds: delta)
            }
            if delta > 0 || headlessStore.accumulation.windowStart == nil { headlessStore.accumulation = accumulation }
            return accumulation.seconds
        }
    }

    func enhancementStatus() -> ModEnhancementStatus {
        let (claudeCode, record, checked, lastModDataAt, active, activityStart) = lock.withLock {
            (self.claudeCode, self.installRecord, self.installChecked, self.lastModDataAt, self.claudeActive, self.activityStartedAt)
        }
        // Until the registry has been read, data from the Mod itself is the best evidence of an install.
        let installed = checked ? record != nil : lastModDataAt != nil
        let silenceSince = [record?.installedAt, activityStart].compactMap { $0 }.max()
        return ModEnhancementStatus.resolve(
            installed: installed,
            lastModDataAt: lastModDataAt,
            claudeActivityDetected: active,
            claudeCode: claudeCode,
            silenceSince: silenceSince,
            now: now())
    }

    // MARK: Inputs

    /// Claude Code started or stopped working. The start of the current activity is what the
    /// "installed but silent" clock counts from.
    func setClaudeActivity(running: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard running != claudeActive else { return false }
            claudeActive = running
            if running { activityStartedAt = now() }
            return true
        }
        if changed { notify() }
    }

    /// Receives every observation the real-time sources delivered; only the Mod's count as Mod data.
    func recordObservation(_ observation: QuotaObservation) {
        guard observation.source == ModOnboardingConfig.modSourceID else { return }
        let date = min(observation.observedAt ?? observation.receivedAt, now())
        let notifyChange = lock.withLock { () -> Bool in
            guard lastModDataAt.map({ date > $0 }) ?? true else { return false }
            let previous = lastModDataAt
            lastModDataAt = date
            timestamps.lastModDataAt = date
            // A steady stream of snapshots must not rebuild the menu each time.
            return previous.map { date.timeIntervalSince($0) > 60 } ?? true
        }
        // The first snapshot after an install completes it ("wait for first data").
        DispatchQueue.main.async { [weak self] in self?.controller.markFirstDataReceived() }
        if notifyChange { notify() }
    }

    /// Re-reads the Claude Code version and the plugin registry in the background when the
    /// last read is older than `ModOnboardingConfig.environmentRefreshInterval` (or `force`).
    /// `completion` runs on the main thread once the read finished (or was skipped as unnecessary).
    func refreshEnvironment(force: Bool = false, completion: (() -> Void)? = nil) {
        let shouldRun = lock.withLock { () -> Bool in
            if environmentRefreshing { return false }
            let interval = claudeCode == .unknown
                ? ModOnboardingConfig.unknownVersionRetryInterval : ModOnboardingConfig.environmentRefreshInterval
            if !force, let last = lastEnvironmentRefresh, now().timeIntervalSince(last) < interval { return false }
            environmentRefreshing = true
            return true
        }
        guard shouldRun else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        queue.async { [self] in
            let version = environment.detectClaudeCode()
            let record = environment.readInstallRecord()
            let changed = lock.withLock { () -> Bool in
                let different = claudeCode != version || installRecord != record || !installChecked
                claudeCode = version
                installRecord = record
                installChecked = true
                lastEnvironmentRefresh = now()
                environmentRefreshing = false
                return different
            }
            if changed { notify() }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: Views (main thread)

    /// The Settings › Advanced rows. One set is kept up to date and re-parented by each page build;
    /// `detached` returns a separate snapshot for Dashboard search results.
    func realtimeBoostSettingsRows(detached: Bool = false) -> [NSView] {
        if detached {
            return RealtimeBoostSettingsRows(
                controller: controller, status: enhancementStatus(), localize: RealtimeBoostText.appLocalize,
                observesController: false, onShowDescription: nil).rows
        }
        if let settingsRows { return settingsRows.rows }
        let rows = RealtimeBoostSettingsRows(
            controller: controller, status: enhancementStatus(), localize: RealtimeBoostText.appLocalize,
            onShowDescription: { [weak self] in self?.showWindow() })
        settingsRows = rows
        refreshEnvironment()
        return rows.rows
    }

    /// Opens (or brings forward) the explanation window.
    func showWindow() {
        refreshEnvironment()
        windowController.show()
    }

    /// A fresh explanation view in its intro state (an install in progress keeps showing its progress).
    func makePanelView() -> ModOnboardingPanelView {
        controller.resetToIntro(force: enhancementStatus() == .notInstalled)
        return ModOnboardingPanelView(controller: controller, localize: ModOnboardingText.appLocalize)
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsRows?.update(status: self.enhancementStatus())
            self.onChange?()
        }
    }
}
