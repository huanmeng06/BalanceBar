import XCTest
@testable import BalanceBar

final class ClaudeRealtimeTrackerTests: XCTestCase {
    func testFreshnessRequiresBothWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(freshness: 120, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: now, epoch: .initial)
        XCTAssertNil(tracker.lastTrustedRealtimeObservationAt)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: now, epoch: .initial)
        XCTAssertEqual(tracker.lastTrustedRealtimeObservationAt, now)
    }

    func testOlderWindowControlsFreshnessAndPendingResetDisablesIt() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(freshness: 120, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: now, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: now, epoch: .initial)
        now = now.addingTimeInterval(60)
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: now, epoch: .initial)
        XCTAssertEqual(tracker.bothWindowsFreshUntil, Date(timeIntervalSince1970: 1_800_000_120))
        let pendingResetOf = Date(timeIntervalSince1970: 1_800_000_090)
        tracker.markPendingReset(pendingResetOf)
        XCTAssertNil(tracker.bothWindowsFreshUntil)
        XCTAssertEqual(tracker.pendingResetOf, pendingResetOf)
        tracker.markPendingReset(nil)
        XCTAssertNil(tracker.pendingResetOf)
        XCTAssertEqual(tracker.bothWindowsFreshUntil, Date(timeIntervalSince1970: 1_800_000_120))
    }

    func testAccountResetDropsPreviousFreshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: now, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: now, epoch: .initial)
        tracker.reset(epoch: .initial.next)
        XCTAssertNil(tracker.lastTrustedRealtimeObservationAt)
    }

    func testObservationTimeInThePastDoesNotCreateFreshness() {
        // A rescanned old snapshot is recorded with its own observation time; the freshness
        // window measured from that time has already expired.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = now.addingTimeInterval(-3_600)
        let tracker = ClaudeRealtimeTracker(freshness: 120, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: stale, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: stale, epoch: .initial)
        XCTAssertNil(tracker.lastTrustedRealtimeObservationAt)
        XCTAssertNil(tracker.bothWindowsFreshUntil)
    }
}
