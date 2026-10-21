import XCTest
@testable import BalanceBar

final class CodexRolloutSourceTests: XCTestCase {
    private var root: URL!
    private var sessions: URL!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private struct FakeAccount: AccountIdentityProviding {
        var accountIdentity: AccountIdentity? = AccountIdentity(stableID: "codex:acct", idSource: .accountUUID)
        var credentialVersion: CredentialVersion? = nil
        var accountEpoch = AccountEpoch(3)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRolloutTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        sessions = root.appendingPathComponent("sessions/2026/10/19", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(offset))
    }

    private func window(_ minutes: Int, _ used: Double, resetsAt: Int = 1_800_003_600) -> String {
        "{\"used_percent\":\(used),\"window_minutes\":\(minutes),\"resets_at\":\(resetsAt)}"
    }

    private func line(at offset: TimeInterval, primary: String, secondary: String) -> String {
        "{\"timestamp\":\"\(iso(offset))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":\(primary),\"secondary\":\(secondary)}}}\n"
    }

    private final class Switchable: AccountIdentityProviding {
        var accountIdentity: AccountIdentity? = AccountIdentity(stableID: "codex:one", idSource: .accountUUID)
        var credentialVersion: CredentialVersion? { nil }
        var accountEpoch: AccountEpoch { .initial }
    }

    private final class MutableNow {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private func appendRollout(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: sessions.appendingPathComponent("rollout-\(name).jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Writes a rollout whose first line is a `session_meta` naming `creator` as the session's creator account.
    @discardableResult
    private func writeRollout(_ name: String, _ text: String, creator: String? = "acct-1") throws -> URL {
        let url = sessions.appendingPathComponent("rollout-\(name).jsonl")
        var meta = "{\"timestamp\":\"\(iso(-60))\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(name)\""
        if let creator { meta += ",\"creator_account_id\":\"\(creator)\"" }
        meta += "}}\n"
        try Data((meta + text).utf8).write(to: url)
        return url
    }

    /// `currentAccountID` is the signed-in ChatGPT account; only files created by it are attributed.
    private func makeSource(account: FakeAccount = FakeAccount(), currentAccountID: String? = "acct-1") -> CodexRolloutSource {
        CodexRolloutSource(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            accountProvider: account,
            configuration: CodexRolloutConfiguration(maximumFileAge: .infinity),
            now: { self.base.addingTimeInterval(100) },
            currentAccountID: { currentAccountID }
        )
    }

    private func scan(_ source: CodexRolloutSource, paths: Set<String>? = nil) -> [QuotaObservation] {
        var result: [QuotaObservation] = []
        source.rescan(paths: paths) { result.append($0) }
        return result
    }

    func testNewestEventAcrossFilesWins() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)))
        try writeRollout("b", line(at: 50, primary: window(300, 30), secondary: window(10080, 40)))
        try writeRollout("c", line(at: 20, primary: window(300, 99), secondary: window(10080, 99)))
        let observations = scan(makeSource())
        let byWindow = Dictionary(uniqueKeysWithValues: observations.map { ($0.window, $0) })
        XCTAssertEqual(byWindow[.fiveHour]?.usedPercentage, 30)
        XCTAssertEqual(byWindow[.sevenDay]?.usedPercentage, 40)
        XCTAssertEqual(byWindow[.fiveHour]?.observedAt, base.addingTimeInterval(50))
        XCTAssertEqual(byWindow[.fiveHour]?.trust, .a)
        XCTAssertEqual(byWindow[.fiveHour]?.source, "codex-rollout")
        XCTAssertEqual(byWindow[.fiveHour]?.accountID, "codex:acct")
        XCTAssertEqual(byWindow[.fiveHour]?.epoch, AccountEpoch(3))
        XCTAssertEqual(byWindow[.fiveHour]?.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
    }

    func testLargeRolloutIsScannedFromItsTailAndStillFollowedAfterwards() throws {
        // 6 MB of unrelated lines after an early event, then a late event inside the final 4 MB window.
        let filler = String(repeating: "{\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 900) + "\"}}\n", count: 6_500)
        let early = line(at: 10, primary: window(300, 11), secondary: window(10080, 22))
        let late = line(at: 90, primary: window(300, 33), secondary: window(10080, 44))
        let url = try writeRollout("big", early + filler + late)
        XCTAssertGreaterThan(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize), 6_000_000)
        let source = makeSource()
        let observations = scan(source)
        let byWindow = Dictionary(uniqueKeysWithValues: observations.map { ($0.window, $0) })
        XCTAssertEqual(byWindow[.fiveHour]?.usedPercentage, 33, "the newest event is found in the tail")
        XCTAssertEqual(byWindow[.sevenDay]?.usedPercentage, 44)

        // New lines appended later are read incrementally.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(at: 95, primary: window(300, 55), secondary: window(10080, 66)).utf8))
        try handle.close()
        let later = scan(source, paths: [url.path])
        XCTAssertEqual(later.first { $0.window == .fiveHour }?.usedPercentage, 55)
    }

    func testEventOnlyBeforeTheTailWindowOfALargeRolloutIsNotReadSoTheServerIsAsked() throws {
        let filler = String(repeating: "{\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 900) + "\"}}\n", count: 6_500)
        try writeRollout("big-old", line(at: 10, primary: window(300, 11), secondary: window(10080, 22)) + filler)
        XCTAssertTrue(scan(makeSource()).isEmpty, "no event in the tail: no reading, the ordinary request logic applies")
    }

    func testWindowClassificationIgnoresPrimarySecondaryOrder() throws {
        try writeRollout("a", line(at: 10, primary: window(10080, 70), secondary: window(300, 15)))
        let byWindow = Dictionary(uniqueKeysWithValues: scan(makeSource()).map { ($0.window, $0) })
        XCTAssertEqual(byWindow[.fiveHour]?.usedPercentage, 15)
        XCTAssertEqual(byWindow[.sevenDay]?.usedPercentage, 70)
    }

    func testUnknownWindowIsPreservedAsOther() {
        XCTAssertEqual(CodexRolloutParser.windowKind(forMinutes: 60), .other("window_60m"))
    }

    func testIncrementalAppendEmitsOnlyNewerEvents() throws {
        let url = try writeRollout("a", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)))
        let source = makeSource()
        XCTAssertEqual(scan(source).count, 2)
        XCTAssertTrue(scan(source, paths: [url.path]).isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(at: 60, primary: window(300, 11), secondary: window(10080, 21)).utf8))
        try handle.close()
        let updated = scan(source, paths: [url.path])
        XCTAssertEqual(updated.map(\.usedPercentage).sorted(), [11, 21])
    }

    func testRelativeResetAndIgnoredLines() throws {
        let relative = "{\"timestamp\":\"\(iso(10))\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":5,\"window_minutes\":300,\"resets_in_seconds\":600}}}}\n"
        let nullLimits = "{\"timestamp\":\"\(iso(20))\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n"
        let other = "{\"timestamp\":\"\(iso(30))\",\"payload\":{\"type\":\"agent_message\",\"rate_limits\":{}}}\nnot json rate_limits\n"
        try writeRollout("a", relative + nullLimits + other)
        let observations = scan(makeSource())
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].resetsAt, base.addingTimeInterval(610))
    }

    func testOutOfRangePercentIsDropped() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 150), secondary: window(10080, 20)))
        XCTAssertEqual(scan(makeSource()).map(\.window), [.sevenDay])
    }

    func testNoAccountEmitsNothingAndDoesNotConsumeEvent() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)))
        XCTAssertTrue(scan(makeSource(account: FakeAccount(accountIdentity: nil))).isEmpty)
    }

    func testFreshnessReflectsLatestEventAge() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)))
        let source = makeSource()
        XCTAssertFalse(source.hasFreshData(at: base.addingTimeInterval(20)))
        _ = scan(source)
        XCTAssertTrue(source.hasFreshData(at: base.addingTimeInterval(20)))
        XCTAssertFalse(source.hasFreshData(at: base.addingTimeInterval(10 + QuotaConstants.realtimeSourceFreshness + 1)))
    }

    func testCodexHomeSelectsSessionsDirectory() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(
            CodexRolloutSource.sessionsDirectory(environment: ["CODEX_HOME": "/tmp/custom"], homeDirectory: home).path,
            "/tmp/custom/sessions"
        )
        XCTAssertEqual(
            CodexRolloutSource.sessionsDirectory(environment: [:], homeDirectory: home).path,
            "/Users/tester/.codex/sessions"
        )
        XCTAssertEqual(
            CodexRolloutSource.sessionsDirectory(environment: ["CODEX_HOME": "  "], homeDirectory: home).path,
            "/Users/tester/.codex/sessions"
        )
    }

    func testRolloutOutsideSessionsDirectoryIsRejected() throws {
        let outside = root.appendingPathComponent("rollout-x.jsonl")
        try Data(line(at: 10, primary: window(300, 10), secondary: window(10080, 20)).utf8).write(to: outside)
        XCTAssertTrue(scan(makeSource(), paths: [outside.path]).isEmpty)
    }

    func testZeroAndOnePercentAreParsed() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 0), secondary: window(10080, 1)))
        let byWindow = Dictionary(uniqueKeysWithValues: scan(makeSource()).map { ($0.window, $0) })
        XCTAssertEqual(byWindow[.fiveHour]?.usedPercentage, 0)
        XCTAssertEqual(byWindow[.sevenDay]?.usedPercentage, 1)
    }

    func testBooleanPercentIsRejected() {
        let text = "{\"timestamp\":\"\(iso(10))\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":true,\"window_minutes\":300}}}}"
        XCTAssertNil(CodexRolloutParser.parse(line: Data(text.utf8)))
    }

    func testInvalidOrUnattributedDataIsNotFresh() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 150), secondary: window(10080, 150)))
        let invalid = makeSource()
        _ = scan(invalid)
        XCTAssertFalse(invalid.hasFreshData(at: base.addingTimeInterval(20)))

        let url = root.appendingPathComponent("sessions/2026/10/19/rollout-b.jsonl")
        try Data(line(at: 10, primary: window(300, 10), secondary: window(10080, 20)).utf8).write(to: url)
        let noAccount = makeSource(account: FakeAccount(accountIdentity: nil))
        _ = scan(noAccount)
        XCTAssertFalse(noAccount.hasFreshData(at: base.addingTimeInterval(20)))
    }

    func testFreshnessIsInvalidatedWhenAccountChanges() throws {
        try writeRollout("a", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)))
        let account = Switchable()
        let source = CodexRolloutSource(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            accountProvider: account,
            configuration: CodexRolloutConfiguration(maximumFileAge: .infinity),
            now: { self.base.addingTimeInterval(100) },
            currentAccountID: { "acct-1" }
        )
        _ = scan(source)
        XCTAssertTrue(source.hasFreshData(at: base.addingTimeInterval(20)))
        account.accountIdentity = AccountIdentity(stableID: "codex:two", idSource: .accountUUID)
        XCTAssertFalse(source.hasFreshData(at: base.addingTimeInterval(20)))
    }

    func testASessionCreatedByAnotherLoginIsNeverAttributedEvenWhileItKeepsWriting() throws {
        // A's session, still running: before and after the switch to B (the current account) it writes events.
        let url = try writeRollout("a", line(at: 10, primary: window(300, 80), secondary: window(10080, 20)), creator: "acct-A")
        let source = makeSource(currentAccountID: "acct-B")
        XCTAssertTrue(scan(source).isEmpty, "cold start: A's fresh log is not B's")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(at: 30, primary: window(300, 81), secondary: window(10080, 21))
                                           + line(at: 31, primary: window(300, 82), secondary: window(10080, 21))).utf8))
        try handle.close()
        XCTAssertTrue(scan(source, paths: [url.path]).isEmpty, "A's session writing after the switch is still A's")
        XCTAssertFalse(source.hasFreshData(at: base.addingTimeInterval(40)))
        // B's own session is attributed.
        try writeRollout("b", line(at: 50, primary: window(300, 10), secondary: window(10080, 5)), creator: "acct-B")
        let seen = scan(source)
        XCTAssertEqual(seen.compactMap { $0.window == .fiveHour ? $0.usedPercentage : nil }, [10])
        XCTAssertTrue(source.hasFreshData(at: base.addingTimeInterval(60)))
    }

    func testALoginSwitchWhileScanningNeverHandsTheOldLoginsReadingsToTheNewLogin() throws {
        // The identity provider reports login A while the scan starts and login B by the time it would publish.
        final class FlippingAccount: AccountIdentityProviding {
            private let lock = NSLock()
            private var reads = 0
            var flipped: Bool { lock.withLock { reads >= 2 } }
            var accountIdentity: AccountIdentity? {
                lock.withLock { reads += 1 }
                return AccountIdentity(stableID: flipped ? "codex:b" : "codex:a", idSource: .accountUUID)
            }
            var credentialVersion: CredentialVersion? { nil }
            var accountEpoch: AccountEpoch { .initial }
        }
        try writeRollout("a", line(at: 10, primary: window(300, 80), secondary: window(10080, 20)), creator: "acct-A")
        let account = FlippingAccount()
        let source = CodexRolloutSource(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            accountProvider: account,
            configuration: CodexRolloutConfiguration(maximumFileAge: .infinity),
            now: { self.base.addingTimeInterval(100) },
            currentAccountID: { account.flipped ? "acct-B" : "acct-A" })
        XCTAssertTrue(scan(source).isEmpty, "A's readings were filtered for A; B is signed in by the time they would be published")
        XCTAssertFalse(source.hasFreshData(at: base.addingTimeInterval(20)))
    }

    func testALogWithoutACreatorAccountIsNotAttributed() throws {
        try writeRollout("old", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)), creator: nil)
        XCTAssertTrue(scan(makeSource()).isEmpty, "older Codex versions fall back to the server")
    }

    func testTheSameLoginsOwnSessionIsAttributedFromTheFirstScanAndAnIncompleteFirstLineIsWaitedFor() throws {
        let url = sessions.appendingPathComponent("rollout-new.jsonl")
        // The first line is still being written: no end of line yet.
        try Data("{\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"acct-1\"".utf8).write(to: url)
        let source = makeSource()
        XCTAssertTrue(scan(source).isEmpty)
        // Completed later (not cached as "no creator"), then attributed.
        try Data(("{\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"acct-1\"}}\n"
                  + line(at: 10, primary: window(300, 10), secondary: window(10080, 20))).utf8).write(to: url)
        XCTAssertEqual(scan(source).count, 2, "both windows, from the login's own file logged before launch")
    }

    func testAVeryLongFirstLineStillNamesItsCreator() throws {
        let filler = String(repeating: "x", count: 100_000)
        let url = sessions.appendingPathComponent("rollout-long.jsonl")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"acct-1\",\"base_instructions\":{\"text\":\"\(filler)\"}}}\n"
        try Data((meta + line(at: 10, primary: window(300, 10), secondary: window(10080, 20))).utf8).write(to: url)
        XCTAssertEqual(scan(makeSource()).count, 2)
    }

    func testStartAndStopLifecycleDeliversAppendedEvents() throws {
        let url = try writeRollout("live", line(at: 10, primary: window(300, 10), secondary: window(10080, 20)))
        let source = CodexRolloutSource(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            accountProvider: FakeAccount(),
            configuration: CodexRolloutConfiguration(maximumFileAge: .infinity),
            ioConfiguration: QuotaIOConfiguration(watchCoalescingInterval: 0.1),
            now: { self.base.addingTimeInterval(100) },
            currentAccountID: { "acct-1" }
        )
        let lock = NSLock()
        var received: [QuotaObservation] = []
        let initial = expectation(description: "initial scan")
        initial.expectedFulfillmentCount = 2
        let appended = expectation(description: "appended event")
        appended.expectedFulfillmentCount = 2
        source.start { observation in
            lock.lock(); received.append(observation); let count = received.count; lock.unlock()
            if count <= 2 { initial.fulfill() } else { appended.fulfill() }
        }
        wait(for: [initial], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5) // let the FSEvents stream settle
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(at: 60, primary: window(300, 11), secondary: window(10080, 21)).utf8))
        try handle.close()
        wait(for: [appended], timeout: 10)
        source.stop()
        source.stop()
    }
}
