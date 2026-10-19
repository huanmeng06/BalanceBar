import Foundation
import XCTest
@testable import BalanceBar

final class MultiDeviceCompensationTests: XCTestCase {
    private final class FakeScheduler: FetchScheduling {
        var reasons: [FetchRequestReason] = []
        func requestFetch(reason: FetchRequestReason) { reasons.append(reason) }
    }

    private final class FakeLocalGrowth: LocalUsageGrowthEstimating {
        var growth: Double? = 0
        func estimatedLocalGrowth(for window: QuotaWindowKind, from start: Date, to end: Date) -> Double? { growth }
    }

    /// Manual timer: `advance(by:)` moves the shared clock and runs due work in order.
    private final class ManualTimer: MultiDeviceTimer {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        private var pending: [(due: Date, work: () -> Void)] = []
        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            pending.append((current.addingTimeInterval(delay), work))
        }
        func advance(by interval: TimeInterval) {
            let target = current.addingTimeInterval(interval)
            while let index = pending.indices.filter({ pending[$0].due <= target })
                .min(by: { pending[$0].due < pending[$1].due }) {
                let next = pending.remove(at: index)
                current = max(current, next.due)
                next.work()
            }
            current = target
        }
    }

    private let desktop = "com.anthropic.claudefordesktop"
    private var scheduler = FakeScheduler()
    private var local = FakeLocalGrowth()
    private var timer = ManualTimer()

    private func makeCompensator(local: LocalUsageGrowthEstimating? = nil) -> MultiDeviceCompensator {
        MultiDeviceCompensator(
            scheduler: scheduler,
            localGrowth: local ?? self.local,
            timer: timer,
            now: { [unowned self] in timer.current }
        )
    }

    private func observation(_ used: Double, trust: QuotaTrust = .a) -> QuotaObservation {
        QuotaObservation(
            window: .fiveHour, usedPercentage: used,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000 + 7_200), receivedAt: timer.current,
            source: "test", trust: trust, accountID: "acct", epoch: .initial
        )!
    }

    private func reading(_ used: Double) -> QuotaMergedReading { QuotaMergedReading(observation(used)) }

    /// Accepts a baseline then an official jump with no local usage.
    private func triggerDrift(_ c: MultiDeviceCompensator, from: Double = 10, to: Double = 30) {
        let previous = reading(from)
        timer.advance(by: 60)
        c.didAccept(observation(to), previous: previous)
    }

    func testDriftBeyondLocalGrowthEntersExternalActiveMode() {
        let c = makeCompensator()
        triggerDrift(c)
        XCTAssertTrue(c.externalActiveModeIsOn)
    }

    func testIncreaseExplainedByLocalUsageDoesNotTrigger() {
        local.growth = 19
        let c = makeCompensator()
        triggerDrift(c)
        XCTAssertFalse(c.externalActiveModeIsOn)
    }

    func testUnknownLocalGrowthDoesNotTrigger() {
        local.growth = nil
        let c = makeCompensator()
        triggerDrift(c)
        XCTAssertFalse(c.externalActiveModeIsOn)
    }

    func testNoLocalEstimatorMeansNoDrift() {
        let c = MultiDeviceCompensator(scheduler: scheduler, localGrowth: nil, timer: timer, now: { [unowned self] in timer.current })
        triggerDrift(c)
        XCTAssertFalse(c.externalActiveModeIsOn)
    }

    func testGradeBAndFirstObservationAreIgnored() {
        let c = makeCompensator()
        c.didAccept(observation(30, trust: .b), previous: reading(10))
        c.didAccept(observation(30), previous: nil)
        XCTAssertFalse(c.externalActiveModeIsOn)
    }

    func testExternalActiveRequestsEveryFiveMinutesAndStopsAfterThirtyMinutes() {
        let c = makeCompensator()
        triggerDrift(c)
        // Keep changing so the unchanged rule never ends the mode.
        for index in 1...5 {
            timer.advance(by: 300)
            c.didAccept(observation(30 + Double(index)), previous: reading(29 + Double(index)))
        }
        XCTAssertEqual(scheduler.reasons.filter { $0 == .externalActivity }.count, 5)
        timer.advance(by: 300)
        XCTAssertFalse(c.externalActiveModeIsOn)
        XCTAssertEqual(scheduler.reasons.filter { $0 == .externalActivity }.count, 5)
    }

    func testExitsAfterTwoConsecutiveUnchangedRequests() {
        let c = makeCompensator()
        triggerDrift(c)
        timer.advance(by: 300)   // request 1
        timer.advance(by: 300)   // unchanged 1, request 2
        XCTAssertTrue(c.externalActiveModeIsOn)
        timer.advance(by: 300)   // unchanged 2 -> exit
        XCTAssertFalse(c.externalActiveModeIsOn)
        XCTAssertEqual(scheduler.reasons.filter { $0 == .externalActivity }.count, 2)
    }

    func testChangeResetsUnchangedCount() {
        let c = makeCompensator()
        triggerDrift(c)
        timer.advance(by: 300)   // request 1
        timer.advance(by: 300)   // unchanged 1, request 2
        c.didAccept(observation(35), previous: reading(30))
        timer.advance(by: 300)   // changed -> count 0, request 3
        timer.advance(by: 300)   // unchanged 1, request 4
        XCTAssertTrue(c.externalActiveModeIsOn)
    }

    func testLeavingDesktopRequestsAfterFiveSeconds() {
        let c = makeCompensator()
        c.foregroundApplicationDidChange(bundleIdentifier: desktop)
        c.foregroundApplicationDidChange(bundleIdentifier: "com.apple.finder")
        timer.advance(by: 4)
        XCTAssertTrue(scheduler.reasons.isEmpty)
        timer.advance(by: 1)
        XCTAssertEqual(scheduler.reasons, [.externalActivity])
    }

    func testReturningToDesktopCancelsPendingRequest() {
        let c = makeCompensator()
        c.foregroundApplicationDidChange(bundleIdentifier: desktop)
        c.foregroundApplicationDidChange(bundleIdentifier: "com.apple.finder")
        timer.advance(by: 2)
        c.foregroundApplicationDidChange(bundleIdentifier: desktop)
        timer.advance(by: 10)
        XCTAssertTrue(scheduler.reasons.isEmpty)
    }

    func testSwitchingBetweenOtherAppsNeverRequests() {
        let c = makeCompensator()
        c.foregroundApplicationDidChange(bundleIdentifier: "com.apple.finder")
        c.foregroundApplicationDidChange(bundleIdentifier: "com.apple.Safari")
        c.foregroundApplicationDidChange(bundleIdentifier: nil)
        timer.advance(by: 60)
        XCTAssertTrue(scheduler.reasons.isEmpty)
    }

    func testStaleOfficialValueRequestsCalibration() {
        let c = makeCompensator()
        c.didAccept(observation(10), previous: nil)
        timer.advance(by: 29 * 60)
        XCTAssertTrue(scheduler.reasons.isEmpty)
        timer.advance(by: 60)
        XCTAssertEqual(scheduler.reasons, [.estimatedCalibration])
    }

    func testFreshOfficialValueRestartsCalibrationWindow() {
        let c = makeCompensator()
        c.didAccept(observation(10), previous: nil)
        timer.advance(by: 20 * 60)
        c.didAccept(observation(11), previous: reading(10))
        timer.advance(by: 20 * 60)
        XCTAssertTrue(scheduler.reasons.isEmpty)
        timer.advance(by: 10 * 60)
        XCTAssertEqual(scheduler.reasons, [.estimatedCalibration])
    }
}
