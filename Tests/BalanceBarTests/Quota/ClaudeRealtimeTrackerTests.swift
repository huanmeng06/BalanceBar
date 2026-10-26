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

    func testEachWindowExpiresWithItsOwnSourceValidity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var validity = ClaudeSourceValidity(oauth: 600, statusLine: 300, mod: 60)
        let tracker = ClaudeRealtimeTracker(validity: { validity }, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: now, epoch: .initial, source: .statusLine)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: now, epoch: .initial, source: .mod)
        XCTAssertEqual(tracker.realtimeFreshUntil, now.addingTimeInterval(60), "the shorter Mod validity ends freshness")
        XCTAssertEqual(tracker.lastTrustedRealtimeObservationAt, now)

        validity.mod = 600
        XCTAssertEqual(tracker.realtimeFreshUntil, now.addingTimeInterval(300), "changing the setting applies at once")

        tracker.markPendingReset(now)
        XCTAssertNil(tracker.realtimeFreshUntil, "a pending reset still disables freshness")
    }

    func testFreePathUsesTheOldestObservationAge() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = ClaudeRealtimeTracker(validity: { ClaudeSourceValidity(oauth: 600, statusLine: 600, mod: 600) }, now: { now })
        tracker.recordTrustedObservation(window: .fiveHour, observedAt: now, epoch: .initial)
        tracker.recordTrustedObservation(window: .sevenDay, observedAt: now, epoch: .initial)
        now = now.addingTimeInterval(200)
        var results: [Bool] = []
        tracker.checkFreePath(within: 300) { results.append($0) }
        tracker.checkFreePath(within: 100) { results.append($0) }
        XCTAssertEqual(results, [true, false])
        now = now.addingTimeInterval(500) // past the 600 s validity
        tracker.checkFreePath(within: 3_600) { results.append($0) }
        XCTAssertEqual(results.last, false)
    }
}
