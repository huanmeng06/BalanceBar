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

    func testTheMinimumIntervalThenTheTokensDecideWhenTheNextReadCanHappen() {
        // Read 60 s ago: 120 s of the 3-minute minimum are left.
        XCTAssertEqual(status(tokens: 1, next: base.addingTimeInterval(100), lastDispatch: base.addingTimeInterval(-60)).phase(now: base),
                       .waitingInterval(remaining: 120, total: 180))
        // Interval over, one token short (an automatic read costs two): the next token arrives in 100 s.
        XCTAssertEqual(status(tokens: 1, next: base.addingTimeInterval(100), lastDispatch: base.addingTimeInterval(-200)).phase(now: base),
                       .waitingTokens(remaining: 100, total: 180))
        // Both tokens missing: the first arrives in 100 s, the second 180 s later.
        XCTAssertEqual(status(tokens: 0, next: base.addingTimeInterval(100), lastDispatch: base.addingTimeInterval(-200)).phase(now: base),
                       .waitingTokens(remaining: 280, total: 360))
        // Tokens earned while the Settings page was open count.
        let waiting = status(tokens: 1, next: base.addingTimeInterval(100), lastDispatch: base.addingTimeInterval(-200))
        XCTAssertEqual(waiting.tokensAvailable(at: base.addingTimeInterval(101)), 2)
        XCTAssertEqual(waiting.phase(now: base.addingTimeInterval(101)), .ready)
    }

    func testTokensNeverExceedTheCapacity() {
        let full = status(tokens: 2, next: base.addingTimeInterval(10))
        XCTAssertEqual(full.tokensAvailable(at: base.addingTimeInterval(10_000)), 3)
    }
}
