import XCTest
@testable import BalanceBar

final class FetchSchedulerTests: XCTestCase {
    private final class FakeClock: SchedulerClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private final class ManualTimer: SchedulerTimer {
        var works: [() -> Void] = []
        var delays: [TimeInterval] = []
        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            delays.append(delay)
            works.append(work)
        }
        func fireAll() { let pending = works; works = []; pending.forEach { $0() } }
    }

    private final class FakeTransport: UsageFetchTransport {
        var completions: [(UsageFetchResult) -> Void] = []
        func fetchUsage(completion: @escaping (UsageFetchResult) -> Void) { completions.append(completion) }
        func complete(_ result: UsageFetchResult) { completions.removeFirst()(result) }
    }

    private final class MemoryStore: FetchSchedulerStateStoring {
        var state: FetchSchedulerPersistentState?
        func load() -> FetchSchedulerPersistentState? { state }
        func save(_ state: FetchSchedulerPersistentState) { self.state = state }
    }

    private final class FakeIdentity: AccountIdentityProviding {
        var accountIdentity: AccountIdentity? = AccountIdentity(stableID: "acct", idSource: .accountUUID)
        var credentialVersion: CredentialVersion? = CredentialVersion("v1")
        var accountEpoch = AccountEpoch.initial
    }

    private final class FakeFreePath: ManualRefreshFreePathChecking {
        var satisfied = false
        var windows: [TimeInterval] = []
        func checkFreePath(within window: TimeInterval, completion: @escaping (Bool) -> Void) {
            windows.append(window)
            completion(satisfied)
        }
    }

    private final class FakeRealtime: RealtimeSourceFreshnessProviding {
        var lastTrustedRealtimeObservationAt: Date?
        var pendingResetOf: Date?
        var realtimeFreshUntil: Date?
    }

    private var clock: FakeClock!
    private var timer: ManualTimer!
    private var transport: FakeTransport!
    private var store: MemoryStore!
    private var identity: FakeIdentity!
    private var logs: [FetchSchedulerLogEvent] = []
    private var deliveries: [FetchSchedulerDelivery] = []

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        timer = ManualTimer()
        transport = FakeTransport()
        store = MemoryStore()
        identity = FakeIdentity()
        logs = []
        deliveries = []
    }

    private func makeScheduler(
        freePath: ManualRefreshFreePathChecking? = nil,
        realtime: RealtimeSourceFreshnessProviding? = nil,
        cap: TimeInterval? = nil,
        automaticInterval: TimeInterval? = nil,
        configuration: FetchSchedulerConfiguration = FetchSchedulerConfiguration()
    ) -> FetchScheduler {
        let scheduler = FetchScheduler(
            transport: transport, identity: identity, stateStore: store, clock: clock, timer: timer,
            freePathChecker: freePath, realtimeFreshness: realtime, calibrationIntervalCap: { cap },
            automaticIntervalOverride: { automaticInterval },
            configuration: configuration,
            logSink: { [unowned self] in logs.append($0) })
        scheduler.addResultHandler { [unowned self] in deliveries.append($0) }
        scheduler.waitUntilIdle()
        return scheduler
    }

    private func request(_ scheduler: FetchScheduler, _ reasons: FetchRequestReason...) {
        reasons.forEach { scheduler.requestFetch(reason: $0) }
        scheduler.waitUntilIdle()
        timer.fireAll()
        scheduler.waitUntilIdle()
        scheduler.waitUntilIdle() // free-path completions hop back onto the queue once more
    }

    private func complete(_ scheduler: FetchScheduler, _ result: UsageFetchResult) {
        transport.complete(result)
        scheduler.waitUntilIdle()
    }

    private var lastSkip: FetchSkipReason? { logs.last(where: { $0.kind == .skipped })?.skipReason }

    func testBurstOfRequestsIsCoalescedIntoOneDispatch() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled, .externalActivity, .estimatedCalibration)
        XCTAssertEqual(transport.completions.count, 1)
        let dispatched = logs.filter { $0.kind == .dispatched }
        XCTAssertEqual(dispatched.count, 1)
        XCTAssertEqual(dispatched.first?.reasons, [.estimatedCalibration, .externalActivity, .scheduled])
    }

    func testSingleFlightBroadcastsOneResult() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled)
        request(scheduler, .manual)
        XCTAssertEqual(transport.completions.count, 1)
        XCTAssertEqual(lastSkip, .coalescedIntoInFlight)
        var otherDeliveries = 0
        scheduler.addResultHandler { _ in otherDeliveries += 1 }
        complete(scheduler, .success(Data()))
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(otherDeliveries, 1)
    }

    func testAutomaticMinimumInterval() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled)
        complete(scheduler, .success(Data()))
        clock.advance(QuotaConstants.automaticRequestMinimumInterval - 1)
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .minimumInterval)
        clock.advance(1)
        request(scheduler, .scheduled)
        XCTAssertEqual(transport.completions.count, 1)
    }

    /// Issue #580: the reset deadline already passed, so its confirmation must not wait
    /// out the automatic minimum interval; only cooldown, 401 and backoff may hold it.
    func testResetConfirmationBypassesMinimumInterval() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .scheduled)
        complete(scheduler, .success(Data()))
        clock.advance(299) // inside Claude V1's five-minute minimum interval
        request(scheduler, .resetConfirmation)
        XCTAssertEqual(transport.completions.count, 1, "the confirmation must dispatch immediately")
    }

    func testResetConfirmationStillHonorsCooldown() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled)
        complete(scheduler, .rateLimited(retryAfter: "1800"))
        request(scheduler, .resetConfirmation)
        XCTAssertEqual(lastSkip, .cooldown)
    }

    /// Issue #580: a success from before the pending deadline describes the previous
    /// cycle and cannot confirm the reset, so it must not suppress a manual refresh.
    func testManualRefreshDuringPendingResetIsNotSuppressedByRecentResult() {
        let realtime = FakeRealtime()
        let scheduler = makeScheduler(realtime: realtime)
        request(scheduler, .scheduled)
        complete(scheduler, .success(Data()))
        realtime.pendingResetOf = clock.now.addingTimeInterval(60)
        request(scheduler, .manual)
        XCTAssertEqual(transport.completions.count, 1, "the manual refresh must reach the server")
    }

    /// A success newer than the pending deadline already answered the confirmation,
    /// so the normal recent-result window keeps suppressing manual refreshes.
    func testManualRefreshAfterPendingResetSuccessIsStillSuppressed() {
        let realtime = FakeRealtime()
        let scheduler = makeScheduler(realtime: realtime)
        request(scheduler, .scheduled)
        complete(scheduler, .success(Data()))
        realtime.pendingResetOf = clock.now.addingTimeInterval(-60)
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .recentResult)
    }

    func testClaudeV1UsesFiveMinuteCadenceAndOneTokenPerRequest() {
        let configuration = FetchSchedulerConfiguration.claudeV1
        XCTAssertEqual(configuration.automaticMinimumInterval, 300)
        XCTAssertEqual(configuration.tokenRefillInterval, 300)
        XCTAssertEqual(configuration.automaticTokenCost, 1)
        XCTAssertEqual(configuration.manualTokenCost, 1)
        XCTAssertEqual(configuration.failureBackoff, [60, 120, 240, 480, 900])
    }

    func testSelectedAutomaticIntervalReplacesConfiguredMinimum() {
        let scheduler = makeScheduler(automaticInterval: 600, configuration: .claudeV1)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        complete(scheduler, .success(Data()))
        clock.advance(300)
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .minimumInterval, "5 min is no longer enough once 10 min is selected")
        XCTAssertEqual(scheduler.statusSnapshot().automaticMinimumInterval, 600)
        clock.advance(300)
        request(scheduler, .scheduled)
        XCTAssertEqual(transport.completions.count, 1)
    }

    func testClaudeFailureBackoffStartsAtLastAttempt() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .initial)
        complete(scheduler, .failure("network"))
        clock.advance(59)
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .failureBackoff)
        clock.advance(1)
        request(scheduler, .scheduled)
        XCTAssertEqual(transport.completions.count, 1)
    }

    /// Issue #580 review: menus need the real failure-backoff deadline to explain
    /// why a click would not reach the server.
    func testStatusSnapshotReportsFailureBackoffUntil() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .scheduled)
        complete(scheduler, .failure("network"))
        XCTAssertEqual(scheduler.statusSnapshot().failureBackoffUntil, clock.now.addingTimeInterval(60))
        clock.advance(61)
        XCTAssertNil(scheduler.statusSnapshot().failureBackoffUntil, "the backoff has ended")
        XCTAssertNil(scheduler.statusSnapshot().manualTokensReadyAt, "remaining tokens still cover a manual read")
    }

    func testClaudeSuccessTimeRestoresOnlyForSameAccount() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .initial)
        complete(scheduler, .success(Data()))

        let sameAccount = makeScheduler(configuration: .claudeV1)
        request(sameAccount, .manual)
        XCTAssertEqual(lastSkip, .recentResult)

        identity.accountIdentity = AccountIdentity(stableID: "other", idSource: .accountUUID)
        let otherAccount = makeScheduler(configuration: .claudeV1)
        request(otherAccount, .manual)
        XCTAssertEqual(transport.completions.count, 1)
    }

    func testTokenReservationAutomaticNeedsTwoManualNeedsOne() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled) // 3 -> 1
        XCTAssertEqual(logs.last { $0.kind == .dispatched }?.tokens, 1)
        complete(scheduler, .failure("x"))
        request(scheduler, .manual) // 1 -> 0
        XCTAssertEqual(logs.last { $0.kind == .dispatched }?.tokens, 0)
        complete(scheduler, .failure("x"))
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .insufficientTokens)
        clock.advance(QuotaConstants.requestTokenRefillInterval) // refill -> 1
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .insufficientTokens, "automatic needs two tokens")
        XCTAssertEqual(logs.last?.tokens, 1)
        request(scheduler, .manual)
        XCTAssertEqual(transport.completions.count, 1, "manual needs one token")
    }

    func testRetryAfterParsing() {
        let now = clock.now
        XCTAssertEqual(RetryAfterParser.seconds(from: "120", now: now), 120)
        XCTAssertNil(RetryAfterParser.seconds(from: "0", now: now))
        XCTAssertNil(RetryAfterParser.seconds(from: nil, now: now))
        XCTAssertNil(RetryAfterParser.seconds(from: "soon", now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: now.addingTimeInterval(3_600))
        XCTAssertEqual(RetryAfterParser.seconds(from: date, now: now) ?? 0, 3_600, accuracy: 1)
        XCTAssertNil(RetryAfterParser.seconds(from: formatter.string(from: now.addingTimeInterval(-10)), now: now))
    }

    private func cooldownAfter429(_ scheduler: FetchScheduler, retryAfter: String?) -> TimeInterval {
        clock.advance(QuotaConstants.automaticRequestMinimumInterval)
        request(scheduler, .manual)
        complete(scheduler, .rateLimited(retryAfter: retryAfter))
        let remaining = (store.state?.cooldownUntil ?? clock.now).timeIntervalSince(clock.now)
        clock.advance(remaining)
        clock.advance(QuotaConstants.requestTokenRefillInterval * 3)
        return remaining
    }

    func testRateLimitCooldownHeaderCombinations() {
        let scheduler = makeScheduler()
        XCTAssertEqual(cooldownAfter429(scheduler, retryAfter: "30"), 15 * 60, "short Retry-After floors to 15 min")
        XCTAssertEqual(cooldownAfter429(scheduler, retryAfter: "7200"), 7_200)
        XCTAssertEqual(cooldownAfter429(scheduler, retryAfter: nil), 15 * 60)
        XCTAssertEqual(cooldownAfter429(scheduler, retryAfter: "0"), 30 * 60)
        XCTAssertEqual(cooldownAfter429(scheduler, retryAfter: nil), 60 * 60)
        XCTAssertEqual(cooldownAfter429(scheduler, retryAfter: nil), 60 * 60, "backoff caps at 60 min")
        request(scheduler, .manual)
        complete(scheduler, .success(Data()))
        XCTAssertEqual(store.state?.consecutiveRateLimitBackoffs, 0)
    }

    func testCooldownBlocksManualAndSurvivesRestart() {
        let scheduler = makeScheduler()
        request(scheduler, .manual)
        complete(scheduler, .rateLimited(retryAfter: nil))
        clock.advance(60)
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .cooldown)
        XCTAssertEqual(logs.last?.cooldownRemaining, 14 * 60)

        let restarted = makeScheduler()
        request(restarted, .scheduled)
        XCTAssertEqual(lastSkip, .cooldown)
        XCTAssertTrue(transport.completions.isEmpty)
        clock.advance(14 * 60)
        request(restarted, .scheduled)
        XCTAssertEqual(transport.completions.count, 1)
    }

    func testFileStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("scheduler.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = FetchSchedulerPersistentState(
            cooldownUntil: Date(timeIntervalSince1970: 1_800_000_900), consecutiveRateLimitBackoffs: 2,
            unauthorizedCredentialVersion: CredentialVersion("v1"), isUnauthorizedPaused: true)
        FileFetchSchedulerStateStore(fileURL: url).save(state)
        XCTAssertEqual(FileFetchSchedulerStateStore(fileURL: url).load(), state)
    }

    func testStaleEpochResultIsDiscarded() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled)
        identity.accountEpoch = identity.accountEpoch.next
        complete(scheduler, .success(Data()))
        XCTAssertTrue(deliveries.isEmpty)
        XCTAssertEqual(logs.last?.kind, .discardedStaleEpoch)
    }

    func testUnauthorizedPausesUntilCredentialVersionChanges() {
        let scheduler = makeScheduler()
        request(scheduler, .manual)
        complete(scheduler, .unauthorized)
        clock.advance(3_600)
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .unauthorizedPaused)
        identity.credentialVersion = CredentialVersion("v2")
        request(scheduler, .manual)
        XCTAssertEqual(transport.completions.count, 1)
        XCTAssertEqual(store.state?.isUnauthorizedPaused, false)
    }

    func testManualRefreshWindowAndFreePath() {
        let freePath = FakeFreePath()
        let scheduler = makeScheduler(freePath: freePath)
        request(scheduler, .manual)
        complete(scheduler, .success(Data()))
        clock.advance(30)
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .recentResult)
        clock.advance(30)
        freePath.satisfied = true
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .freePathSatisfied)
        XCTAssertEqual(freePath.windows.last, QuotaConstants.manualRefreshWindow)
        freePath.satisfied = false
        request(scheduler, .manual)
        XCTAssertEqual(transport.completions.count, 1)
    }

    func testManualRefreshSatisfiedByLocalDataRearmsAutomaticTimer() {
        let freePath = FakeFreePath()
        let scheduler = makeScheduler(freePath: freePath, configuration: .claudeV1)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        complete(scheduler, .success(Data()))
        clock.advance(400) // past the manual refresh window, so the free-path check runs
        freePath.satisfied = true
        scheduler.requestFetch(reason: .manual)
        scheduler.waitUntilIdle()
        timer.delays.removeAll()
        timer.fireAll() // ends the coalescing window, which runs the evaluation
        scheduler.waitUntilIdle()
        scheduler.waitUntilIdle()
        XCTAssertEqual(lastSkip, .freePathSatisfied)
        XCTAssertFalse(timer.delays.isEmpty, "the automatic timer is armed again once the check ends")
    }

    func testManualRefreshWithoutTokensAfterFreePathCheckRearmsAutomaticTimer() {
        let freePath = FakeFreePath()
        var configuration = FetchSchedulerConfiguration.claudeV1
        configuration.tokenCapacity = 1
        configuration.tokenRefillInterval = 100_000
        let scheduler = makeScheduler(freePath: freePath, configuration: configuration)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        complete(scheduler, .success(Data())) // spends the only token
        clock.advance(400)
        scheduler.requestFetch(reason: .manual)
        scheduler.waitUntilIdle()
        timer.delays.removeAll()
        timer.fireAll()
        scheduler.waitUntilIdle()
        scheduler.waitUntilIdle()
        XCTAssertEqual(lastSkip, .insufficientTokens)
        XCTAssertFalse(timer.delays.isEmpty)
    }

    func testSourceProvidedFreshUntilReplacesTheConfiguredFreshness() {
        let realtime = FakeRealtime()
        let scheduler = makeScheduler(realtime: realtime, cap: 3_600)
        request(scheduler, .scheduled)
        complete(scheduler, .success(Data()))
        clock.advance(300)
        // 250 s after the observation is past the default 120 s, but the source says it is valid for 600 s.
        realtime.lastTrustedRealtimeObservationAt = clock.now.addingTimeInterval(-250)
        realtime.realtimeFreshUntil = clock.now.addingTimeInterval(350)
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .realtimeSourceFresh)
        clock.advance(400)
        request(scheduler, .scheduled)
        XCTAssertEqual(transport.completions.count, 1, "once the source's own validity ends the read goes ahead")
    }

    func testFreshRealtimeSourceSuppressesAutomaticUntilCalibrationCap() {
        let realtime = FakeRealtime()
        let scheduler = makeScheduler(realtime: realtime, cap: 600)
        request(scheduler, .scheduled)
        complete(scheduler, .success(Data()))
        clock.advance(300)
        realtime.lastTrustedRealtimeObservationAt = clock.now
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .realtimeSourceFresh)
        clock.advance(300)
        realtime.lastTrustedRealtimeObservationAt = clock.now
        request(scheduler, .scheduled)
        XCTAssertEqual(transport.completions.count, 1, "cap reached forces a calibration request")
    }

    func testEveryRequestAndSkipIsLoggedWithTokensAndCooldown() {
        let scheduler = makeScheduler()
        request(scheduler, .scheduled)
        request(scheduler, .scheduled)
        XCTAssertEqual(logs.map(\.kind), [.requested, .dispatched, .requested, .skipped])
        XCTAssertEqual(logs.last?.skipReason, .coalescedIntoInFlight)
        XCTAssertEqual(logs.last?.tokens, 1)
        XCTAssertEqual(logs.last?.cooldownRemaining, 0)
    }

    func testManualRefreshAfterAccountSwitchIgnoresPreviousAccountSuccess() {
        let freePath = FakeFreePath()
        let scheduler = makeScheduler(freePath: freePath)
        request(scheduler, .manual)
        complete(scheduler, .success(Data()))
        clock.advance(30)
        identity.accountEpoch = identity.accountEpoch.next
        request(scheduler, .manual)
        XCTAssertEqual(freePath.windows.count, 2, "free path is checked for the new account")
        XCTAssertEqual(transport.completions.count, 1)
        XCTAssertNotEqual(lastSkip, .recentResult)
    }

    func testUnauthorizedForOldCredentialDoesNotPauseNewCredential() {
        let scheduler = makeScheduler()
        request(scheduler, .manual)
        identity.credentialVersion = CredentialVersion("v2")
        complete(scheduler, .unauthorized)
        XCTAssertNotEqual(store.state?.isUnauthorizedPaused, true)
        request(scheduler, .manual)
        XCTAssertEqual(transport.completions.count, 1)
    }

    // MARK: - Scheduler-owned timer

    /// Starts demand and returns the delay of the automatic timer the scheduler armed.
    private func armedDelay(after action: () -> Void) -> TimeInterval? {
        timer.delays.removeAll()
        action()
        return timer.delays.last
    }

    func testTimerTargetsFiveMinutesAfterSuccessAndDispatchesWhenDue() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        let delay = armedDelay { complete(scheduler, .success(Data())) }
        XCTAssertEqual(delay, 300)
        clock.advance(300)
        timer.fireAll()
        scheduler.waitUntilIdle()
        timer.fireAll() // coalescing window of the timer's `.scheduled` request
        scheduler.waitUntilIdle()
        XCTAssertEqual(transport.completions.count, 1)
        XCTAssertEqual(logs.last { $0.kind == .dispatched }?.reasons, [.scheduled])
    }

    func testTimerUsesAutomaticTriggerWhenSet() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        var triggered = 0
        scheduler.setAutomaticTrigger { triggered += 1 }
        scheduler.setDemand(true)
        scheduler.waitUntilIdle()
        timer.fireAll()
        scheduler.waitUntilIdle()
        XCTAssertEqual(triggered, 1)
        XCTAssertTrue(transport.completions.isEmpty)
    }

    func testUnauthorizedPauseArmsSlowRecheckInsteadOfSpinning() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        XCTAssertEqual(armedDelay { complete(scheduler, .unauthorized) }, 300)
        for _ in 0..<3 {
            clock.advance(300)
            let delays = { () -> [TimeInterval] in
                timer.delays.removeAll()
                timer.fireAll()
                scheduler.waitUntilIdle()
                timer.fireAll()
                scheduler.waitUntilIdle()
                return timer.delays
            }()
            XCTAssertEqual(lastSkip, .unauthorizedPaused)
            XCTAssertFalse(delays.contains { $0 > 1 && $0 < 300 }, "no sub-recheck wakeups: \(delays)")
        }
        XCTAssertEqual(transport.completions.count, 0)
    }

    func testEmptyTokenBudgetArmsAtRefillTime() {
        var configuration = FetchSchedulerConfiguration.claudeV1
        configuration.tokenCapacity = 1
        configuration.automaticMinimumInterval = 10
        let scheduler = makeScheduler(configuration: configuration)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        XCTAssertEqual(armedDelay { complete(scheduler, .success(Data())) }, 300)
    }

    func testCooldownArmsAtCooldownEnd() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        XCTAssertEqual(armedDelay { complete(scheduler, .rateLimited(retryAfter: "1800")) }, 1_800)
    }

    func testFreshLocalDataDefersTimerWithoutSpinning() {
        let realtime = FakeRealtime()
        let scheduler = makeScheduler(realtime: realtime, configuration: .claudeV1)
        scheduler.setDemand(true)
        request(scheduler, .initial)
        complete(scheduler, .success(Data()))
        clock.advance(300)
        // Local data keeps arriving exactly as the timer fires, so each check is skipped.
        for _ in 0..<3 {
            realtime.lastTrustedRealtimeObservationAt = clock.now
            timer.delays.removeAll()
            timer.fireAll()
            scheduler.waitUntilIdle()
            timer.fireAll()
            scheduler.waitUntilIdle()
            XCTAssertEqual(lastSkip, .realtimeSourceFresh)
            XCTAssertTrue(timer.delays.allSatisfy { $0 <= 1 || $0 >= 60 }, "\(timer.delays)")
            clock.advance(120)
        }
        XCTAssertEqual(transport.completions.count, 0)
    }

    func testDemandOffCancelsAutomaticChecks() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        scheduler.setDemand(true)
        scheduler.setDemand(false)
        scheduler.waitUntilIdle()
        timer.fireAll()
        scheduler.waitUntilIdle()
        timer.fireAll()
        scheduler.waitUntilIdle()
        XCTAssertTrue(transport.completions.isEmpty)
    }

    // MARK: - Account switch during a flight

    func testAccountSwitchDuringFlightIsReplayedAfterStaleResult() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .initial)
        identity.accountIdentity = AccountIdentity(stableID: "other", idSource: .accountUUID)
        identity.accountEpoch = identity.accountEpoch.next
        request(scheduler, .accountChanged)
        XCTAssertEqual(lastSkip, .coalescedIntoInFlight)
        complete(scheduler, .success(Data()))
        XCTAssertTrue(deliveries.isEmpty, "old account's result is discarded")
        timer.fireAll()
        scheduler.waitUntilIdle()
        XCTAssertEqual(transport.completions.count, 1, "new account gets its own read")
        XCTAssertEqual(logs.last { $0.kind == .dispatched }?.reasons, [.accountChanged])
    }

    func testManualDuringSameAccountFlightIsAnsweredByThatFlight() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .initial)
        request(scheduler, .manual)
        complete(scheduler, .success(Data()))
        timer.fireAll()
        scheduler.waitUntilIdle()
        XCTAssertTrue(transport.completions.isEmpty)
    }

    func testPersistedSuccessIsMatchedOnceIdentityLoads() {
        store.state = FetchSchedulerPersistentState(
            lastServerAttemptAt: clock.now, lastServerSuccessAt: clock.now, lastSuccessAccountKey: "acct")
        identity.accountIdentity = nil
        let scheduler = makeScheduler(configuration: .claudeV1)
        identity.accountIdentity = AccountIdentity(stableID: "acct", idSource: .accountUUID)
        clock.advance(60)
        request(scheduler, .scheduled)
        XCTAssertEqual(lastSkip, .minimumInterval)
        XCTAssertTrue(transport.completions.isEmpty)
    }

    func testParseFailureCountsAsFailureNotSuccess() {
        let scheduler = makeScheduler(configuration: .claudeV1)
        request(scheduler, .initial)
        complete(scheduler, .failure("invalid_response"))
        XCTAssertNil(store.state?.lastServerSuccessAt)
        XCTAssertEqual(store.state?.consecutiveFailures, 1)
        request(scheduler, .manual)
        XCTAssertEqual(lastSkip, .failureBackoff)
    }
}
