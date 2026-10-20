import XCTest
@testable import BalanceBar

/// Replays one simulated five-hour window through the real `FetchScheduler` with and without
/// estimate-driven calibration, and reports request counts against official-value freshness.
final class EstimateCalibrationSimulationTests: XCTestCase {
    private final class FakeClock: SchedulerClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class ManualTimer: SchedulerTimer {
        var works: [() -> Void] = []
        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) { works.append(work) }
        func fireAll() { let pending = works; works = []; pending.forEach { $0() } }
    }

    private final class FakeTransport: UsageFetchTransport {
        var completions: [(UsageFetchResult) -> Void] = []
        var dispatched = 0
        func fetchUsage(completion: @escaping (UsageFetchResult) -> Void) {
            dispatched += 1
            completions.append(completion)
        }
    }

    private final class MemoryStore: FetchSchedulerStateStoring {
        func load() -> FetchSchedulerPersistentState? { nil }
        func save(_ state: FetchSchedulerPersistentState) {}
    }

    private final class FakeIdentity: AccountIdentityProviding {
        var accountIdentity: AccountIdentity? = AccountIdentity(stableID: "acct", idSource: .accountUUID)
        var credentialVersion: CredentialVersion? = CredentialVersion("v1")
        var accountEpoch = AccountEpoch.initial
    }

    private struct Outcome {
        var requests = 0
        var meanError = 0.0
        var maxError = 0.0
        var requestsToReachNotification: Int?
    }

    /// Used percentage: 35 active minutes at 0.5 points/min in every hour, idle otherwise.
    private func trueUsed(atMinute minute: Int) -> Double {
        let hours = minute / 60
        let within = minute % 60
        return Double(hours) * 17.5 + Double(min(within, 35)) * 0.5
    }

    private func run(scheduledEveryMinutes: Int, calibrated: Bool) -> Outcome {
        let clock = FakeClock()
        let timer = ManualTimer()
        let transport = FakeTransport()
        let scheduler = FetchScheduler(
            transport: transport, identity: FakeIdentity(), stateStore: MemoryStore(), clock: clock, timer: timer)
        let base = clock.now
        let trigger = EstimateCalibrationTrigger(scheduler: scheduler, notificationThresholds: { _ in [20, 10] })
        var official = 0.0
        var officialTrue = 0.0
        var readings = 0
        var errorSum = 0.0
        var outcome = Outcome()

        for minute in 0...300 {
            clock.now = base.addingTimeInterval(Double(minute) * 60)
            let truth = trueUsed(atMinute: minute)
            if minute % scheduledEveryMinutes == 0 { scheduler.requestFetch(reason: .scheduled) }
            if calibrated, readings > 0 {
                // The estimator under-reads by 15%; confidence qualifies after three official readings.
                let estimated = min(100, official + 0.85 * (truth - officialTrue))
                let confidence = readings >= 3 ? 0.8 : 0
                trigger.evaluate(
                    accountID: "acct", window: .fiveHour,
                    estimate: UsageEstimate(percent: estimated, confidence: confidence, errorRange: 2))
            }
            scheduler.waitUntilIdle()
            timer.fireAll()
            scheduler.waitUntilIdle()
            while !transport.completions.isEmpty {
                transport.completions.removeFirst()(.success(Data()))
                scheduler.waitUntilIdle()
                official = truth
                officialTrue = truth
                readings += 1
                trigger.recordOfficial(accountID: "acct", window: .fiveHour, percent: official)
            }
            let error = abs(truth - official)
            errorSum += error
            outcome.maxError = max(outcome.maxError, error)
        }
        outcome.requests = transport.dispatched
        outcome.meanError = errorSum / 301
        return outcome
    }

    func testEstimateDrivenCalibrationSpendsRequestsWhereUsageMoves() {
        let slow = run(scheduledEveryMinutes: 15, calibrated: false)
        let fast = run(scheduledEveryMinutes: 3, calibrated: false)
        let driven = run(scheduledEveryMinutes: 15, calibrated: true)

        func row(_ name: String, _ o: Outcome) -> String {
            String(format: "%@ | requests %3d | mean |official-true| %.2f pt | max %.2f pt", name, o.requests, o.meanError, o.maxError)
        }
        print("""
        === BB-17 calibration simulation (5h window, 301 one-minute steps) ===
        \(row("A scheduled 3 min, no estimate   ", fast))
        \(row("B scheduled 15 min, no estimate  ", slow))
        \(row("C scheduled 15 min + estimate    ", driven))
        """)

        XCTAssertGreaterThan(driven.requests, slow.requests, "estimate rises must add some reads")
        XCTAssertLessThan(driven.meanError, slow.meanError, "estimate-driven reads must make the official value fresher")
        XCTAssertLessThan(driven.maxError, slow.maxError)
        XCTAssertLessThanOrEqual(driven.requests, fast.requests, "the scheduler's rules still bound the request rate")
    }
}
