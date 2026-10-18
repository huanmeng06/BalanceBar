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
    private let configuration: FetchSchedulerConfiguration
    private let logSink: (FetchSchedulerLogEvent) -> Void
    private let queue: DispatchQueue

    private var persistent: FetchSchedulerPersistentState
    private var tokens: Int
    private var tokenRefillAnchor: Date
    private var pendingReasons: Set<FetchRequestReason> = []
    private var isCoalescing = false
    private var isBusy = false
    private var lastDispatchAt: Date?
    private var lastSuccessAt: Date?
    private var resultHandlers: [(FetchSchedulerDelivery) -> Void] = []

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
        self.configuration = configuration
        self.queue = queue
        self.logSink = logSink
        persistent = FetchSchedulerPersistentState()
        tokens = configuration.tokenCapacity
        tokenRefillAnchor = clock.now
        queue.async { [self] in
            if let loaded = stateStore.load() { persistent = loaded }
        }
    }

    /// Registers a handler that receives every current-epoch result. Called on the scheduler queue.
    public func addResultHandler(_ handler: @escaping (FetchSchedulerDelivery) -> Void) {
        queue.async { [self] in resultHandlers.append(handler) }
    }

    public func requestFetch(reason: FetchRequestReason) {
        queue.async { [self] in
            log(.requested, reasons: [reason])
            if isBusy {
                log(.skipped, reasons: [reason], skip: .coalescedIntoInFlight)
                return
            }
            pendingReasons.insert(reason)
            guard !isCoalescing else { return }
            isCoalescing = true
            timer.schedule(after: configuration.coalescingWindow) { [self] in
                queue.async { flushPending() }
            }
        }
    }

    /// Blocks until previously enqueued scheduler work has run. Intended for tests and shutdown.
    public func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Evaluation (scheduler queue only)

    private func flushPending() {
        isCoalescing = false
        let reasons = pendingReasons.sorted { $0.rawValue < $1.rawValue }
        pendingReasons.removeAll()
        guard !reasons.isEmpty else { return }
        evaluate(reasons)
    }

    private func evaluate(_ reasons: [FetchRequestReason]) {
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

        if reasons.contains(.manual) {
            evaluateManual(reasons, now: now)
        } else {
            evaluateAutomatic(reasons, now: now)
        }
    }

    private func evaluateManual(_ reasons: [FetchRequestReason], now: Date) {
        let window = configuration.manualRefreshWindow
        if let lastSuccessAt, now.timeIntervalSince(lastSuccessAt) < window {
            return log(.skipped, reasons: reasons, skip: .recentResult)
        }
        guard let freePathChecker else { return spendAndDispatch(reasons, cost: configuration.manualTokenCost) }
        isBusy = true
        freePathChecker.checkFreePath(within: window) { [self] satisfied in
            queue.async {
                isBusy = false
                if satisfied {
                    return log(.skipped, reasons: reasons, skip: .freePathSatisfied)
                }
                refillTokens(now: clock.now)
                spendAndDispatch(reasons, cost: configuration.manualTokenCost)
            }
        }
    }

    private func evaluateAutomatic(_ reasons: [FetchRequestReason], now: Date) {
        if let lastDispatchAt, now.timeIntervalSince(lastDispatchAt) < configuration.automaticMinimumInterval {
            return log(.skipped, reasons: reasons, skip: .minimumInterval)
        }
        if let realtimeAt = realtimeFreshness?.lastTrustedRealtimeObservationAt,
           now.timeIntervalSince(realtimeAt) < configuration.realtimeSourceFreshness,
           !calibrationCapExceeded(now: now) {
            return log(.skipped, reasons: reasons, skip: .realtimeSourceFresh)
        }
        spendAndDispatch(reasons, cost: configuration.automaticTokenCost)
    }

    private func calibrationCapExceeded(now: Date) -> Bool {
        guard let cap = calibrationIntervalCap(), cap > 0 else { return false }
        guard let lastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= cap
    }

    private func spendAndDispatch(_ reasons: [FetchRequestReason], cost: Int) {
        guard tokens >= cost else {
            return log(.skipped, reasons: reasons, skip: .insufficientTokens)
        }
        tokens -= cost
        isBusy = true
        lastDispatchAt = clock.now
        let epoch = identity.accountEpoch
        log(.dispatched, reasons: reasons)
        transport.fetchUsage { [self] result in
            queue.async { complete(result, reasons: reasons, epoch: epoch) }
        }
    }

    private func complete(_ result: UsageFetchResult, reasons: [FetchRequestReason], epoch: AccountEpoch) {
        isBusy = false
        let now = clock.now
        // A 429 is honored even for a stale epoch so an account switch cannot bypass the cooldown.
        if case let .rateLimited(retryAfter) = result {
            applyRateLimit(retryAfter: retryAfter, now: now)
        }
        guard identity.accountEpoch == epoch else {
            return log(.discardedStaleEpoch, reasons: reasons, outcome: Self.label(result))
        }
        switch result {
        case .success:
            lastSuccessAt = now
            if persistent.consecutiveRateLimitBackoffs != 0 || persistent.cooldownUntil != nil {
                persistent.consecutiveRateLimitBackoffs = 0
                persistent.cooldownUntil = nil
                stateStore.save(persistent)
            }
        case .unauthorized:
            persistent.isUnauthorizedPaused = true
            persistent.unauthorizedCredentialVersion = identity.credentialVersion
            stateStore.save(persistent)
        case .rateLimited, .failure:
            break
        }
        log(.completed, reasons: reasons, outcome: Self.label(result))
        let delivery = FetchSchedulerDelivery(result: result, reasons: reasons, epoch: epoch, receivedAt: now)
        resultHandlers.forEach { $0(delivery) }
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

    private func log(
        _ kind: FetchSchedulerLogEvent.Kind,
        reasons: [FetchRequestReason],
        skip: FetchSkipReason? = nil,
        outcome: String? = nil
    ) {
        let now = clock.now
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
