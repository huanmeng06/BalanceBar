import CryptoKit
import Foundation

/// Why the latest Claude official refresh did not produce new data.
enum ClaudeQuotaFailure: Equatable {
    case missingCredentials
    case rateLimited
    case unauthorized
    case transport(possibleProxy: Bool, description: String)
    case http(Int)
    case invalidResponse
}

/// Why a manual refresh would not reach the Usage API right now, for the refresh menu item.
enum ClaudeManualRefreshNotice: Equatable {
    /// The OAuth token was rejected (401); only a new credential from Claude Code lifts the pause.
    case loginExpired
    /// Waiting out a 429 until the given date.
    case rateLimited(until: Date)
    /// A read succeeded within the manual-refresh window.
    case justRefreshed
}

/// Everything the refresh coordinator needs to publish Claude official quota.
struct ClaudeQuotaState: Equatable {
    /// Merged display model owned by `QuotaMergeEngine`.
    let display: QuotaDisplayModel
    /// Card windows rebuilt from `display`; empty when nothing is known.
    let windows: [OfficialQuotaWindow]
    let accountEpoch: AccountEpoch
    /// Opaque account identity for notification progress; never credential material.
    let accountScope: String?
    /// Receipt time of the newest displayed official reading.
    let updatedAt: Date?
    let isRefreshing: Bool
    let failure: ClaudeQuotaFailure?
    /// Status-slot state resolved with BB-07's rules.
    let status: StatusSlotState
}

/// Forwards notification snapshots from the quota adapter to the existing rules.
/// The handler is attached by the refresh coordinator, which knows the Provider IDs.
final class ClaudeNotificationRouter: QuotaNotificationSnapshotProcessing {
    private let lock = NSLock()
    private var handler: ((Snapshot) -> Void)?

    var onSnapshot: ((Snapshot) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func process(snapshot: Snapshot, agent: BalanceNotificationAgent, providerID: String) {
        onSnapshot?(snapshot)
    }
}

/// Keeps the scheduler's persisted state readable from other threads, so the
/// menu can show the 429 wait without asking the scheduler queue.
final class ObservedFetchSchedulerStateStore: FetchSchedulerStateStoring {
    private let base: FetchSchedulerStateStoring
    private let lock = NSLock()
    private var latest = FetchSchedulerPersistentState()

    init(base: FetchSchedulerStateStoring) { self.base = base }

    var snapshot: FetchSchedulerPersistentState { lock.withLock { latest } }

    func load() -> FetchSchedulerPersistentState? {
        let loaded = base.load()
        if let loaded { lock.withLock { latest = loaded } }
        return loaded
    }

    func save(_ state: FetchSchedulerPersistentState) {
        lock.withLock { latest = state }
        base.save(state)
    }
}

/// Restores merge state only for the signed-in account and rebases its epoch.
///
/// Account epochs restart at zero on every launch, so a persisted epoch from an earlier run
/// would otherwise reject every new observation as stale.
final class RebasingMergeStore: QuotaMergeStateStoring {
    private let base: QuotaMergeStateStoring
    private let accountID: String?
    private let epoch: AccountEpoch

    init(base: QuotaMergeStateStoring, accountID: String?, epoch: AccountEpoch) {
        self.base = base
        self.accountID = accountID
        self.epoch = epoch
    }

    func load() -> QuotaMergeState? {
        guard let accountID, var state = base.load(), state.accountID == accountID else { return nil }
        state.epoch = epoch
        return state
    }

    func save(_ state: QuotaMergeState) { base.save(state) }
}

/// Lets other threads ask the merge engine whether a window waits for a reset confirmation.
final class ClaudeMergeEngineBox {
    private let lock = NSLock()
    private var engine: QuotaMergeEngine?

    func set(_ engine: QuotaMergeEngine) { lock.withLock { self.engine = engine } }

    /// `true` when a window passed its reset time, whether or not the engine has noticed yet.
    func hasPassedReset(at date: Date) -> Bool {
        guard let engine = lock.withLock({ self.engine }) else { return false }
        return engine.currentState.windows.values.contains { window in
            window.pendingResetOf != nil || (window.displayed?.resetsAt).map { $0 <= date } ?? false
        }
    }
}

/// Remembers when the trusted real-time source (the BalanceBar Mod, delivered through the snapshot inbox) last had an observation
/// accepted by the merge engine, so the scheduler can skip requests the local sources already answer.
///
/// Only accepted observations count: a snapshot rejected by the merge rules (another account, a stale
/// cycle) never suppresses a request. While a window waits for a reset confirmation nothing is trusted,
/// because only an official read can confirm the reset.
final class ClaudeRealtimeTracker: RealtimeSourceFreshnessProviding, ManualRefreshFreePathChecking {
    private let identity: AccountIdentityProviding
    private let now: () -> Date
    private let resetPassed: () -> Bool
    private let lock = NSLock()
    private var acceptedAt: Date?
    private var acceptedEpoch: AccountEpoch?
    private var acceptedSourceID: String?

    init(identity: AccountIdentityProviding, now: @escaping () -> Date, resetPassed: @escaping () -> Bool) {
        self.identity = identity
        self.now = now
        self.resetPassed = resetPassed
    }

    func recordAccepted(at date: Date, epoch: AccountEpoch, sourceID: String? = nil) {
        lock.withLock {
            acceptedAt = date
            acceptedEpoch = epoch
            acceptedSourceID = sourceID
        }
    }

    /// The source of the newest accepted real-time observation.
    var latestSourceID: String? { lock.withLock { acceptedSourceID } }

    func clear() {
        lock.withLock {
            acceptedAt = nil
            acceptedEpoch = nil
            acceptedSourceID = nil
        }
    }

    var lastTrustedRealtimeObservationAt: Date? {
        let (at, epoch) = lock.withLock { (acceptedAt, acceptedEpoch) }
        guard let at, epoch == identity.accountEpoch, !resetPassed() else { return nil }
        return at
    }

    /// Age of the newest accepted real-time reading for diagnostics: seconds, or "none". Ignores the reset and
    /// account checks, so a log line shows what was there even when it was not trusted.
    func ageDescription() -> String {
        guard let at = lock.withLock({ acceptedAt }) else { return "none" }
        return "\(Int(max(0, now().timeIntervalSince(at))))s"
    }

    /// `true` while the newest trusted observation is younger than `window`.
    func isFresh(within window: TimeInterval) -> Bool {
        guard let at = lastTrustedRealtimeObservationAt else { return false }
        let age = now().timeIntervalSince(at)
        return age >= 0 && age < window
    }

    func checkFreePath(within window: TimeInterval, completion: @escaping (Bool) -> Void) {
        completion(isFresh(within: window))
    }
}

/// Claude official quota path: account identity → scheduler → merge engine → status and notifications.
///
/// All file, Keychain and merge-state work happens on private background queues; `latestState`
/// and the other accessors only read memory. The coordinator observes `onUpdate`.
final class ClaudeQuotaPipeline {
    /// Source label recorded on observations from the OAuth usage endpoint.
    static let sourceID = "oauth-api"

    private let client: OfficialQuotaClient
    private let identity: ClaudeAccountIdentityProvider
    private let identityQueue: DispatchQueue
    private let stateStore: ObservedFetchSchedulerStateStore
    private let mergeFileStore: QuotaMergeFileStore
    private let notificationRouter = ClaudeNotificationRouter()
    private let now: () -> Date
    private let manualRefreshWindow: TimeInterval
    private let diagnostics: (String, SwitchLog.Level) -> Void
    private let realtimeSources: [QuotaSource]
    private let realtime: ClaudeRealtimeTracker
    private let engineBox = ClaudeMergeEngineBox()
    private let realtimeFreshnessWindow: TimeInterval
    private let queue = DispatchQueue(label: "BalanceBar.ClaudeQuotaPipeline", qos: .utility)
    /// Identifies the newest scheduled "real-time reading expired" republish; older ones do nothing.
    private var expiryToken = UUID()
    private let lock = NSLock()

    private var scheduler: FetchScheduler!
    private var engine: QuotaMergeEngine?
    private var adapter: QuotaNotificationAdapter?
    private var observerToken: AnyObject?
    private var started = false
    private var pendingReasons: [FetchRequestReason] = []
    private var failure: ClaudeQuotaFailure?
    private var refreshing = false
    private var lastClientError: OfficialQuotaClientError?
    private var lastSuccessAt: Date?
    private var state: ClaudeQuotaState?

    /// Called on the pipeline queue whenever the published state changes.
    var onUpdate: ((ClaudeQuotaState) -> Void)? {
        get { lock.withLock { updateHandler } }
        set { lock.withLock { updateHandler = newValue } }
    }
    private var updateHandler: ((ClaudeQuotaState) -> Void)?

    /// - Parameters:
    ///   - realtimeSources: Local real-time sources (in production only the Mod's snapshot inbox). They start with the pipeline
    ///     and deliver grade-B observations to the merge engine.
    ///   - calibrationIntervalCap: Upper bound for how long a fresh real-time source may suppress requests.
    ///   - diagnostics: Receives scheduler skip reasons; production writes them to `SwitchLog`.
    init(
        client: OfficialQuotaClient,
        identity: ClaudeAccountIdentityProvider,
        identityQueue: DispatchQueue,
        stateDirectory: URL,
        realtimeSources: [QuotaSource] = [],
        calibrationIntervalCap: @escaping () -> TimeInterval? = { nil },
        schedulerClock: SchedulerClock = SystemSchedulerClock(),
        schedulerTimer: SchedulerTimer = DispatchSchedulerTimer(),
        schedulerConfiguration: FetchSchedulerConfiguration = FetchSchedulerConfiguration(),
        now: @escaping () -> Date = Date.init,
        diagnostics: @escaping (String, SwitchLog.Level) -> Void = { message, level in
            SwitchLog.write(message, level: level, category: "refresh.claude")
        }
    ) {
        self.client = client
        self.realtimeSources = realtimeSources
        realtimeFreshnessWindow = schedulerConfiguration.realtimeSourceFreshness
        realtime = ClaudeRealtimeTracker(
            identity: identity, now: now, resetPassed: { [engineBox, now] in engineBox.hasPassedReset(at: now()) })
        manualRefreshWindow = schedulerConfiguration.manualRefreshWindow
        self.diagnostics = diagnostics
        self.identity = identity
        self.identityQueue = identityQueue
        self.now = now
        stateStore = ObservedFetchSchedulerStateStore(
            base: FileFetchSchedulerStateStore(fileURL: stateDirectory.appendingPathComponent("claude-fetch-scheduler.json")))
        mergeFileStore = QuotaMergeFileStore(url: stateDirectory.appendingPathComponent("claude-quota-merge.json"))
        scheduler = FetchScheduler(
            transport: ClaudeUsageTransport(pipeline: self),
            identity: identity,
            stateStore: stateStore,
            clock: schedulerClock,
            timer: schedulerTimer,
            freePathChecker: realtime,
            realtimeFreshness: realtime,
            calibrationIntervalCap: calibrationIntervalCap,
            configuration: schedulerConfiguration,
            logSink: { [weak self] event in self?.schedulerEvent(event) })
        scheduler.addResultHandler { [weak self] delivery in
            self?.queue.async { self?.handle(delivery) }
        }
    }

    /// Why and when the next official read can happen, for Settings. Cheap enough to call once a second.
    func refreshStatus() -> ClaudeRefreshStatus? {
        guard let scheduler else { return nil }
        return ClaudeRefreshStatus(
            scheduler: scheduler.statusSnapshot(),
            realtimeAt: realtime.lastTrustedRealtimeObservationAt,
            realtimeFreshnessWindow: realtimeFreshnessWindow)
    }

    deinit {
        realtimeSources.forEach { $0.stop() }
        identity.stopMonitoring()
    }

    /// Called on the pipeline queue for every observation the local real-time sources delivered, with whether
    /// the merge engine accepted it (for example to remember when the Mod last delivered data).
    var realtimeObserver: ((QuotaObservation, Bool) -> Void)? {
        get { lock.withLock { observerHandler } }
        set { lock.withLock { observerHandler = newValue } }
    }
    private var observerHandler: ((QuotaObservation, Bool) -> Void)?

    /// Production snapshot inbox, kept for health reporting.
    private(set) var snapshotInbox: SnapshotInbox?

    /// Receives official snapshots that passed the notification adapter's rules.
    var onNotification: ((Snapshot) -> Void)? {
        get { notificationRouter.onSnapshot }
        set { notificationRouter.onSnapshot = newValue }
    }

    /// Most recent published state, or `nil` before the engine is ready.
    var latestState: ClaudeQuotaState? { lock.withLock { state } }

    /// End of the 429 wait, when a manual refresh could only be skipped.
    func manualRefreshBlockedUntil() -> Date? {
        guard let until = stateStore.snapshot.cooldownUntil, until > now() else { return nil }
        return until
    }

    /// Why a manual refresh would be skipped right now, in the scheduler's own precedence.
    /// Reads memory only, so the menu can ask while it validates its items.
    func manualRefreshNotice() -> ClaudeManualRefreshNotice? {
        if stateStore.snapshot.isUnauthorizedPaused { return .loginExpired }
        if let until = manualRefreshBlockedUntil() { return .rateLimited(until: until) }
        if let at = lock.withLock({ lastSuccessAt }), now().timeIntervalSince(at) < manualRefreshWindow {
            return .justRefreshed
        }
        // A local real-time source answered within the window, so a manual read would be skipped.
        if realtime.isFresh(within: manualRefreshWindow) { return .justRefreshed }
        return nil
    }

    /// Whether "Refresh Now" would read right now, from the scheduler's own snapshot. Briefly waits on the scheduler
    /// queue, like the Settings status; never call it from there.
    func manualRefreshAvailability() -> ClaudeRefreshStatus.ManualRefresh? {
        refreshStatus()?.manualRefresh(now: now())
    }

    /// Starts account monitoring and builds the merge engine off the caller's thread.
    func start() {
        queue.async { [self] in startOnQueue() }
    }

    /// Asks the scheduler for a read. Credentials are re-read first so the scheduler judges
    /// the 401 pause against the current credential version.
    func requestFetch(reason: FetchRequestReason) {
        queue.async { [self] in
            guard engine != nil else {
                pendingReasons.append(reason)
                startOnQueue()
                return
            }
            prepareAndRequest(reason)
        }
    }

    /// Re-evaluates reset deadlines; may ask the scheduler to confirm a reset.
    func tick() {
        queue.async { [self] in
            guard let engine else { return }
            engine.refresh()
            publish()
        }
    }

    /// Blocks until queued pipeline work has run. Intended for tests and shutdown.
    func waitUntilIdle() {
        queue.sync {}
        identityQueue.sync {}
        scheduler.waitUntilIdle()
        queue.sync {}
    }

    /// Flushes the merge state to disk. Intended for tests and shutdown.
    func flush() {
        queue.sync {}
        mergeFileStore.flush()
    }

    // MARK: - Pipeline queue

    private func startOnQueue() {
        guard !started else { return }
        started = true
        identity.startMonitoring()
        // Monitoring's first read is queued on the identity queue; wait for it so the
        // persisted state is matched against the real account.
        identityQueue.sync {}
        observerToken = identity.addObserver { [weak self] change in
            self?.queue.async { self?.identityChanged(change) }
        }
        let restoring = RebasingMergeStore(
            base: mergeFileStore, accountID: identity.accountIdentity?.stableID, epoch: identity.accountEpoch)
        let adapter = QuotaNotificationAdapter(processor: notificationRouter, providerID: "claude")
        self.adapter = adapter
        let mergeEngine = QuotaMergeEngine(scheduler: scheduler, notifications: adapter, store: restoring, now: now)
        engine = mergeEngine
        engineBox.set(mergeEngine)
        publish()
        for source in realtimeSources {
            source.start(receiving: { [weak self] observation in self?.receive(observation) })
        }
        let reasons = pendingReasons
        pendingReasons.removeAll()
        if let reason = reasons.min(by: { $0.rawValue < $1.rawValue }) { prepareAndRequest(reason) }
    }

    /// Entry for observations from the local real-time sources; they arrive on the sources' own queues.
    private func receive(_ observation: QuotaObservation) {
        queue.async { [self] in
            guard let engine else { return }
            engine.merge(observation)
            // Only a reading the merge rules actually displayed counts as a trusted real-time answer.
            let displayed = engine.currentState.windows[observation.window.rawValue]?.displayed
            let accepted = displayed?.receivedAt == observation.receivedAt && displayed?.source == observation.source
            if accepted { realtime.recordAccepted(at: now(), epoch: observation.epoch, sourceID: observation.source) }
            self.realtimeObserver?(observation, accepted)
            if let account = identity.accountIdentity {
                adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: account))
            }
            publish()
        }
    }

    private func prepareAndRequest(_ reason: FetchRequestReason) {
        // While a live local source answers, an automatic read is skipped anyway, so the credential
        // probe (a Keychain read) is not worth its cost. A read that does go through (the calibration
        // cap) reads and ingests the token itself.
        let answeredLive = reason != .manual && reason != .initial
            && realtime.isFresh(within: realtimeFreshnessWindow)
        if !answeredLive {
            let epoch = identity.accountEpoch
            let token = client.claudeRequestCredentials(cacheFor: 2).accessToken
            identity.ingestCredential(accessToken: token, expectedEpoch: epoch)
            identityQueue.sync {}
        }
        scheduler.requestFetch(reason: reason)
    }

    private func identityChanged(_ change: AccountIdentityChange) {
        guard change.accountChanged, let engine else { return }
        engine.accountDidChange(epoch: change.epoch, accountID: change.identity?.stableID)
        realtime.clear()
        lock.withLock {
            failure = nil
            refreshing = false
            lastSuccessAt = nil
        }
        adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: change.identity))
        publish()
        if change.identity != nil { requestForNewAccount() }
    }

    /// The scheduler's automatic minimum interval spans accounts, so a new account would
    /// wait for the previous account's interval. A manual-class read is epoch-aware instead.
    private func requestForNewAccount() {
        prepareAndRequest(.manual)
    }

    private func handle(_ delivery: FetchSchedulerDelivery) {
        guard let engine else { return }
        var newFailure: ClaudeQuotaFailure?
        switch delivery.result {
        case let .success(data):
            lock.withLock { lastSuccessAt = delivery.receivedAt }
            newFailure = merge(data, delivery: delivery, into: engine)
        case .rateLimited:
            newFailure = .rateLimited
        case .unauthorized:
            newFailure = .unauthorized
        case .failure:
            newFailure = Self.failure(from: lock.withLock { lastClientError })
        }
        lock.withLock {
            failure = newFailure
            refreshing = false
        }
        publish()
    }

    private func merge(_ data: Data, delivery: FetchSchedulerDelivery, into engine: QuotaMergeEngine) -> ClaudeQuotaFailure? {
        guard identity.accountEpoch == delivery.epoch else { return nil }
        guard let account = identity.accountIdentity else { return .missingCredentials }
        guard let readings = try? OfficialQuotaResponseParser.claudeReadings(data: data, now: delivery.receivedAt) else {
            return .invalidResponse
        }
        for reading in readings {
            guard let observation = QuotaObservation(
                window: reading.quotaKind,
                usedPercentage: reading.usedPercentage,
                resetsAt: reading.resetsAt,
                receivedAt: delivery.receivedAt,
                source: Self.sourceID,
                trust: .a,
                accountID: account.stableID,
                epoch: delivery.epoch) else { continue }
            engine.merge(observation)
        }
        adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: account))
        return nil
    }

    private func schedulerEvent(_ event: FetchSchedulerLogEvent) {
        switch event.kind {
        case .dispatched:
            let reasons = event.reasons.map { String(describing: $0) }.joined(separator: ",")
            diagnostics("claude fetch dispatched; reasons=\(reasons); tokens=\(event.tokens); live_age=\(realtime.ageDescription())", .info)
            queue.async { [self] in
                lock.withLock { refreshing = true }
                publish()
            }
        case .discardedStaleEpoch:
            // The request belonged to an account that is no longer signed in; the
            // current account's own read was coalesced into it, so repeat that read.
            queue.async { [self] in
                lock.withLock { refreshing = false }
                publish()
                if identity.accountIdentity != nil { requestForNewAccount() }
            }
        case .skipped:
            logSkip(event)
            // A skipped read is the only signal after a restart that the persisted 401 pause or
            // 429 cooldown still applies, so surface it instead of leaving the card unchanged.
            let skipFailure: ClaudeQuotaFailure?
            switch event.skipReason {
            case .unauthorizedPaused?: skipFailure = .unauthorized
            case .cooldown?: skipFailure = .rateLimited
            default: skipFailure = nil
            }
            guard let skipFailure else { return }
            queue.async { [self] in
                lock.withLock { failure = skipFailure }
                publish()
            }
        case .completed:
            // Without the outcome, a read that failed quietly (a transport error) is indistinguishable from one
            // still in flight; "last read" in Settings only moves on success.
            let outcome = event.outcome ?? "unknown"
            diagnostics("claude fetch completed; outcome=\(outcome); tokens=\(event.tokens)", outcome == "success" ? .debug : .warning)
        case .requested:
            break
        }
    }

    private func logSkip(_ event: FetchSchedulerLogEvent) {
        let reasons = event.reasons.map { String(describing: $0) }.joined(separator: ",")
        let skip = event.skipReason.map { String(describing: $0) } ?? "unknown"
        let cooldown = Int(event.cooldownRemaining.rounded(.up))
        diagnostics(
            "claude fetch skipped; skip=\(skip); reasons=\(reasons); cooldown_remaining=\(cooldown)s; tokens=\(event.tokens); live_age=\(realtime.ageDescription())",
            event.reasons.contains(.manual) ? .info : .debug)
    }

    private func publish() {
        guard let engine else { return }
        let model = engine.displayModel
        let merged = engine.currentState
        let date = now()
        let updatedAt = merged.windows.values.compactMap { $0.displayed?.receivedAt }.max()
        let (failure, refreshing, handler) = lock.withLock { (self.failure, self.refreshing, updateHandler) }
        // A failure marks the displayed values as outdated without discarding them.
        let shown = failure == nil ? model : QuotaDisplayModel(
            windows: model.windows, isEstimated: model.isEstimated, state: .error, hoverTextKey: model.hoverTextKey)
        let source: StatusSlotSource = realtime.isFresh(within: realtimeFreshnessWindow) ? .realtime : .official
        if source == .realtime { scheduleRealtimeExpiryRepublish(date: date) }
        let status = StatusSlotState.resolve(
            model: shown,
            context: StatusSlotContext(
                isRefreshing: refreshing, source: source, updatedAt: updatedAt,
                realtimeFromMod: realtime.latestSourceID == ModOnboardingConfig.modSourceID))
        let next = ClaudeQuotaState(
            display: model,
            windows: Self.cardWindows(from: model, now: date),
            accountEpoch: identity.accountEpoch,
            accountScope: Self.accountScope(for: identity.accountIdentity),
            updatedAt: updatedAt,
            isRefreshing: refreshing,
            failure: failure,
            status: status)
        let changed = lock.withLock { () -> Bool in
            guard state != next else { return false }
            state = next
            return true
        }
        if changed { handler?(next) }
    }

    /// The status slot shows "Live" only while the reading is fresh, but nothing else changes when it goes stale:
    /// publish once more just after it expires so the card stops claiming "Live".
    private func scheduleRealtimeExpiryRepublish(date: Date) {
        guard let at = realtime.lastTrustedRealtimeObservationAt else { return }
        let remaining = max(0, realtimeFreshnessWindow - date.timeIntervalSince(at))
        let token = UUID()
        lock.withLock { expiryToken = token }
        queue.asyncAfter(deadline: .now() + remaining + 0.25) { [weak self] in
            guard let self, self.lock.withLock({ self.expiryToken }) == token else { return }
            self.publish()
        }
    }

    // MARK: - Pure helpers

    private static let windowOrder = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]

    static func cardWindows(from model: QuotaDisplayModel, now: Date) -> [OfficialQuotaWindow] {
        model.windows
            .compactMap { display -> (Int, OfficialQuotaWindow)? in
                guard let used = display.usedPercentage,
                      let window = OfficialQuotaResponseParser.claudeWindow(
                        for: display.kind, usedPercentage: used, resetsAt: display.resetsAt, now: now),
                      let order = windowOrder.firstIndex(of: display.kind.rawValue) else { return nil }
                return (order, window)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Notification scope: the email hash when known (stable across account-file formats), else the stable ID hash.
    static func accountScope(for identity: AccountIdentity?) -> String? {
        guard let identity else { return nil }
        let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let basis = email.isEmpty ? identity.stableID : email
        return "account:" + SHA256.hash(data: Data(basis.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(from error: OfficialQuotaClientError?) -> ClaudeQuotaFailure {
        switch error {
        case .missingCredentials?, nil: return .missingCredentials
        case let .transport(transport)?:
            if case .possibleProxy = transport {
                return .transport(possibleProxy: true, description: transport.localizedDescription)
            }
            return .transport(possibleProxy: false, description: transport.localizedDescription)
        case let .httpStatus(status, _)?: return .http(status)
        case .invalidJSON?, .unsupportedFormat?: return .invalidResponse
        }
    }

    fileprivate func recordClientError(_ error: OfficialQuotaClientError?) {
        lock.withLock { lastClientError = error }
    }

    fileprivate func recordCredentialRead(_ token: String, epoch: AccountEpoch) {
        identity.ingestCredential(accessToken: token, expectedEpoch: epoch)
    }

    fileprivate var hasAccount: Bool { identity.accountIdentity != nil }
    fileprivate var currentEpoch: AccountEpoch { identity.accountEpoch }
    fileprivate var transportClient: OfficialQuotaClient { client }
}

/// Scheduler transport that performs the single Claude usage request.
private final class ClaudeUsageTransport: UsageFetchTransport {
    private weak var pipeline: ClaudeQuotaPipeline?

    init(pipeline: ClaudeQuotaPipeline) { self.pipeline = pipeline }

    func fetchUsage(completion: @escaping (UsageFetchResult) -> Void) {
        guard let pipeline else { return completion(.failure("pipeline_released")) }
        guard pipeline.hasAccount else {
            pipeline.recordClientError(.missingCredentials)
            completion(.failure("missing_account"))
            return
        }
        let epoch = pipeline.currentEpoch
        pipeline.transportClient.fetchClaudeUsage(
            didReadToken: { pipeline.recordCredentialRead($0, epoch: epoch) },
            completion: { result, error in
                pipeline.recordClientError(error)
                completion(result)
            })
    }
}

extension ClaudeQuotaPipeline {
    /// Production wiring: `~/.claude.json` identity, the BalanceBar Mod snapshot inbox as the only real-time source, state under
    /// Application Support. Nothing is read or watched until the first Claude read is requested.
    static func makeProduction(
        client: OfficialQuotaClient,
        calibrationIntervalCap: @escaping () -> TimeInterval? = { QuotaConstants.realtimeCalibrationInterval }
    ) -> ClaudeQuotaPipeline {
        let identityQueue = DispatchQueue(label: "BalanceBar.AccountIdentity", qos: .utility)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BalanceBar", isDirectory: true)
            .appendingPathComponent("Quota", isDirectory: true)
        let identity = ClaudeAccountIdentityProvider(workQueue: identityQueue)
        let inbox = SnapshotInbox(identity: identity)
        let pipeline = ClaudeQuotaPipeline(
            client: client,
            identity: identity,
            identityQueue: identityQueue,
            stateDirectory: directory,
            realtimeSources: [inbox],
            calibrationIntervalCap: calibrationIntervalCap)
        pipeline.snapshotInbox = inbox
        return pipeline
    }
}
