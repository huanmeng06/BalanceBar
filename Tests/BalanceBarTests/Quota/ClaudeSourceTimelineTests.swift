import XCTest
@testable import BalanceBar

final class ClaudeSourceTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTimeline(
        validity: @escaping () -> ClaudeSourceValidity = { .defaults }, now: @escaping () -> Date
    ) -> ClaudeSourceTimeline {
        ClaudeSourceTimeline(validity: validity, now: now)
    }

    func testPairedWindowObservationsBecomeOneReadingWithTheValidityAtThatMoment() {
        let timeline = makeTimeline(now: { self.start })
        var changes = 0
        timeline.onChange = { changes += 1 }
        timeline.recordReading(source: .mod, observedAt: start)
        timeline.recordReading(source: .mod, observedAt: start.addingTimeInterval(0.4))
        timeline.recordReading(source: .oauthAPI, observedAt: start)
        let readings = timeline.snapshot().readings
        XCTAssertEqual(readings.map(\.source), [.mod, .oauthAPI])
        XCTAssertEqual(readings.first?.expiresAt, start.addingTimeInterval(ClaudeSourceValidity.defaults.mod))
        XCTAssertEqual(changes, 2, "the duplicate 7d half of a pair is not a change")
    }

    func testPairedWindowValuesAndDisplayDispositionStayWithTheReading() {
        let timeline = makeTimeline(now: { self.start })
        timeline.recordReading(
            source: .mod, observedAt: start,
            values: [.fiveHour: .init(usedPercentage: 41, resetAt: start.addingTimeInterval(900))],
            dispositions: [.fiveHour: .freshnessEvidenceWithinTolerance])
        timeline.recordReading(
            source: .mod, observedAt: start.addingTimeInterval(0.4),
            values: [.sevenDay: .init(usedPercentage: 67, resetAt: start.addingTimeInterval(86_400))],
            dispositions: [.sevenDay: .displayed])

        let reading = try! XCTUnwrap(timeline.snapshot().readings.first)
        XCTAssertEqual(reading.windows[.fiveHour]?.usedPercentage, 41)
        XCTAssertEqual(reading.windows[.fiveHour]?.resetAt, start.addingTimeInterval(900))
        XCTAssertEqual(reading.windows[.sevenDay]?.usedPercentage, 67)
        XCTAssertEqual(reading.dispositions, [
            .fiveHour: .freshnessEvidenceWithinTolerance,
            .sevenDay: .displayed,
        ])
    }

    func testRequestsKeepDispatchCompletionTriggerAndOutcome() {
        let timeline = makeTimeline(now: { self.start.addingTimeInterval(20) })
        let started = start.addingTimeInterval(1)
        let completed = start.addingTimeInterval(5)
        timeline.recordRequestDispatched(trigger: .sourceExpiryPrefetch, at: started, sourceExpiryAt: start.addingTimeInterval(10))
        timeline.recordRequestCompleted(
            trigger: .sourceExpiryPrefetch, startedAt: started, completedAt: completed,
            outcome: .failure(.rateLimited))
        XCTAssertEqual(timeline.snapshot().requests, [
            .init(trigger: .sourceExpiryPrefetch, startedAt: started, completedAt: completed,
                  outcome: .failure(.rateLimited), sourceExpiryAt: start.addingTimeInterval(10))
        ])
    }

    func testReadingsStaySortedWhenAnOlderSnapshotArrivesLate() {
        let timeline = makeTimeline(now: { self.start.addingTimeInterval(60) })
        timeline.recordReading(source: .mod, observedAt: start.addingTimeInterval(30))
        timeline.recordReading(source: .mod, observedAt: start.addingTimeInterval(10))
        XCTAssertEqual(timeline.snapshot().readings.map(\.observedAt), [10, 30].map { start.addingTimeInterval($0) })
    }

    func testValidityChangeOnlyReachesReadingsThatAreStillValid() {
        var now = start
        var validity = ClaudeSourceValidity.defaults
        let timeline = makeTimeline(validity: { validity }, now: { now })
        timeline.recordReading(source: .mod, observedAt: start)                          // valid until +120
        timeline.recordReading(source: .mod, observedAt: start.addingTimeInterval(200))  // valid until +320
        now = start.addingTimeInterval(250)

        validity.mod = 300
        timeline.validityChanged()
        var readings = timeline.snapshot().readings
        XCTAssertEqual(readings[0].expiresAt, start.addingTimeInterval(120), "an expired reading keeps its length")
        XCTAssertEqual(readings[1].expiresAt, start.addingTimeInterval(500), "a live reading follows the longer setting")

        validity.mod = 30
        timeline.validityChanged()
        readings = timeline.snapshot().readings
        XCTAssertEqual(readings[1].expiresAt, now, "a shorter setting that already elapsed ends the reading now")
        XCTAssertEqual(readings[0].expiresAt, start.addingTimeInterval(120))
    }

    func testFailureRunSplitsOnANewKindAndEndsOnTheNextOfficialRead() {
        let timeline = makeTimeline(now: { self.start.addingTimeInterval(600) })
        timeline.recordFailure(.network, at: start)
        timeline.recordFailure(.network, at: start.addingTimeInterval(60))
        timeline.recordFailure(.rateLimited, at: start.addingTimeInterval(120))
        XCTAssertEqual(timeline.snapshot().failures, [
            ClaudeSourceTimeline.FailureRun(start: start, end: start.addingTimeInterval(120), kind: .network),
            ClaudeSourceTimeline.FailureRun(start: start.addingTimeInterval(120), end: nil, kind: .rateLimited)
        ], "a new category closes the earlier run instead of rewriting it")
        timeline.recordOfficialSuccess(at: start.addingTimeInterval(300))
        let snapshot = timeline.snapshot()
        XCTAssertEqual(snapshot.failures.last?.end, start.addingTimeInterval(300))
        XCTAssertEqual(snapshot.readings.map(\.source), [.oauthAPI])

        timeline.recordFailure(.unauthorized, at: start.addingTimeInterval(400))
        XCTAssertEqual(timeline.snapshot().failures.count, 3, "a failure after a success opens a new run")
    }

    func testFailureKindsAreGroupedForDisplay() {
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.transport(possibleProxy: true, description: "x")), .network)
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.http(429)), .rateLimited)
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.rateLimited), .rateLimited)
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.unauthorized), .unauthorized)
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.http(500)), .serverError)
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.invalidResponse), .serverError)
        XCTAssertEqual(ClaudeSourceTimeline.FailureKind(.missingCredentials), .missingCredentials)
    }

    // MARK: Persistence

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSourceTimelineTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("claude-source-timeline.json")
    }

    func testHistoryComesBackAfterARelaunchForTheSameAccount() throws {
        let file = try temporaryFile()
        var now = start
        let key = ClaudeSourceTimeline.accountKey(forStableID: "account-a|org")
        let first = ClaudeSourceTimeline(now: { now }, fileURL: file, saveDelay: 60)
        first.restore(accountKey: key)
        first.recordReading(source: .mod, observedAt: start)
        first.recordFailure(.network, at: start.addingTimeInterval(30))
        now = start.addingTimeInterval(60)
        first.flushPendingSave()

        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(stored.contains("account-a"), "the file keeps only a hash of the stable ID")

        now = start.addingTimeInterval(600)
        let relaunched = ClaudeSourceTimeline(now: { now }, fileURL: file, saveDelay: 60)
        var changes = 0
        relaunched.onChange = { changes += 1 }
        relaunched.restore(accountKey: key)
        let snapshot = relaunched.snapshot()
        XCTAssertEqual(snapshot.readings, [
            ClaudeSourceTimeline.Reading(source: .mod, observedAt: start, expiresAt: start.addingTimeInterval(120))
        ])
        XCTAssertEqual(snapshot.failures, [
            ClaudeSourceTimeline.FailureRun(start: start.addingTimeInterval(30), end: start.addingTimeInterval(60), kind: .network)
        ], "a run still open at quit ends at the last save, not at the relaunch")
        XCTAssertEqual(changes, 1)
    }

    func testRequestValuesRoundTripAndLegacyHistoryIsIgnored() throws {
        let file = try temporaryFile()
        let key = ClaudeSourceTimeline.accountKey(forStableID: "account-a|org")!
        let timeline = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        timeline.restore(accountKey: key)
        timeline.recordReading(
            source: .oauthAPI, observedAt: start,
            values: [.fiveHour: .init(usedPercentage: 24.5, resetAt: start.addingTimeInterval(1_800))],
            dispositions: [.fiveHour: .displayed])
        timeline.recordRequestDispatched(trigger: .calibrationFloor, at: start, sourceExpiryAt: nil)
        timeline.recordRequestCompleted(
            trigger: .calibrationFloor, startedAt: start, completedAt: start.addingTimeInterval(3),
            outcome: .success,
            values: [.fiveHour: .init(usedPercentage: 24.5, resetAt: start.addingTimeInterval(1_800))],
            dispositions: [.fiveHour: .displayed])
        timeline.flushPendingSave()

        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(stored.contains("24.5"))
        XCTAssertFalse(stored.contains("account-a"))
        let restored = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        restored.restore(accountKey: key)
        XCTAssertEqual(restored.snapshot().readings.first?.windows[.fiveHour]?.usedPercentage, 24.5)
        XCTAssertEqual(restored.snapshot().requests.first?.trigger, .calibrationFloor)
        XCTAssertEqual(restored.snapshot().requests.first?.outcome, .success)

        try Data(#"{"version":1,"accountKey":"\#(key)","savedAt":1800000000,"readings":[],"failures":[]}"#.utf8).write(to: file)
        let legacy = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        legacy.restore(accountKey: key)
        XCTAssertEqual(legacy.snapshot(), .empty, "version 1 history is safely ignored after the privacy-format upgrade")
    }

    func testAnotherAccountNeverSeesTheSavedHistory() throws {
        let file = try temporaryFile()
        let first = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        first.restore(accountKey: ClaudeSourceTimeline.accountKey(forStableID: "account-a|org"))
        first.recordReading(source: .oauthAPI, observedAt: start)
        first.flushPendingSave()

        let other = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        other.restore(accountKey: ClaudeSourceTimeline.accountKey(forStableID: "account-b|org"))
        XCTAssertEqual(other.snapshot(), .empty)
        let signedOut = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        signedOut.restore(accountKey: nil)
        XCTAssertEqual(signedOut.snapshot(), .empty, "no account, no history")
    }

    func testAccountSwitchRewritesTheFileSoTheOldHistoryStaysGone() throws {
        let file = try temporaryFile()
        let keyA = ClaudeSourceTimeline.accountKey(forStableID: "account-a|org")
        let keyB = ClaudeSourceTimeline.accountKey(forStableID: "account-b|org")
        let timeline = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        timeline.restore(accountKey: keyA)
        timeline.recordReading(source: .oauthAPI, observedAt: start)
        timeline.flushPendingSave()
        timeline.reset(accountKey: keyB)
        timeline.flushPendingSave()

        let relaunchedAsA = ClaudeSourceTimeline(now: { self.start }, fileURL: file, saveDelay: 60)
        relaunchedAsA.restore(accountKey: keyA)
        XCTAssertEqual(relaunchedAsA.snapshot(), .empty)
    }

    func testOldEntriesArePrunedAndResetClearsEverything() {
        var now = start
        let timeline = makeTimeline(now: { now })
        timeline.recordReading(source: .mod, observedAt: start)
        timeline.recordFailure(.network, at: start)
        timeline.recordOfficialSuccess(at: start.addingTimeInterval(10))
        now = start.addingTimeInterval(ClaudeSourceTimeline.retention + 200)
        let pruned = timeline.snapshot()
        XCTAssertTrue(pruned.failures.isEmpty)
        XCTAssertEqual(pruned.readings.map(\.source), [.oauthAPI], "the 10-minute official reading is still in range")

        var changes = 0
        timeline.onChange = { changes += 1 }
        timeline.reset()
        XCTAssertEqual(timeline.snapshot(), .empty)
        timeline.reset()
        XCTAssertEqual(changes, 1, "clearing an empty history is not a change")
    }
}
