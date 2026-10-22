import XCTest
@testable import BalanceBar

final class ClaudeRealtimeTrackerTests: XCTestCase {
    func testFreshnessRequiresBothWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(freshness: 120, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, receivedAt: now, epoch: .initial)
        XCTAssertNil(tracker.lastTrustedRealtimeObservationAt)
        tracker.recordTrustedObservation(window: .sevenDay, receivedAt: now, epoch: .initial)
        XCTAssertEqual(tracker.lastTrustedRealtimeObservationAt, now)
    }

    func testOlderWindowControlsFreshnessAndPendingResetDisablesIt() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(freshness: 120, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, receivedAt: now, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, receivedAt: now, epoch: .initial)
        now = now.addingTimeInterval(60)
        tracker.recordTrustedObservation(window: .fiveHour, receivedAt: now, epoch: .initial)
        XCTAssertEqual(tracker.bothWindowsFreshUntil, Date(timeIntervalSince1970: 1_800_000_120))
        tracker.markPendingReset(true)
        XCTAssertNil(tracker.bothWindowsFreshUntil)
    }

    func testAccountResetDropsPreviousFreshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, receivedAt: now, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, receivedAt: now, epoch: .initial)
        tracker.reset(epoch: .initial.next)
        XCTAssertNil(tracker.lastTrustedRealtimeObservationAt)
    }
}
