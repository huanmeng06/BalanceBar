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
    /// A reset passed and is awaiting official confirmation; a manual refresh asks the
    /// Usage API directly instead of being suppressed by the recent-result window.
    case awaitingResetConfirmation
    /// The request budget is exhausted; the next token arrives at the given date.
    case outOfTokens(until: Date)
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
    /// Lowercased account email; scopes quota prediction evidence to this
    /// account and matches the menu card's account presentation.
    let predictionAccountKey: String?
    /// Journal identity for that evidence: the stable account ID (account +
    /// organization UUID), so same-email Claude accounts stay isolated. Nil
    /// whenever the email key is nil; evidence is only kept when the menu
    /// can later match it.
    let predictionEvidenceKey: String?
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
    private let sourceValidity: () -> ClaudeSourceValidity
    /// Recent source activity for the Advanced settings timeline; observation only.
    let sourceTimeline: ClaudeSourceTimeline
    private let snapshotInbox: SnapshotInbox?
    private let confirmationTimer: SchedulerTimer
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
    private var pendingReasons: [FetchRequestReason] = []
    private var failure: ClaudeQuotaFailure?
    /// Start of the current unbroken run of failed official reads; nil while none is failing.
    private var failureSince: Date?
    private var refreshing = false
    private var lastClientError: OfficialQuotaClientError?
    private var lastSuccessAt: Date?
    /// When the active account was first seen by this process; Mod snapshots produced earlier
    /// cannot be attributed to it without an official baseline.
    private var accountActiveSince: Date
    private var state: ClaudeQuotaState?
    /// Set while the Mod is known to be uninstalled or disabled (its lifecycle, not its data
    /// validity): its readings keep their value and time but are neither live nor fresh
    /// scheduler evidence. Cleared only by a Mod snapshot produced after this moment, so a
    /// reinstall never revives the old evidence. Guarded by `lock`.
    private var modSuspendedAt: Date?
    /// When detection last confirmed the suspended Mod installed and enabled; nil while it is
    /// not. Only snapshots produced after this moment may resume live status, so data written
    /// while the Mod was off (and rescanned later) never does.
    private var modAvailableSince: Date?
    /// Newest Mod snapshot per window that was produced after the suspension but arrived before
    /// detection confirmed the Mod available; the detection it triggered may resume live status
    /// with it. A verdict of "unavailable" drops the candidates it covers; an account change drops all.
    private var modResumeCandidates: [QuotaWindowKind: QuotaObservation] = [:]
    /// Production time of the newest snapshot an "unavailable" verdict has covered: a rescan of
    /// the same file (or anything older) is not a candidate again, so a stray snapshot cannot
    /// keep re-triggering detections.
    private var modCandidateFloor: Date?
    /// Whether any window is awaiting official reset confirmation (pipeline queue).
    private var awaitingResetConfirmation = false
    /// Confirmation requests already repeated by the retry timer in the current pending period.
    private var resetConfirmationAttempts = 0
    private var resetConfirmationTimerGeneration = 0

    /// Retry cadence for official reset confirmation: 1 → 2 → 5 minutes, then every 5 minutes.
    private static let resetConfirmationRetryDelays: [TimeInterval] = [60, 120, 300]

    /// Called on the pipeline queue whenever the published state changes.
    var onUpdate: ((ClaudeQuotaState) -> Void)? {
        get { lock.withLock { updateHandler } }
        set { lock.withLock { updateHandler = newValue } }
    }
    private var updateHandler: ((ClaudeQuotaState) -> Void)?

    /// What happened to one BalanceBar Mod snapshot; consumed by the settings entry's
    /// status display (`ModSyncStatus`). The rejection variants are decided by the inbox
    /// before emission, the processed variant by the merge engine.
    struct ModSnapshotEvent: Equatable {
        enum Kind: Equatable {
            /// The snapshot reached the merge engine; `accepted` says whether it is now
            /// displayed (the only thing that counts as trusted real-time evidence).
            case processed(accepted: Bool)
            /// The inbox refused to emit the snapshot at all.
            case rejected(reason: SnapshotRejectionReason)
            /// The signed-in account changed: the settings entry must drop all snapshot
            /// evidence gathered for the previous account.
            case accountChanged
        }

        var kind: Kind
        var window: QuotaWindowKind?
        var observedAt: Date?
        var receivedAt: Date
    }

    /// Called on pipeline/inbox background queues after each Mod snapshot outcome.
    /// Pure notification: merge, scheduling and acceptance decisions are untouched.
    var modSnapshotEventSink: ((ModSnapshotEvent) -> Void)? {
        get { lock.withLock { modSnapshotEventHandler } }
        set { lock.withLock { modSnapshotEventHandler = newValue } }
    }
    private var modSnapshotEventHandler: ((ModSnapshotEvent) -> Void)?

    /// Asks the settings coordinator for a Mod availability check (forced, no polling). Fired
    /// on the pipeline queue once per snapshot produced after the suspension that arrives while
    /// the Mod is not yet confirmed available. The coordinator serializes checks and queues one
    /// follow-up when a check is already running, so a request is never lost.
    var modDetectionRequester: (() -> Void)? {
        get { lock.withLock { modDetectionRequestHandler } }
        set { lock.withLock { modDetectionRequestHandler = newValue } }
    }
    private var modDetectionRequestHandler: (() -> Void)?

    /// - Parameters:
    ///   - calibrationIntervalCap: Upper bound for how long a fresh real-time source may suppress requests.
    ///   - diagnostics: Receives scheduler skip reasons; production writes them to `SwitchLog`.
    init(
        client: OfficialQuotaClient,
        identity: ClaudeAccountIdentityProvider,
        identityQueue: DispatchQueue,
        stateDirectory: URL,
        calibrationIntervalCap: @escaping () -> TimeInterval? = { nil },
        automaticInterval: @escaping () -> TimeInterval? = { nil },
        schedulerClock: SchedulerClock = SystemSchedulerClock(),
        schedulerTimer: SchedulerTimer = DispatchSchedulerTimer(),
        confirmationTimer: SchedulerTimer = DispatchSchedulerTimer(),
        schedulerConfiguration: FetchSchedulerConfiguration = FetchSchedulerConfiguration(),
        realtimeTracker: ClaudeRealtimeTracker? = nil,
        snapshotInbox: SnapshotInbox? = nil,
        sourceValidity: @escaping () -> ClaudeSourceValidity = { .defaults },
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
        accountActiveSince = now()
        self.realtimeTracker = realtimeTracker
        self.sourceValidity = sourceValidity
        sourceTimeline = ClaudeSourceTimeline(
            validity: sourceValidity, now: now,
            fileURL: stateDirectory.appendingPathComponent("claude-source-timeline.json"))
        self.snapshotInbox = snapshotInbox
        self.confirmationTimer = confirmationTimer
        stateStore = ObservedFetchSchedulerStateStore(
            base: FileFetchSchedulerStateStore(fileURL: stateDirectory.appendingPathComponent("claude-fetch-scheduler.json")))
        mergeFileStore = QuotaMergeFileStore(url: stateDirectory.appendingPathComponent("claude-quota-merge.json"))
        scheduler = FetchScheduler(
            transport: ClaudeUsageTransport(pipeline: self),
            identity: identity,
            stateStore: stateStore,
            clock: schedulerClock,
            timer: schedulerTimer,
            freePathChecker: realtimeTracker,
            realtimeFreshness: realtimeTracker,
            calibrationIntervalCap: calibrationIntervalCap,
            automaticIntervalOverride: automaticInterval,
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
        // Inbox snapshots are verified against the official cycle as a whole before they are
        // attributed; the inbox rejects a snapshot when any of its windows fails.
        snapshotInbox?.cycleVerification = { [weak self] window, resetsAt, updatedAt, isComplete in
            self?.verifySnapshotCycle(window: window, resetsAt: resetsAt, updatedAt: updatedAt, isComplete: isComplete)
        }
        // Forward inbox-level rejections (account attribution, cycle verification) to the
        // settings entry; a forwarding-time timestamp is enough because the inbox does not
        // stamp rejections with an observation time.
        snapshotInbox?.rejectionObserver = { [weak self] reason in
            guard let self, let sink = self.modSnapshotEventSink else { return }
            sink(ModSnapshotEvent(
                kind: .rejected(reason: reason), window: nil, observedAt: nil,
                receivedAt: self.now()))
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        snapshotInbox?.stop()
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

    /// Why a manual refresh would be skipped right now, in the scheduler's own precedence
    /// (401 pause, cooldown, in-flight, recent result, budget; a plain failure never blocks it). Reads the
    /// scheduler's queue-protected snapshot so the menu never disagrees with the actual
    /// decision (e.g. a success persisted before a restart still suppresses).
    func manualRefreshNotice() -> ClaudeManualRefreshNotice? {
        let status = scheduler.statusSnapshot()
        if status.isUnauthorizedPaused { return .loginExpired }
        if status.cooldownRemaining > 0 {
            return .rateLimited(until: status.at.addingTimeInterval(status.cooldownRemaining))
        }
        if status.isBusy { return .inFlight }
        let pending = earliestPendingReset()
        if let lastSuccessAt = status.lastSuccessAt,
           now().timeIntervalSince(lastSuccessAt) < manualRefreshWindow,
           pending.map({ lastSuccessAt <= $0 }) != true {
            return .recentResult(until: lastSuccessAt.addingTimeInterval(manualRefreshWindow))
        }
        if let readyAt = status.manualTokensReadyAt, readyAt > status.at { return .outOfTokens(until: readyAt) }
        if pending != nil { return .awaitingResetConfirmation }
        // A manual refresh is only skipped for local data inside the manual window (the scheduler's
        // free-path rule), however long the user's validity keeps the source "live".
        if let observedAt = realtimeTracker?.lastTrustedRealtimeObservationAt,
           now().timeIntervalSince(observedAt) <= manualRefreshWindow { return .localFresh }
        return nil
    }

    enum ModUnavailableReason: String {
        case uninstalled, disabled
        case inAppUninstall = "in_app_uninstall"
    }

    /// The Mod was found uninstalled or disabled: it loses live eligibility at once and stops
    /// deferring official reads. Its last reading stays displayed with its own time.
    /// Idempotent; the first suspension moment is kept.
    ///
    /// - Parameter checkedAt: When the detection behind this verdict began. Only resume
    ///   candidates that arrived before it are covered by the verdict; a snapshot that arrived
    ///   while the check was already running keeps waiting for the follow-up check. `nil` (the
    ///   in-app uninstall) covers everything.
    func modBecameUnavailable(reason: ModUnavailableReason, checkedAt: Date? = nil) {
        queue.async { [self] in
            let first = lock.withLock { () -> Bool in
                modAvailableSince = nil
                let covered = modResumeCandidates.filter { checkedAt == nil || $0.value.receivedAt <= checkedAt! }
                if let newest = covered.values.map({ $0.observedAt ?? $0.receivedAt }).max() {
                    modCandidateFloor = max(modCandidateFloor ?? newest, newest)
                }
                modResumeCandidates = modResumeCandidates.filter { covered[$0.key] == nil }
                guard modSuspendedAt == nil else { return false }
                modSuspendedAt = now()
                return true
            }
            guard first else { return }
            diagnostics("claude mod suspended; reason=\(reason.rawValue)", .info)
            realtimeTracker?.invalidate(source: .mod)
            scheduler.rearm()
            publish()
        }
    }

    /// Detection confirmed the Mod installed and enabled. Does not restore live status by
    /// itself: a snapshot produced after the suspension is still required.
    func modBecameAvailable() {
        queue.async { [self] in
            let confirmed = lock.withLock { () -> (first: Bool, suspended: Bool, resume: [QuotaObservation]) in
                guard modAvailableSince == nil else { return (false, modSuspendedAt != nil, []) }
                modAvailableSince = now()
                // The snapshot that triggered this detection was produced after the suspension
                // and the detection now proves the Mod is installed and enabled: it resumes
                // live status at once instead of waiting for the next snapshot. Candidates were
                // collected only after the suspension, so data written earlier never qualifies.
                let resume = modSuspendedAt == nil ? [] : Array(modResumeCandidates.values)
                modResumeCandidates = [:]
                if !resume.isEmpty { modSuspendedAt = nil }
                return (true, modSuspendedAt != nil || !resume.isEmpty, resume)
            }
            if confirmed.first {
                diagnostics("claude mod available confirmed; suspended=\(confirmed.suspended)", .info)
            }
            guard !confirmed.resume.isEmpty else { return }
            for observation in confirmed.resume {
                diagnostics(
                    "claude mod live resumed; window=\(observation.window.rawValue); trigger=snapshot_detection",
                    .info)
                recordTrustedLocalEvidence(observation)
                modSnapshotEventSink?(ModSnapshotEvent(
                    kind: .processed(accepted: true), window: observation.window,
                    observedAt: observation.observedAt, receivedAt: observation.receivedAt))
            }
            publish()
        }
    }

    /// Earliest reset deadline that passed and still awaits official confirmation.
    private func earliestPendingReset() -> Date? {
        engine?.currentState.windows.values.compactMap { $0.pendingResetOf }.min()
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

    /// Merge-engine state for diagnostics: which sources currently own each window.
    var mergeStateForDiagnostics: QuotaMergeState? {
        lock.withLock { engine?.currentState }
    }

    /// Recomputes the pending automatic check after the calibration interval setting changed.
    func calibrationIntervalChanged() {
        scheduler.rearm()
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
        // Like the merge state, the source history comes back only for the same account.
        sourceTimeline.restore(accountKey: ClaudeSourceTimeline.accountKey(forStableID: identity.accountIdentity?.stableID))
        let adapter = QuotaNotificationAdapter(processor: notificationRouter, providerID: "claude")
        self.adapter = adapter
        engine = QuotaMergeEngine(scheduler: scheduler, notifications: adapter, store: restoring, now: now)
        snapshotInbox?.start { [weak self] observation in
            self?.queue.async { self?.receiveInbox(observation) }
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
        // The settings entry must not carry the previous account's snapshot evidence
        // across a switch (Issue #597: installed is never conflated with collecting).
        if let sink = modSnapshotEventSink {
            sink(ModSnapshotEvent(
                kind: .accountChanged, window: nil, observedAt: nil, receivedAt: now()))
        }
        engine.accountDidChange(epoch: change.epoch, accountID: change.identity?.stableID)
        lock.withLock {
            accountActiveSince = now()
            modResumeCandidates = [:]
            modCandidateFloor = nil
        }
        realtimeTracker?.reset(epoch: change.epoch)
        sourceTimeline.reset(accountKey: ClaudeSourceTimeline.accountKey(forStableID: change.identity?.stableID))
        lock.withLock {
            setFailureLocked(nil)
            refreshing = false
            lastSuccessAt = nil
        }
        adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: change.identity))
        publish()
        if change.identity != nil { requestForNewAccount() }
    }

    private func receiveInbox(_ observation: QuotaObservation) {
        let accepted = receiveInboxObservation(observation)
        // Adoption feedback drives the inbox's replay baseline: only snapshots whose
        // observations the merge engine actually adopted may become the baseline a later
        // duplicate is measured against.
        snapshotInbox?.noteProcessed(
            source: observation.source, accountID: observation.accountID,
            receivedAt: observation.receivedAt, accepted: accepted)
    }

    /// Returns whether the merge engine adopted the observation; `false` when it was
    /// filtered (non-Mod source, non-standard window) or rejected.
    private func receiveInboxObservation(_ observation: QuotaObservation) -> Bool {
        // Only the BalanceBar Mod's standard windows are Claude quota evidence; the Mod's
        // superset windows and unrelated inbox sources never reach the merge engine or card.
        guard observation.source == SnapshotInbox.modSourceID,
              observation.window == .fiveHour || observation.window == .sevenDay else { return false }
        let accepted = receiveNative(observation)
        if !accepted {
            diagnostics(
                "claude mod snapshot rejected; reason=not_displayed_by_merge; window=\(observation.window.rawValue)",
                .debug)
        }
        if let sink = modSnapshotEventSink {
            sink(ModSnapshotEvent(
                kind: .processed(accepted: accepted), window: observation.window,
                observedAt: observation.observedAt, receivedAt: observation.receivedAt))
        }
        return accepted
    }

    /// Ingest-time cycle verification handed to the snapshot inbox. The snapshot only
    /// carries an email hash, so a foreign identity under the same email can only be told
    /// apart by its quota cycle: a window whose reset time does not match the latest
    /// official reading fails, which rejects the whole snapshot (`nil` when there is no
    /// baseline yet — the merge engine's grade-B rules reject those anyway, and while a
    /// reset awaits confirmation the engine's own provisional rules govern).
    ///
    /// Two further guards protect what the cycle cannot prove. Without an official baseline the
    /// snapshot only carries an email hash, which two organizations of one email share; a snapshot
    /// produced before this account became active here may belong to the other one, so it is
    /// rejected. This is a known limit, not an organization proof: a snapshot written after the
    /// switch by a session still running under the other organization of the same email cannot be
    /// told apart until an official baseline exists (the Mod Schema carries no organization).
    /// And while a reset awaits confirmation, only a complete snapshot (both standard
    /// windows with reset times) may establish the next cycle.
    fileprivate func verifySnapshotCycle(
        window: QuotaWindowKind, resetsAt: Date?, updatedAt: Date, isComplete: Bool
    ) -> Bool? {
        guard let engine else { return nil }
        let state = engine.currentState.windows[window.rawValue]
        let baseline = state?.latestGradeA.flatMap { $0.epoch == identity.accountEpoch ? $0 : nil }
        if baseline == nil, updatedAt < lock.withLock({ accountActiveSince }) { return false }
        if state?.pendingResetOf != nil { return isComplete }
        guard let gradeA = baseline else { return nil }
        guard let gradeAReset = gradeA.resetsAt, let reset = resetsAt,
              QuotaMergeEngine.sameResetInstant(reset, gradeAReset) else { return false }
        return true
    }

    /// Merges one native observation; returns whether the engine now displays it, which is
    /// the only state that counts as trusted real-time evidence. Whole-snapshot replays are
    /// already filtered upstream (the inbox, per snapshot), so an accepted observation always records evidence — including a window
    /// that did not change while its snapshot sibling did.
    @discardableResult
    private func receiveNative(_ observation: QuotaObservation) -> Bool {
        guard let engine else { return false }
        // Cross-source monotonicity: a native grade-B reading may never move the display
        // backwards inside one cycle, whichever local source it comes from. Official
        // grade-A corrections and the pending-reset rules stay with the merge engine.
        if observation.trust != .a,
           let displayed = engine.currentState.windows[observation.window.rawValue]?.displayed,
           displayed.epoch == observation.epoch,
           Self.sameCycle(displayed.resetsAt, observation.resetsAt),
           observation.usedPercentage < displayed.usedPercentage {
            // The official API and the local sources round differently (e.g. the Mod reports 41
            // where the official API reported 42). Below an official reading and inside the
            // tolerance, the local reading is not shown, but it still proves the local source is
            // alive for this window; without it the window would never count as fresh local data.
            // Between two local readings a regression is concurrent-session noise, never evidence.
            let tolerated = displayed.trust == .a
                && displayed.usedPercentage - observation.usedPercentage
                    <= QuotaConstants.gradeBTolerancePercentagePoints
            let observedAt = observation.observedAt ?? observation.receivedAt
            guard tolerated, observedAt >= displayed.effectiveTime else {
                if !tolerated { logSourceConflict(observation, displayed: displayed, reason: "lower_than_displayed") }
                diagnostics(
                    "claude native observation rejected; reason=usage_decreased_within_cycle; source=\(observation.source); window=\(observation.window.rawValue)",
                    .debug)
                return false
            }
            diagnostics(
                "claude native observation kept as evidence only; reason=usage_within_tolerance_below_display; source=\(observation.source); window=\(observation.window.rawValue)",
                .debug)
            let recorded = recordLocalEvidence(observation)
            publish()
            return recorded
        }
        let previous = engine.currentState.windows[observation.window.rawValue]?.displayed
        _ = engine.merge(observation)
        let displayed = engine.currentState.windows[observation.window.rawValue]?.displayed
        let accepted = displayed?.source == observation.source
            && displayed?.receivedAt == observation.receivedAt
        if accepted, let previous, previous.source == observation.source, previous.epoch == observation.epoch,
           previous.usedPercentage == observation.usedPercentage,
           Self.sameCycle(previous.resetsAt, observation.resetsAt) {
            // Same value, later production time: only the reading's time advances.
            diagnostics(
                "claude native observation refreshed evidence; reason=same_value_newer; source=\(observation.source); window=\(observation.window.rawValue)",
                .debug)
        }
        if !accepted, let previous, (observation.observedAt ?? observation.receivedAt) < previous.effectiveTime {
            logSourceConflict(observation, displayed: previous, reason: "older_than_displayed")
        }
        diagnostics(
            "claude native observation; source=\(observation.source); window=\(observation.window.rawValue); accepted=\(accepted)",
            .debug)
        // A displayed reading that may not count as current evidence (Mod suspended) is not
        // reported as accepted either: the settings entry must not treat it as trusted.
        let recorded = accepted ? recordLocalEvidence(observation) : false
        publish()
        return accepted && recorded
    }

    /// Writes a redacted error line when two different sources disagree about one cycle of a window
    /// beyond the rounding tolerance. The newer validated reading already won; this is diagnostics only.
    private func logSourceConflict(
        _ observation: QuotaObservation, displayed: QuotaMergedReading, reason: String
    ) {
        guard displayed.source != observation.source,
              displayed.epoch == observation.epoch,
              Self.sameCycle(displayed.resetsAt, observation.resetsAt),
              abs(displayed.usedPercentage - observation.usedPercentage)
                > QuotaConstants.gradeBTolerancePercentagePoints else { return }
        diagnostics(
            "claude source conflict; reason=\(reason); window=\(observation.window.rawValue); "
                + "displayed_source=\(displayed.source); observed_source=\(observation.source); "
                + "displayed_used=\(displayed.usedPercentage); observed_used=\(observation.usedPercentage); "
                + "displayed_at=\(displayed.effectiveTime.timeIntervalSince1970); "
                + "observed_at=\((observation.observedAt ?? observation.receivedAt).timeIntervalSince1970)",
            .error)
    }

    /// Trusted real-time evidence from a local source: freshness for the scheduler and a block on
    /// the source timeline.
    /// Returns false when the observation may not count as current evidence (the Mod is
    /// suspended and has not been confirmed available again with a newer snapshot).
    @discardableResult
    private func recordLocalEvidence(_ observation: QuotaObservation) -> Bool {
        if observation.source == SnapshotInbox.modSourceID {
            let producedAt = observation.observedAt ?? observation.receivedAt
            enum Outcome { case notSuspended, rejected(String), resumed, awaitingDetection(request: Bool) }
            let outcome = lock.withLock { () -> Outcome in
                guard let suspendedAt = modSuspendedAt else { return .notSuspended }
                if suspendedAt > producedAt { return .rejected("snapshot_before_suspension") }
                guard let since = modAvailableSince else {
                    // Produced after the suspension: keep it for the detection it asks for.
                    guard modDetectionRequestHandler != nil,
                          modCandidateFloor.map({ producedAt > $0 }) ?? true else {
                        return .rejected("snapshot_while_mod_unavailable")
                    }
                    // One request per snapshot: its second window shares the production time.
                    let isNewSnapshot = modResumeCandidates.values.allSatisfy {
                        ($0.observedAt ?? $0.receivedAt) < producedAt }
                    modResumeCandidates[observation.window] = observation
                    return .awaitingDetection(request: isNewSnapshot)
                }
                if producedAt <= since { return .rejected("snapshot_before_available_confirmation") }
                modSuspendedAt = nil
                return .resumed
            }
            switch outcome {
            case .notSuspended:
                break
            case .rejected(let reason):
                diagnostics(
                    "claude mod snapshot not live evidence; reason=\(reason); window=\(observation.window.rawValue)",
                    .debug)
                return false
            case .resumed:
                diagnostics("claude mod live resumed; window=\(observation.window.rawValue)", .info)
            case .awaitingDetection(let request):
                diagnostics(
                    "claude mod snapshot not live evidence; reason=snapshot_while_mod_unavailable; window=\(observation.window.rawValue); detection_requested=\(request)",
                    .debug)
                if request { modDetectionRequester?() }
                return false
            }
        }
        recordTrustedLocalEvidence(observation)
        return true
    }

    private func recordTrustedLocalEvidence(_ observation: QuotaObservation) {
        realtimeTracker?.recordTrustedObservation(
            window: observation.window,
            observedAt: observation.observedAt ?? observation.receivedAt,
            epoch: observation.epoch,
            source: Self.statusSource(forSourceID: observation.source) ?? .mod)
        if let source = Self.statusSource(forSourceID: observation.source) {
            sourceTimeline.recordReading(source: source, observedAt: observation.observedAt ?? observation.receivedAt)
        }
    }

    /// Sources disagree below a second; see `QuotaMergeEngine.sameResetInstant`.
    private static func sameCycle(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return QuotaMergeEngine.sameResetInstant(l, r)
        default: return false
        }
    }

    /// A new account must be read immediately, subject only to auth, cooldown, budget and
    /// failure-backoff constraints.
    private func requestForNewAccount() {
        prepareAndRequest(.accountChanged)
    }

    private func handle(_ delivery: FetchSchedulerDelivery) {
        guard let engine else { return }
        var newFailure: ClaudeQuotaFailure?
        var adoptedOfficialRead = false
        switch delivery.result {
        case let .success(data):
            lock.withLock { lastSuccessAt = delivery.receivedAt }
            let currentEpoch = identity.accountEpoch == delivery.epoch
            newFailure = merge(data, delivery: delivery, into: engine)
            adoptedOfficialRead = currentEpoch && newFailure == nil
        case .rateLimited:
            newFailure = .rateLimited
        case .unauthorized:
            newFailure = .unauthorized
        case .failure:
            newFailure = Self.failure(from: lock.withLock { lastClientError })
        }
        lock.withLock {
            setFailureLocked(newFailure)
            refreshing = false
        }
        if let newFailure {
            diagnostics("claude official fetch failed; kind=\(Self.failureKind(newFailure))", .info)
            sourceTimeline.recordFailure(ClaudeSourceTimeline.FailureKind(newFailure), at: delivery.receivedAt)
        } else if adoptedOfficialRead {
            sourceTimeline.recordOfficialSuccess(at: delivery.receivedAt)
        }
        publish()
    }

    /// Records the failure and keeps `failureSince` at the start of the run. Caller holds `lock`.
    private func setFailureLocked(_ newFailure: ClaudeQuotaFailure?) {
        failure = newFailure
        if newFailure == nil {
            failureSince = nil
        } else if failureSince == nil {
            failureSince = now()
        }
    }

    /// Non-secret failure category for diagnostics.
    private static func failureKind(_ failure: ClaudeQuotaFailure) -> String {
        switch failure {
        case .missingCredentials: return "missing_credentials"
        case .rateLimited: return "rate_limited"
        case .unauthorized: return "unauthorized"
        case let .transport(possibleProxy, description):
            return "transport; possible_proxy=\(possibleProxy); detail=\(description)"
        case let .http(status): return "http; status=\(status)"
        case .invalidResponse: return "invalid_response"
        }
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
            let previous = engine.currentState.windows[observation.window.rawValue]?.displayed
            engine.merge(observation)
            if let previous, previous.trust == .b,
               engine.currentState.windows[observation.window.rawValue]?.displayed?.source == Self.sourceID {
                logSourceConflict(observation, displayed: previous, reason: "official_corrected_local")
            }
        }
        adapter?.update(engine.displayModel, accountScope: Self.accountScope(for: account))
        return nil
    }

    /// Keeps the tracker's pending-reset view in sync and drives official confirmation
    /// retries while any window awaits one. Called from `publish` on the pipeline queue.
    private func syncResetConfirmation() {
        let pending = earliestPendingReset()
        realtimeTracker?.markPendingReset(pending)
        guard pending != nil else {
            if awaitingResetConfirmation {
                awaitingResetConfirmation = false
                resetConfirmationTimerGeneration += 1
            }
            return
        }
        guard !awaitingResetConfirmation else { return }
        awaitingResetConfirmation = true
        resetConfirmationAttempts = 0
        // The engine already asked when its clock crossed the deadline; this request also
        // covers a pending state restored from disk after a restart, where nothing else fires.
        // The scheduler coalesces both into one read.
        prepareAndRequest(.resetConfirmation)
        armResetConfirmationRetry()
    }

    private func armResetConfirmationRetry() {
        resetConfirmationTimerGeneration += 1
        let generation = resetConfirmationTimerGeneration
        let delays = Self.resetConfirmationRetryDelays
        let delay = delays[min(resetConfirmationAttempts, delays.count - 1)]
        confirmationTimer.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.queue.async { self.resetConfirmationRetryFired(generation: generation) }
        }
    }

    private func resetConfirmationRetryFired(generation: Int) {
        guard generation == resetConfirmationTimerGeneration, awaitingResetConfirmation else { return }
        resetConfirmationAttempts += 1
        prepareAndRequest(.resetConfirmation)
        armResetConfirmationRetry()
    }

    private func schedulerEvent(_ event: FetchSchedulerLogEvent) {
        switch event.kind {
        case .dispatched:
            logDispatch(event)
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
                lock.withLock { setFailureLocked(skipFailure) }
                publish()
            }
        case .requested, .completed:
            break
        }
    }

    private func logDispatch(_ event: FetchSchedulerLogEvent) {
        let reasons = event.reasons.map { String(describing: $0) }.joined(separator: ",")
        diagnostics(
            "claude fetch dispatched; trigger=\(event.trigger?.rawValue ?? "unknown"); reasons=\(reasons); tokens=\(event.tokens)",
            event.reasons.contains(.manual) ? .info : .debug)
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
        let (failure, failureSince, refreshing, handler) = lock.withLock {
            (self.failure, self.failureSince, self.refreshing, updateHandler)
        }
        // Local evidence: readings displayed from the Mod's inbox snapshots.
        // `ClaudeRealtimeTracker` stays scheduler-only; a pending reset must not hide fresh
        // local readings from the card, so freshness is read from the displayed readings.
        let standard = [QuotaWindowKind.fiveHour, .sevenDay].map { merged.windows[$0.rawValue]?.displayed }
        func isLocal(_ reading: QuotaMergedReading?) -> Bool {
            guard let reading, reading.epoch == identity.accountEpoch else { return false }
            return reading.source == SnapshotInbox.modSourceID
        }
        let validity = sourceValidity()
        let modSuspended = lock.withLock { modSuspendedAt != nil }
        func isFresh(_ reading: QuotaMergedReading) -> Bool {
            guard let source = Self.statusSource(forSourceID: reading.source) else { return false }
            if source == .mod, modSuspended { return false }
            return date.timeIntervalSince(reading.effectiveTime) <= validity.seconds(for: source)
        }
        // "Live" status: the newest displayed reading comes from a local source and is within that
        // source's validity. One window may keep its official value (a local reading that moved
        // backwards inside the cycle is rejected), which must not hide that the other window is
        // being updated in real time.
        let newestStandard = standard.compactMap { $0 }.max { $0.effectiveTime < $1.effectiveTime }
        let nativeDisplayed = isLocal(newestStandard) && isFresh(newestStandard!)
        // A failed official read marks the displayed values as outdated without discarding
        // them. It only concerns the Usage API, though: a local reading received after the
        // failures began and still within its source's validity is current evidence, so the
        // failure stays in `failure` (diagnostics, menu subtitle) without turning the card red.
        let localReadingIsCurrent = merged.windows.values.compactMap(\.displayed).contains { reading in
            isLocal(reading)
                && reading.effectiveTime >= (failureSince ?? .distantPast)
                && isFresh(reading)
        }
        let failureTaintsDisplay = failure != nil && !nativeDisplayed && !localReadingIsCurrent
        // A pending window that already shows a provisional next-cycle reading from a local
        // source is presented as in progress; the engine keeps it pending until grade-A data.
        let presented = Self.presentationModel(from: model, merged: merged)
        let shown = failureTaintsDisplay ? QuotaDisplayModel(
            windows: presented.windows, isEstimated: presented.isEstimated, state: .error,
            hoverTextKey: presented.hoverTextKey) : presented
        let status = StatusSlotState.resolve(
            model: shown,
            context: StatusSlotContext(isRefreshing: refreshing,
                source: Self.liveSource(of: standard, now: date, nativeDisplayed: nativeDisplayed, officialValidity: validity.oauth),
                // The slot's age is the reading's own time, not when BalanceBar happened to receive it
                // (a Mod snapshot read at launch may have been written minutes earlier).
                updatedAt: newestStandard?.effectiveTime ?? updatedAt,
                lastSource: Self.statusSource(of: standard)))
        let next = ClaudeQuotaState(
            display: model,
            windows: DevelopmentClaudeIdleDemo.windows() ?? Self.cardWindows(from: presented, now: date),
            accountEpoch: identity.accountEpoch,
            accountScope: Self.accountScope(for: identity.accountIdentity),
            predictionAccountKey: Self.predictionAccountKey(for: identity.accountIdentity),
            predictionEvidenceKey: Self.predictionEvidenceKey(for: identity.accountIdentity),
            updatedAt: updatedAt,
            isRefreshing: refreshing,
            failure: failure,
            status: status)
        let changed = lock.withLock { () -> Bool in
            guard state != next else { return false }
            state = next
            return true
        }
        syncResetConfirmation()
        if changed { handler?(next) }
    }

    // MARK: - Pure helpers

    /// Maps an observation's source label to the status-slot source; nil for unknown sources.
    static func statusSource(forSourceID id: String) -> StatusSlotLiveSource? {
        switch id {
        case SnapshotInbox.modSourceID: return .mod
        case sourceID: return .oauthAPI
        default: return nil
        }
    }

    /// Source of the newest standard-window reading, for the "N 分钟前 · 来源" label.
    static func statusSource(of standard: [QuotaMergedReading?]) -> StatusSlotLiveSource? {
        standard.compactMap { $0 }.max(by: { $0.effectiveTime < $1.effectiveTime })
            .flatMap { statusSource(forSourceID: $0.source) }
    }

    /// Source label for the status slot: the newest standard-window reading decides. A local source
    /// is live while that reading is fresh (`nativeDisplayed`); an official read stays live for the
    /// user's OAuth validity.
    static func liveSource(
        of standard: [QuotaMergedReading?], now: Date, nativeDisplayed: Bool, officialValidity: TimeInterval
    ) -> StatusSlotSource {
        guard let newest = standard.compactMap({ $0 }).max(by: { $0.effectiveTime < $1.effectiveTime }),
              let source = statusSource(forSourceID: newest.source) else { return .official }
        switch source {
        case .mod: return nativeDisplayed ? .realtime(source) : .official
        case .oauthAPI:
            return now.timeIntervalSince(newest.effectiveTime) <= officialValidity ? .realtime(.oauthAPI) : .official
        }
    }

    /// Re-evaluates freshness after the user changed a source's validity: the scheduler recomputes
    /// when local data stops suppressing requests, and the card re-resolves its status.
    func sourceValidityChanged() {
        sourceTimeline.validityChanged()
        scheduler.rearm()
        queue.async { [self] in publish() }
    }

    /// The model as the card presents it: a window awaiting confirmation that already displays a
    /// grade-B reading of the next cycle is real data, not "waiting".
    static func presentationModel(from model: QuotaDisplayModel, merged: QuotaMergeState) -> QuotaDisplayModel {
        var changed = false
        let windows = model.windows.map { window -> QuotaWindowDisplay in
            guard window.state == .resetPendingConfirmation,
                  let state = merged.windows[window.kind.rawValue],
                  let pending = state.pendingResetOf,
                  let displayed = state.displayed,
                  displayed.trust == .b, displayed.effectiveTime > pending else { return window }
            changed = true
            return QuotaWindowDisplay(
                kind: window.kind, usedPercentage: window.usedPercentage, resetsAt: window.resetsAt,
                isEstimated: window.isEstimated, state: .inProgress, hoverTextKey: QuotaMergeEngine.hoverKey(.inProgress))
        }
        guard changed else { return model }
        let aggregate = QuotaMergeEngine.aggregateState(windows.map(\.state))
        return QuotaDisplayModel(windows: windows, isEstimated: model.isEstimated, state: aggregate,
                                 hoverTextKey: QuotaMergeEngine.hoverKey(aggregate))
    }

    private static let windowOrder = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]

    static func cardWindows(from model: QuotaDisplayModel, now: Date) -> [OfficialQuotaWindow] {
        model.windows
            .compactMap { display -> (Int, OfficialQuotaWindow)? in
                guard let used = display.usedPercentage,
                      let order = windowOrder.firstIndex(of: display.kind.rawValue) else { return nil }
                // A window past its reset with no newer reading is shown as already reset: untouched
                // (100%) with the window length, which the card projects to now + length.
                // The old reading is not shown as if it still applied.
                let pendingReset = display.state == .resetPendingConfirmation
                guard let window = OfficialQuotaResponseParser.claudeWindow(
                    for: display.kind, usedPercentage: pendingReset ? 0 : used,
                    resetsAt: pendingReset ? nil : display.resetsAt, now: now) else { return nil }
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

    /// Prediction account key: the normalized email, using the same rule the
    /// menu applies to the card's account presentation. Nil without an email.
    static func predictionAccountKey(for identity: AccountIdentity?) -> String? {
        guard let identity, let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty else { return nil }
        return email
    }

    /// Journal identity for prediction evidence: the stable account ID, which
    /// distinguishes same-email Claude accounts (account + organization UUID).
    /// Its "claude:" namespace also never collides with a Codex email journal.
    /// Emitted only when the email-based menu match exists.
    static func predictionEvidenceKey(for identity: AccountIdentity?) -> String? {
        guard let identity, predictionAccountKey(for: identity) != nil else { return nil }
        return identity.stableID
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
        if DevelopmentClaudeUnauthorizedSimulation.isActive {
            pipeline.recordClientError(nil)
            completion(.unauthorized)
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
        calibrationIntervalCap: @escaping () -> TimeInterval?,
        automaticInterval: @escaping () -> TimeInterval? = { nil },
        sourceValidity: @escaping () -> ClaudeSourceValidity = { .defaults }
    ) -> ClaudeQuotaPipeline {
        let identityQueue = DispatchQueue(label: "BalanceBar.AccountIdentity", qos: .utility)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BalanceBar", isDirectory: true)
            .appendingPathComponent("Quota", isDirectory: true)
        let identity = ClaudeAccountIdentityProvider(workQueue: identityQueue)
        let tracker = ClaudeRealtimeTracker(validity: sourceValidity, now: Date.init)
        // The BalanceBar Mod writes Schema v1 snapshots into the shared inbox; its account
        // attribution is verified fail closed inside the inbox before anything reaches the engine.
        let inbox = SnapshotInbox(identity: identity)
        return ClaudeQuotaPipeline(
            client: client,
            identity: identity,
            identityQueue: identityQueue,
            stateDirectory: directory,
            calibrationIntervalCap: calibrationIntervalCap,
            automaticInterval: automaticInterval,
            schedulerConfiguration: .claudeV1,
            realtimeTracker: tracker,
            snapshotInbox: inbox,
            sourceValidity: sourceValidity)
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

/// Makes the Claude usage request answer 401 for manual testing of the login-expired
/// states. Only the development bundle honours `BALANCEBAR_SIMULATE_CLAUDE_401=1`.
/// The resulting pause is persisted; delete the dev bundle's `claude-fetch-scheduler.json` to clear it.
enum DevelopmentClaudeUnauthorizedSimulation {
    static var isActive: Bool {
        guard let id = Bundle.main.bundleIdentifier,
              id == "com.huanmeng06.BalanceBar.dev" || id.hasPrefix("com.huanmeng06.BalanceBar.dev.")
        else { return false }
        return ProcessInfo.processInfo.environment["BALANCEBAR_SIMULATE_CLAUDE_401"] == "1"
    }
}
