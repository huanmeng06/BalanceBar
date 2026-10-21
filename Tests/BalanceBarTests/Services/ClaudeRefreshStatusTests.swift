import XCTest
@testable import BalanceBar

final class ClaudeRefreshStatusTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(
        tokens: Int = 3, next: Date? = nil, lastDispatch: Date? = nil, cooldown: TimeInterval = 0, paused: Bool = false,
        busy: Bool = false, realtimeAt: Date? = nil
    ) -> ClaudeRefreshStatus {
        ClaudeRefreshStatus(
            scheduler: FetchSchedulerStatus(
                tokens: tokens, tokenCapacity: 3, tokenRefillInterval: 180, nextTokenAt: next, automaticTokenCost: 2,
                lastDispatchAt: lastDispatch, automaticMinimumInterval: 180, lastSuccessAt: lastDispatch,
                cooldownRemaining: cooldown, isUnauthorizedPaused: paused, isBusy: busy, at: base),
            realtimeAt: realtimeAt, realtimeFreshnessWindow: 120)
    }

    func testRefreshNowFollowsTheSchedulersManualPath() {
        XCTAssertEqual(status().manualRefresh(now: base), .now)
        XCTAssertEqual(status(lastDispatch: base.addingTimeInterval(-10)).manualRefresh(now: base), .justRead(remaining: 50),
                       "a read within the last minute makes a manual one unnecessary")
        XCTAssertEqual(status(tokens: 0, next: base.addingTimeInterval(40), lastDispatch: base.addingTimeInterval(-100))
            .manualRefresh(now: base), .noPoints(remaining: 40), "no point left until the next one arrives")
        XCTAssertEqual(status(tokens: 1, lastDispatch: base.addingTimeInterval(-100)).manualRefresh(now: base), .now,
                       "one point is enough for a manual read")
        XCTAssertEqual(status(lastDispatch: base.addingTimeInterval(-100), realtimeAt: base.addingTimeInterval(-30))
            .manualRefresh(now: base), .alreadyFresh)
        XCTAssertEqual(status(busy: true).manualRefresh(now: base), .reading)
        XCTAssertEqual(status(paused: true, busy: true).manualRefresh(now: base), .loginExpired)
        XCTAssertEqual(status(cooldown: 600, busy: true).manualRefresh(now: base.addingTimeInterval(100)), .rateLimited(remaining: 500))
        XCTAssertTrue(status().manualRefresh(now: base).isAvailable)
        XCTAssertFalse(status(busy: true).manualRefresh(now: base).isAvailable)
    }

    func testAnUntouchedSchedulerIsReady() {
        XCTAssertEqual(status().phase(now: base), .ready)
    }

    func testTheMostBlockingReasonWins() {
        XCTAssertEqual(status(paused: true, busy: true).phase(now: base), .loginExpired)
        XCTAssertEqual(status(cooldown: 600, busy: true).phase(now: base), .rateLimited(remaining: 600))
        XCTAssertEqual(status(cooldown: 600).phase(now: base.addingTimeInterval(100)), .rateLimited(remaining: 500),
                       "the cooldown counts down from when the snapshot was taken")
        XCTAssertEqual(status(busy: true).phase(now: base), .reading)
        XCTAssertEqual(status(lastDispatch: base.addingTimeInterval(-10), realtimeAt: base.addingTimeInterval(-30)).phase(now: base),
                       .liveFresh(age: 30), "fresh Mod data keeps the official endpoint out of it")
    }

    func testTheNextRefreshIsWhenBothTheIntervalAndThePointsAllowIt() {
        // Refreshed 60 s ago, one point left and the next in 100 s: the interval ends first (in 120 s) but the second
        // point only arrives in 100 s, so 120 s it is; the bar runs over the whole 180 s since the last refresh.
        XCTAssertEqual(status(tokens: 1, next: base.addingTimeInterval(100), lastDispatch: base.addingTimeInterval(-60)).phase(now: base),
                       .waiting(remaining: 120, total: 180))
        // The reported case: refreshed 3 min 31 s ago, interval over, one point short. One wait, not a second bar.
        XCTAssertEqual(status(tokens: 1, next: base.addingTimeInterval(67), lastDispatch: base.addingTimeInterval(-211)).phase(now: base),
                       .waiting(remaining: 67, total: 278))
        // Refreshed 7 s ago with no point left: the interval would end in 173 s, but two points take 173 + 180 s.
        XCTAssertEqual(status(tokens: 0, next: base.addingTimeInterval(173), lastDispatch: base.addingTimeInterval(-7)).phase(now: base),
                       .waiting(remaining: 353, total: 360))
        // Points earned while the Settings page was open count.
        let waiting = status(tokens: 1, next: base.addingTimeInterval(100), lastDispatch: base.addingTimeInterval(-200))
        XCTAssertEqual(waiting.tokensAvailable(at: base.addingTimeInterval(101)), 2)
        XCTAssertEqual(waiting.phase(now: base.addingTimeInterval(101)), .ready)
    }

    func testTheRemainingTimeOnlyCountsDownWhileWaiting() {
        let status = status(tokens: 0, next: base.addingTimeInterval(173), lastDispatch: base.addingTimeInterval(-7))
        var previous = TimeInterval.infinity
        for second in stride(from: 0.0, to: 353, by: 10) {
            guard case let .waiting(remaining, total) = status.phase(now: base.addingTimeInterval(second)) else {
                return XCTFail("still waiting at \(second) s")
            }
            XCTAssertLessThan(remaining, previous, "never jumps back up at \(second) s")
            XCTAssertEqual(total, 360, accuracy: 0.001, "one bar for the whole wait")
            previous = remaining
        }
        XCTAssertEqual(status.phase(now: base.addingTimeInterval(353)), .ready)
    }

    func testTokensNeverExceedTheCapacity() {
        let full = status(tokens: 2, next: base.addingTimeInterval(10))
        XCTAssertEqual(full.tokensAvailable(at: base.addingTimeInterval(10_000)), 3)
    }
}
