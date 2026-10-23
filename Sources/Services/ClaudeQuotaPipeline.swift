import CryptoKit
import Foundation
import AppKit

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
    case localFresh
    case recentResult(until: Date)
    case inFlight
    case networkUnavailable
    case succeeded
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
private final class RebasingMergeStore: QuotaMergeStateStoring {
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
    private let realtimeTracker: ClaudeRealtimeTracker?
    private let statusLineSource: ClaudeStatusLineSource?
    fileprivate let now: () -> Date
    private let manualRefreshWindow: TimeInterval
    private let diagnostics: (String, SwitchLog.Level) -> Void
    private let queue = DispatchQueue(label: "BalanceBar.ClaudeQuotaPipeline", qos: .utility)
    private let lock = NSLock()

    private var scheduler: FetchScheduler!
    private var engine: QuotaMergeEngine?
    private var adapter: QuotaNotificationAdapter?
    private var observerToken: AnyObject?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var statusLineEnabled = false
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
    ///   - calibrationIntervalCap: Upper bound for how long a fresh real-time source may suppress requests.
    ///   - diagnostics: Receives scheduler skip reasons; production writes them to `SwitchLog`.
    init(
        client: OfficialQuotaClient,
        identity: ClaudeAccountIdentityProvider,
        identityQueue: DispatchQueue,
        stateDirectory: URL,
        calibrationIntervalCap: @escaping () -> TimeInterval? = { nil },
        schedulerClock: SchedulerClock = SystemSchedulerClock(),
        schedulerTimer: SchedulerTimer = DispatchSchedulerTimer(),
        schedulerConfiguration: FetchSchedulerConfiguration = FetchSchedulerConfiguration(),
        realtimeTracker: ClaudeRealtimeTracker? = nil,
        statusLineSource: ClaudeStatusLineSource? = nil,
        statusLineEnabled: Bool = false,
        now: @escaping () -> Date = Date.init,
        diagnostics: @escaping (String, SwitchLog.Level) -> Void = { message, level in
            SwitchLog.write(message, level: level, category: "refresh.claude")
        }
    ) {
        self.client = client
        manualRefreshWindow = schedulerConfiguration.manualRefreshWindow
        self.diagnostics = diagnostics
        self.identity = identity
        self.identityQueue = identityQueue
        self.now = now
        self.realtimeTracker = realtimeTracker
        self.statusLineSource = statusLineSource
        self.statusLineEnabled = statusLineEnabled
        stateStore = ObservedFetchSchedulerStateStore(
            base: FileFetchSchedulerStateStore(fileURL: stateDirectory.appendingPathComponent("claude-fetch-scheduler.json")))
        mergeFileStore = QuotaMergeFileStore(url: stateDirectory.appendingPathComponent("claude-quota-merge.json"))
        scheduler = FetchScheduler(
            transport: ClaudeUsageTransport(pipeline: self),
            identity: identity,
            stateStore: stateStore,
            clock: schedulerClock,
            timer: schedulerTimer,
            freePathChecker: statusLineSource,
            realtimeFreshness: realtimeTracker,
            calibrationIntervalCap: calibrationIntervalCap,
            configuration: schedulerConfiguration,
            logSink: { [weak self] event in self?.schedulerEvent(event) })
        scheduler.addResultHandler { [weak self] delivery in
            self?.queue.async { self?.handle(delivery) }
        }
        // The scheduler's own timer goes through the same credential read as every other
        // request, so a new login is noticed even while a 401 pause holds.
        scheduler.setAutomaticTrigger { [weak self] in
            self?.queue.async { self?.prepareAndRequest(.scheduled) }
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        statusLineSource?.stop()
        identity.stopMonitoring()
    }

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
        // Native data can make a server read unnecessary before the OAuth success window ends.
        if realtimeTracker?.lastTrustedRealtimeObservationAt != nil {
            return .localFresh
        }
        if let at = lock.withLock({ lastSuccessAt }), now().timeIntervalSince(at) < manualRefreshWindow {
            return .justRefreshed
        }
        return nil
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

    /// Enables scheduler-owned automatic calibration while Claude is being monitored.
    func setDemand(_ enabled: Bool) {
        scheduler.setDemand(enabled)
    }

    func schedulerStatus() -> FetchSchedulerStatus {
        scheduler.statusSnapshot()
    }

    func setStatusLineEnabled(_ enabled: Bool) {
        queue.async { [self] in
            statusLineEnabled = enabled
            guard let statusLineSource else { return }
            if enabled {
                statusLineSource.start { [weak self] observation in
                    self?.queue.async { self?.receiveNative(observation) }
                }
            } else {
                statusLineSource.stop()
                realtimeTracker?.reset(epoch: identity.accountEpoch)
            }
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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.scheduler.rearm()
        }
        let restoring = RebasingMergeStore(
            base: mergeFileStore, accountID: identity.accountIdentity?.stableID, epoch: identity.accountEpoch)
        let adapter = QuotaNotificationAdapter(processor: notificationRouter, providerID: "claude")
        self.adapter = adapter
        engine = QuotaMergeEngine(scheduler: scheduler, notifications: adapter, store: restoring, now: now)
        if statusLineEnabled, let statusLineSource {
            statusLineSource.start { [weak self] observation in
                self?.queue.async { self?.receiveNative(observation) }
            }
        }
        publish()
        let reasons = pendingReasons
        pendingReasons.removeAll()
        if let reason = reasons.min(by: { $0.rawValue < $1.rawValue }) { prepareAndRequest(reason) }
    }

    private func prepareAndRequest(_ reason: FetchRequestReason) {
        let epoch = identity.accountEpoch
        let token = client.claudeRequestCredentials(cacheFor: 2).accessToken
        identity.ingestCredential(accessToken: token, expectedEpoch: epoch)
        identityQueue.sync {}
        scheduler.requestFetch(reason: reason)
    }

    private func identityChanged(_ change: AccountIdentityChange) {
        guard change.accountChanged, let engine else { return }
        engine.accountDidChange(epoch: change.epoch, accountID: change.identity?.stableID)
        realtimeTracker?.reset(epoch: change.epoch)
        statusLineSource?.accountDidChange(epoch: change.epoch)
        lock.withLock {
            failure = nil
            refreshing = false
            lastSuccessAt = nil
        }
        adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: change.identity))
        publish()
        if change.identity != nil { requestForNewAccount() }
    }

    private func receiveNative(_ observation: QuotaObservation) {
        guard let engine else { return }
        _ = engine.merge(observation)
        let displayed = engine.currentState.windows[observation.window.rawValue]?.displayed
        if displayed?.source == observation.source,
           displayed?.receivedAt == observation.receivedAt {
            realtimeTracker?.recordTrustedObservation(
                window: observation.window, receivedAt: observation.receivedAt, epoch: observation.epoch)
        }
        realtimeTracker?.markPendingReset(engine.currentState.windows.values.contains { $0.pendingResetOf != nil })
        publish()
    }

    /// A new account must be read immediately, subject only to auth, cooldown, budget and
    /// failure-backoff constraints.
    private func requestForNewAccount() {
        prepareAndRequest(.accountChanged)
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
        statusLineSource?.setGradeAResets(Dictionary(uniqueKeysWithValues: readings.map {
            ($0.quotaKind, $0.resetsAt)
        }))
        realtimeTracker?.markPendingReset(engine.currentState.windows.values.contains { $0.pendingResetOf != nil })
        adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: account))
        return nil
    }

    private func schedulerEvent(_ event: FetchSchedulerLogEvent) {
        switch event.kind {
        case .dispatched:
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
        case .requested, .completed:
            break
        }
    }

    private func logSkip(_ event: FetchSchedulerLogEvent) {
        let reasons = event.reasons.map { String(describing: $0) }.joined(separator: ",")
        let skip = event.skipReason.map { String(describing: $0) } ?? "unknown"
        let cooldown = Int(event.cooldownRemaining.rounded(.up))
        diagnostics(
            "claude fetch skipped; skip=\(skip); reasons=\(reasons); cooldown_remaining=\(cooldown)s; tokens=\(event.tokens)",
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
        let nativeDisplayed = statusLineSource != nil
            && realtimeTracker?.lastTrustedRealtimeObservationAt != nil
            && engine.currentState.windows[QuotaWindowKind.fiveHour.rawValue]?.displayed?.source == ClaudeStatusLineSource.identifier
            && engine.currentState.windows[QuotaWindowKind.sevenDay.rawValue]?.displayed?.source == ClaudeStatusLineSource.identifier
        let status = StatusSlotState.resolve(
            model: shown,
            context: StatusSlotContext(isRefreshing: refreshing,
                source: nativeDisplayed ? .realtime : .official, updatedAt: updatedAt))
        let next = ClaudeQuotaState(
            display: model,
            windows: DevelopmentClaudeIdleDemo.windows() ?? Self.cardWindows(from: model, now: date),
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
                guard case let .success(data) = result else {
                    completion(result)
                    return
                }
                do {
                    _ = try OfficialQuotaResponseParser.claudeReadings(data: data, now: pipeline.now())
                    completion(.success(data))
                } catch {
                    pipeline.recordClientError(.unsupportedFormat(dataSize: data.count))
                    completion(.failure("invalid_response"))
                }
            })
    }
}

extension ClaudeQuotaPipeline {
    /// Production wiring: `~/.claude.json` identity, state under Application Support.
    /// Nothing is read or watched until the first Claude read is requested.
    static func makeProduction(
        client: OfficialQuotaClient,
        calibrationIntervalCap: @escaping () -> TimeInterval?
    ) -> ClaudeQuotaPipeline {
        let identityQueue = DispatchQueue(label: "BalanceBar.AccountIdentity", qos: .utility)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BalanceBar", isDirectory: true)
            .appendingPathComponent("Quota", isDirectory: true)
        let identity = ClaudeAccountIdentityProvider(workQueue: identityQueue)
        let tracker = ClaudeRealtimeTracker(now: Date.init)
        let source = ClaudeStatusLineSource(accountProvider: identity, tracker: tracker)
        return ClaudeQuotaPipeline(
            client: client,
            identity: identity,
            identityQueue: identityQueue,
            stateDirectory: directory,
            calibrationIntervalCap: calibrationIntervalCap,
            schedulerConfiguration: .claudeV1,
            realtimeTracker: tracker,
            statusLineSource: source)
    }
}

/// Supplies an untouched (100%, no server reset) Claude quota only to the
/// explicitly named demo bundle. Normal bundles return nil.
enum DevelopmentClaudeIdleDemo {
    private static let infoPlistKey = "BalanceBarClaudeIdleDemo"

    static func windows() -> [OfficialQuotaWindow]? {
        guard Bundle.main.bundleIdentifier?.contains(".demo.") == true,
              Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String == "claude-idle" else { return nil }
        return [
            OfficialQuotaWindow(kind: .fiveHour, remaining: 100, label: tr(.keyResponseParsers5HourQuota),
                daysText: tr(.keyResponseParsers5Hours), reset: "5h0m", durationSeconds: 5 * 3_600),
            OfficialQuotaWindow(kind: .sevenDay, remaining: 100, label: tr(.keyResponseParsers7DayQuota),
                daysText: tr(.keyResponseParsers7Days), reset: "7d0h", durationSeconds: 7 * 86_400)
        ]
    }
}
