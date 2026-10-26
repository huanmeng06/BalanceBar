import Foundation

/// The single Usage API request entry point.
///
/// Callers express intent with `requestFetch(reason:)`; the scheduler alone decides whether
/// coalescing, the minimum interval, the token bucket, 429 cooldown, 401 pause, real-time
/// freshness, and the manual-refresh rules allow a request. All state and persistence live on a
/// private serial background queue.
public final class FetchScheduler: FetchScheduling {
    private let transport: UsageFetchTransport
    private let identity: AccountIdentityProviding
    private let clock: SchedulerClock
    private let timer: SchedulerTimer
    private let stateStore: FetchSchedulerStateStoring
    private let freePathChecker: ManualRefreshFreePathChecking?
    private let realtimeFreshness: RealtimeSourceFreshnessProviding?
    private let calibrationIntervalCap: () -> TimeInterval?
    private let automaticIntervalOverride: () -> TimeInterval?
    private let configuration: FetchSchedulerConfiguration
    private let logSink: (FetchSchedulerLogEvent) -> Void
    private let queue: DispatchQueue

    private var persistent: FetchSchedulerPersistentState
    private var tokens: Int
    private var tokenRefillAnchor: Date
    private var pendingReasons: Set<FetchRequestReason> = []
    private var isCoalescing = false
    private var isBusy = false
    private var lastServerAttemptAt: Date?
    private var lastSuccess: (at: Date, epoch: AccountEpoch)?
    private var consecutiveFailures = 0
    private var lastFailureAt: Date?
    private var demandEnabled = false
    private var timerGeneration = 0
    /// Non-routine reasons that arrived while a request was in flight; replayed once it ends
    /// so an account switch during a stale request still gets its own read.
    private var deferredReasons: Set<FetchRequestReason> = []
    /// Called when the scheduler's own timer decides an automatic check is due. Lets the
    /// owner refresh credentials first; defaults to `requestFetch(.scheduled)`.
    private var automaticTrigger: (() -> Void)?
    /// Timer-only `.scheduled` evaluations skipped in a row; any dispatch resets it.
    private var idleTimerSkips = 0
    private var resultHandlers: [(FetchSchedulerDelivery) -> Void] = []

    /// - Parameter automaticIntervalOverride: Reads a user-selected automatic-request interval that
    ///   replaces `automaticMinimumInterval`; `nil` keeps the configured value.
    /// - Parameter calibrationIntervalCap: Reads the existing refresh-interval setting, used as an
    ///   upper bound: when a fresh real-time source suppresses automatic requests, a request is still
    ///   allowed once the last successful fetch is older than this cap. `nil` disables the override.
    public init(
        transport: UsageFetchTransport,
        identity: AccountIdentityProviding,
        stateStore: FetchSchedulerStateStoring,
        clock: SchedulerClock = SystemSchedulerClock(),
        timer: SchedulerTimer = DispatchSchedulerTimer(),
        freePathChecker: ManualRefreshFreePathChecking? = nil,
        realtimeFreshness: RealtimeSourceFreshnessProviding? = nil,
        calibrationIntervalCap: @escaping () -> TimeInterval? = { nil },
        automaticIntervalOverride: @escaping () -> TimeInterval? = { nil },
        configuration: FetchSchedulerConfiguration = FetchSchedulerConfiguration(),
        queue: DispatchQueue = DispatchQueue(label: "BalanceBar.FetchScheduler", qos: .utility),
        logSink: @escaping (FetchSchedulerLogEvent) -> Void = { _ in }
    ) {
        self.transport = transport
        self.identity = identity
        self.clock = clock
        self.timer = timer
        self.stateStore = stateStore
        self.freePathChecker = freePathChecker
        self.realtimeFreshness = realtimeFreshness
        self.calibrationIntervalCap = calibrationIntervalCap
        self.automaticIntervalOverride = automaticIntervalOverride
        self.configuration = configuration
        self.queue = queue
        self.logSink = logSink
        persistent = FetchSchedulerPersistentState()
        tokens = configuration.tokenCapacity
        tokenRefillAnchor = clock.now
        queue.async { [self] in
            if let loaded = stateStore.load() {
                persistent = loaded
                lastServerAttemptAt = loaded.lastServerAttemptAt
                consecutiveFailures = loaded.consecutiveFailures
            }
        }
    }

    /// Registers a handler that receives every current-epoch result. Called on the scheduler queue.
    public func addResultHandler(_ handler: @escaping (FetchSchedulerDelivery) -> Void) {
        queue.async { [self] in resultHandlers.append(handler) }
    }

    public func requestFetch(reason: FetchRequestReason) {
        queue.async { [self] in enqueue(reason) }
    }

    /// Enables or disables scheduler-owned automatic checks.
    public func setDemand(_ enabled: Bool) {
        queue.async { [self] in
            demandEnabled = enabled
            rearmOnQueue()
        }
    }

    /// Replaces what runs when the scheduler's timer finds an automatic check due.
    public func setAutomaticTrigger(_ trigger: (() -> Void)?) {
        queue.async { [self] in automaticTrigger = trigger }
    }

    /// Recomputes the single pending automatic check without replaying history.
    public func rearm() {
        queue.async { [self] in rearmOnQueue() }
    }

    /// Returns a consistent, queue-protected view for menu and diagnostic consumers.
    public func statusSnapshot() -> FetchSchedulerStatus {
        queue.sync {
            let now = clock.now
            refillTokens(now: now)
            let failureBackoffUntil: Date?
            if let lastServerAttemptAt, consecutiveFailures > 0 {
                let until = lastServerAttemptAt.addingTimeInterval(failureBackoffInterval)
                failureBackoffUntil = until > now ? until : nil
            } else {
                failureBackoffUntil = nil
            }
            let manualTokensReadyAt: Date?
            if tokens < configuration.manualTokenCost, configuration.tokenRefillInterval > 0 {
                let missing = Double(configuration.manualTokenCost - tokens)
                manualTokensReadyAt = tokenRefillAnchor.addingTimeInterval(missing * configuration.tokenRefillInterval)
            } else {
                manualTokensReadyAt = nil
            }
            return FetchSchedulerStatus(
                tokens: tokens,
                tokenCapacity: configuration.tokenCapacity,
                tokenRefillInterval: configuration.tokenRefillInterval,
                nextTokenAt: tokens < configuration.tokenCapacity
                    ? tokenRefillAnchor.addingTimeInterval(configuration.tokenRefillInterval) : nil,
                automaticTokenCost: configuration.automaticTokenCost,
                lastServerAttemptAt: lastServerAttemptAt,
                automaticMinimumInterval: automaticMinimumInterval,
                lastSuccessAt: currentEpochLastSuccessAt,
                lastFailureAt: lastFailureAt,
                manualTokenCost: configuration.manualTokenCost,
                manualRefreshWindow: configuration.manualRefreshWindow,
                cooldownRemaining: cooldownRemaining(now: now),
                failureBackoffUntil: failureBackoffUntil,
                manualTokensReadyAt: manualTokensReadyAt,
                isUnauthorizedPaused: persistent.isUnauthorizedPaused,
                isBusy: isBusy,
                at: now)
        }
    }

    /// Blocks until previously enqueued scheduler work has run. Intended for tests and shutdown.
    public func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Evaluation (scheduler queue only)

    private func enqueue(_ reason: FetchRequestReason) {
        log(.requested, reasons: [reason])
        if isBusy {
            if reason != .scheduled { deferredReasons.insert(reason) }
            log(.skipped, reasons: [reason], skip: .coalescedIntoInFlight)
            return
        }
        pendingReasons.insert(reason)
        startCoalescing()
    }

    private func startCoalescing() {
        guard !isCoalescing else { return }
        isCoalescing = true
        timer.schedule(after: configuration.coalescingWindow) { [self] in
            queue.async { flushPending() }
        }
    }

    private func flushPending() {
        isCoalescing = false
        let reasons = pendingReasons.sorted { $0.rawValue < $1.rawValue }
        pendingReasons.removeAll()
        guard !reasons.isEmpty else { return }
        evaluate(reasons)
    }

    private func evaluate(_ reasons: [FetchRequestReason]) {
        defer { rearmOnQueue() }
        let now = clock.now
        refillTokens(now: now)

        if persistent.isUnauthorizedPaused {
            if identity.credentialVersion == persistent.unauthorizedCredentialVersion {
                return log(.skipped, reasons: reasons, skip: .unauthorizedPaused)
            }
            persistent.isUnauthorizedPaused = false
            persistent.unauthorizedCredentialVersion = nil
            stateStore.save(persistent)
        }
        if cooldownRemaining(now: now) > 0 {
            return log(.skipped, reasons: reasons, skip: .cooldown)
        }

        if let lastServerAttemptAt,
           consecutiveFailures > 0,
           now.timeIntervalSince(lastServerAttemptAt) < failureBackoffInterval {
            return log(.skipped, reasons: reasons, skip: .failureBackoff)
        }

        if reasons.contains(.manual) {
            evaluateManual(reasons, now: now)
        } else {
            evaluateAutomatic(reasons, now: now)
        }
    }

    private func evaluateManual(_ reasons: [FetchRequestReason], now: Date) {
        let window = configuration.manualRefreshWindow
        if let lastSuccessAt = currentEpochLastSuccessAt, now.timeIntervalSince(lastSuccessAt) < window,
           !manualResultCannotConfirmPendingReset(lastSuccessAt: lastSuccessAt) {
            return log(.skipped, reasons: reasons, skip: .recentResult)
        }
        guard let freePathChecker else { return spendAndDispatch(reasons, cost: configuration.manualTokenCost) }
        isBusy = true
        freePathChecker.checkFreePath(within: window) { [self] satisfied in
            queue.async {
                isBusy = false
                // The check suspended the automatic timer while busy; a branch that ends without a
                // request never reaches `complete`, so re-arm here (a dispatch re-arms in `complete`).
                defer { rearmOnQueue() }
                if satisfied {
                    return log(.skipped, reasons: reasons, skip: .freePathSatisfied)
                }
                refillTokens(now: clock.now)
                spendAndDispatch(reasons, cost: configuration.manualTokenCost)
            }
        }
    }

    private func evaluateAutomatic(_ reasons: [FetchRequestReason], now: Date) {
        let firstRead = (reasons.contains(.initial) || reasons.contains(.accountChanged))
            && currentEpochLastSuccessAt == nil
        // A reset confirmation cannot wait out the minimum interval: the deadline already
        // passed, so only the 401 pause, cooldown, failure backoff and budget may hold it.
        let bypassMinimum = firstRead || reasons.contains(.resetConfirmation)
        if !bypassMinimum,
           let lastSuccessAt = currentEpochLastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < automaticMinimumInterval {
            return log(.skipped, reasons: reasons, skip: .minimumInterval)
        }
        if !reasons.contains(.resetConfirmation),
           let freshUntil = realtimeFreshUntil(),
           now < freshUntil,
           !calibrationCapExceeded(now: now) {
            return log(.skipped, reasons: reasons, skip: .realtimeSourceFresh)
        }
        // A first read for a new or newly loaded account is user-visible, so it is charged like
        // a manual request instead of waiting for the routine budget.
        spendAndDispatch(reasons, cost: firstRead ? configuration.manualTokenCost : configuration.automaticTokenCost)
    }

    /// A success from before the pending reset deadline still describes the previous cycle,
    /// so it can never confirm the reset and must not suppress a manual refresh.
    private func manualResultCannotConfirmPendingReset(lastSuccessAt: Date) -> Bool {
        guard let pending = realtimeFreshness?.pendingResetOf else { return false }
        return lastSuccessAt <= pending
    }

    /// Last success time for the current account epoch; another account's success never counts.
    /// A success persisted before a restart counts once the identity reports the same account;
    /// the identity loads asynchronously, so this is resolved on read instead of at init.
    private var currentEpochLastSuccessAt: Date? {
        if let lastSuccess, lastSuccess.epoch == identity.accountEpoch { return lastSuccess.at }
        guard let key = identity.accountKey, key == persistent.lastSuccessAccountKey,
              let at = persistent.lastServerSuccessAt, lastSuccess == nil else { return nil }
        return at
    }

    /// End of the real-time freshness window: the source's own per-source value when it has one,
    /// otherwise the last observation plus the configured freshness.
    private func realtimeFreshUntil() -> Date? {
        guard let realtimeFreshness else { return nil }
        if let until = realtimeFreshness.realtimeFreshUntil { return until }
        return realtimeFreshness.lastTrustedRealtimeObservationAt?
            .addingTimeInterval(configuration.realtimeSourceFreshness)
    }

    private var automaticMinimumInterval: TimeInterval {
        automaticIntervalOverride() ?? configuration.automaticMinimumInterval
    }

    private func calibrationCapExceeded(now: Date) -> Bool {
        let cap = calibrationIntervalCap() ?? configuration.realtimeCalibrationCap
        guard let cap, cap > 0 else { return false }
        guard let lastSuccessAt = currentEpochLastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= cap
    }

    private func spendAndDispatch(_ reasons: [FetchRequestReason], cost: Int) {
        guard tokens >= cost else {
            return log(.skipped, reasons: reasons, skip: .insufficientTokens)
        }
        tokens -= cost
        isBusy = true
        lastServerAttemptAt = clock.now
        persistent.lastServerAttemptAt = lastServerAttemptAt
        stateStore.save(persistent)
        let epoch = identity.accountEpoch
        let credentialVersion = identity.credentialVersion
        log(.dispatched, reasons: reasons)
        transport.fetchUsage { [self] result in
            queue.async {
                complete(result, reasons: reasons, epoch: epoch, credentialVersion: credentialVersion)
            }
        }
    }

    private func complete(
        _ result: UsageFetchResult,
        reasons: [FetchRequestReason],
        epoch: AccountEpoch,
        credentialVersion: CredentialVersion?
    ) {
        isBusy = false
        let now = clock.now
        let stale = identity.accountEpoch != epoch
        defer {
            replayDeferred(staleEpoch: stale)
            rearmOnQueue()
        }
        // A 429 is honored even for a stale epoch so an account switch cannot bypass the cooldown.
        if case let .rateLimited(retryAfter) = result {
            applyRateLimit(retryAfter: retryAfter, now: now)
        }
        guard !stale else {
            return log(.discardedStaleEpoch, reasons: reasons, outcome: Self.label(result))
        }
        switch result {
        case .success:
            lastSuccess = (now, epoch)
            consecutiveFailures = 0
            persistent.consecutiveFailures = 0
            persistent.lastServerSuccessAt = now
            persistent.lastSuccessAccountKey = identity.accountKey
            if persistent.consecutiveRateLimitBackoffs != 0 || persistent.cooldownUntil != nil {
                persistent.consecutiveRateLimitBackoffs = 0
                persistent.cooldownUntil = nil
            }
            stateStore.save(persistent)
        case .unauthorized:
            // A 401 for credentials replaced mid-flight must not pause the new credentials.
            if identity.credentialVersion == credentialVersion {
                persistent.isUnauthorizedPaused = true
                persistent.unauthorizedCredentialVersion = credentialVersion
                stateStore.save(persistent)
            }
        case .rateLimited:
            break
        case .failure:
            lastFailureAt = now
            consecutiveFailures += 1
            persistent.consecutiveFailures = consecutiveFailures
            stateStore.save(persistent)
        }
        log(.completed, reasons: reasons, outcome: Self.label(result))
        let delivery = FetchSchedulerDelivery(result: result, reasons: reasons, epoch: epoch, receivedAt: now)
        resultHandlers.forEach { $0(delivery) }
    }

    /// A same-account result already answers a manual request made during the flight; a stale
    /// result answers nothing, so every deferred reason is evaluated again.
    private func replayDeferred(staleEpoch: Bool) {
        var replay = deferredReasons
        deferredReasons.removeAll()
        if !staleEpoch { replay.remove(.manual) }
        guard !replay.isEmpty else { return }
        pendingReasons.formUnion(replay)
        startCoalescing()
    }

    private func applyRateLimit(retryAfter: String?, now: Date) {
        let duration: TimeInterval
        if let seconds = RetryAfterParser.seconds(from: retryAfter, now: now) {
            duration = max(seconds, configuration.minimumCooldown)
        } else {
            let step = min(persistent.consecutiveRateLimitBackoffs, 10)
            duration = min(configuration.minimumCooldown * pow(2, Double(step)), configuration.maximumBackoffCooldown)
            persistent.consecutiveRateLimitBackoffs += 1
        }
        persistent.cooldownUntil = now.addingTimeInterval(duration)
        stateStore.save(persistent)
    }

    private func refillTokens(now: Date) {
        let interval = configuration.tokenRefillInterval
        guard interval > 0 else { return }
        let elapsed = now.timeIntervalSince(tokenRefillAnchor)
        guard elapsed >= interval else { return }
        let earned = Int(elapsed / interval)
        tokens = min(configuration.tokenCapacity, tokens + earned)
        tokenRefillAnchor = tokens == configuration.tokenCapacity
            ? now
            : tokenRefillAnchor.addingTimeInterval(Double(earned) * interval)
    }

    private func cooldownRemaining(now: Date) -> TimeInterval {
        guard let until = persistent.cooldownUntil else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    private var failureBackoffInterval: TimeInterval {
        guard !configuration.failureBackoff.isEmpty else { return 0 }
        let index = min(max(0, consecutiveFailures - 1), configuration.failureBackoff.count - 1)
        return configuration.failureBackoff[index]
    }

    /// Arms one timer for the earliest moment an automatic request could actually be sent, so
    /// a blocked state (401, empty budget, cooldown, backoff) never turns into periodic wakeups.
    private func rearmOnQueue() {
        timerGeneration += 1
        guard demandEnabled, !isBusy else { return }
        let generation = timerGeneration
        let now = clock.now
        let delay: TimeInterval
        if persistent.isUnauthorizedPaused, identity.credentialVersion == persistent.unauthorizedCredentialVersion {
            // Only a credential change lifts the pause; check for one rarely instead of polling.
            guard configuration.unauthorizedRecheckInterval > 0 else { return }
            delay = configuration.unauthorizedRecheckInterval
        } else {
            let next = nextAutomaticEligibleAt(now: now)
            var wait = next.timeIntervalSince(now)
            // A timer check that was skipped for a reason not modelled above must not spin.
            if idleTimerSkips > 0 { wait = max(wait, configuration.idleRecheckFloor) }
            delay = max(configuration.coalescingWindow, wait)
        }
        timer.schedule(after: delay) { [weak self] in
            guard let self else { return }
            queue.async {
                guard self.demandEnabled, self.timerGeneration == generation else { return }
                if let trigger = self.automaticTrigger {
                    trigger()
                } else {
                    self.enqueue(.scheduled)
                }
            }
        }
    }

    /// Earliest time a `.scheduled` request passes every automatic gate.
    private func nextAutomaticEligibleAt(now: Date) -> Date {
        var next = currentEpochLastSuccessAt?.addingTimeInterval(automaticMinimumInterval) ?? now
        if let lastServerAttemptAt, consecutiveFailures > 0 {
            next = max(next, lastServerAttemptAt.addingTimeInterval(failureBackoffInterval))
        }
        if let cooldownUntil = persistent.cooldownUntil { next = max(next, cooldownUntil) }
        if tokens < configuration.automaticTokenCost, configuration.tokenRefillInterval > 0 {
            let missing = Double(configuration.automaticTokenCost - tokens)
            next = max(next, tokenRefillAnchor.addingTimeInterval(missing * configuration.tokenRefillInterval))
        }
        if let freshUntil = realtimeFreshUntil(),
           !calibrationCapExceeded(now: now) {
            if freshUntil > next {
                // Wake when local data goes stale, or at the calibration cap, whichever is first.
                var wake = freshUntil
                if let cap = calibrationIntervalCap() ?? configuration.realtimeCalibrationCap, cap > 0,
                   let successAt = currentEpochLastSuccessAt {
                    wake = min(wake, successAt.addingTimeInterval(cap))
                }
                next = max(next, wake)
            }
        }
        return next
    }

    private func log(
        _ kind: FetchSchedulerLogEvent.Kind,
        reasons: [FetchRequestReason],
        skip: FetchSkipReason? = nil,
        outcome: String? = nil
    ) {
        let now = clock.now
        if kind == .dispatched {
            idleTimerSkips = 0
        } else if kind == .skipped, reasons == [.scheduled], skip != .coalescedIntoInFlight {
            idleTimerSkips += 1
        }
        logSink(FetchSchedulerLogEvent(
            kind: kind, reasons: reasons, skipReason: skip, tokens: tokens,
            cooldownRemaining: cooldownRemaining(now: now), outcome: outcome, timestamp: now))
    }

    private static func label(_ result: UsageFetchResult) -> String {
        switch result {
        case .success: return "success"
        case .rateLimited: return "rate_limited"
        case .unauthorized: return "unauthorized"
        case .failure: return "failure"
        }
    }
}
