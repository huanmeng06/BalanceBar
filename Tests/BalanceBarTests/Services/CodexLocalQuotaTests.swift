import XCTest
@testable import BalanceBar

private final class MutableProfile {
    private let lock = NSLock()
    private var value: CodexAccountProfile?
    private(set) var reads = 0
    init(_ email: String?) { value = email.map { CodexAccountProfile(email: $0, planType: "plus") } }
    func set(_ email: String?) { lock.withLock { value = email.map { CodexAccountProfile(email: $0, planType: "plus") } } }
    func read() -> CodexAccountProfile? { lock.withLock { reads += 1; return value } }
}

private final class MutableDate {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

final class CodexAccountIdentityProviderTests: XCTestCase {
    func testIdentityComesFromTheLoginEmailAndTheEpochAdvancesOnlyWhenItChanges() {
        let profile = MutableProfile("Me@Example.com ")
        let clock = MutableDate(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = CodexAccountIdentityProvider(readProfile: profile.read, refreshInterval: 2, now: { clock.now })
        XCTAssertEqual(provider.accountIdentity?.stableID, "codex:me@example.com")
        XCTAssertEqual(provider.accountIdentity?.email, "me@example.com")
        XCTAssertEqual(provider.accountEpoch, .initial)

        clock.advance(by: 3)
        XCTAssertEqual(provider.accountEpoch, .initial, "re-reading the same login keeps the epoch")

        profile.set("other@example.com")
        clock.advance(by: 3)
        XCTAssertEqual(provider.accountIdentity?.stableID, "codex:other@example.com")
        XCTAssertEqual(provider.accountEpoch, AccountEpoch(1))

        profile.set(nil)
        clock.advance(by: 3)
        XCTAssertNil(provider.accountIdentity, "signed out: nobody to attribute a reading to")
        XCTAssertEqual(provider.accountEpoch, AccountEpoch(2))
    }

    func testTheLoginFileIsReadAtMostOncePerInterval() {
        let profile = MutableProfile("me@example.com")
        let clock = MutableDate(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = CodexAccountIdentityProvider(readProfile: profile.read, refreshInterval: 2, now: { clock.now })
        for _ in 0..<50 { _ = provider.accountIdentity; _ = provider.accountEpoch }
        XCTAssertEqual(profile.reads, 1)
        clock.advance(by: 2.5)
        _ = provider.accountIdentity
        XCTAssertEqual(profile.reads, 2)
    }
}

final class CodexLocalQuotaTests: XCTestCase {
    private var root: URL!
    private var sessions: URL!
    private var state: URL!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var created: [CodexLocalQuota] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLocalQuotaTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        sessions = root.appendingPathComponent("sessions/2026/10/19", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        created.forEach { $0.stop() }
        created.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(offset))
    }

    private func line(at offset: TimeInterval, fiveHourUsed: Double, sevenDayUsed: Double,
                      fiveHourReset: Int = 1_800_010_000, sevenDayReset: Int = 1_800_400_000) -> String {
        let primary = "{\"used_percent\":\(fiveHourUsed),\"window_minutes\":300,\"resets_at\":\(fiveHourReset)}"
        let secondary = "{\"used_percent\":\(sevenDayUsed),\"window_minutes\":10080,\"resets_at\":\(sevenDayReset)}"
        return "{\"timestamp\":\"\(iso(offset))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":\(primary),\"secondary\":\(secondary)}}}\n"
    }

    private func writeRollout(_ text: String, name: String = "a") throws {
        try Data(text.utf8).write(to: sessions.appendingPathComponent("rollout-\(name).jsonl"))
    }

    private func makeLocal(
        email: String? = "me@example.com", clock: MutableDate
    ) -> (local: CodexLocalQuota, profile: MutableProfile) {
        let profile = MutableProfile(email)
        let identity = CodexAccountIdentityProvider(readProfile: profile.read, refreshInterval: 0.01, now: { clock.now })
        let source = CodexRolloutSource(
            sessionsDirectory: root.appendingPathComponent("sessions"), accountProvider: identity,
            configuration: CodexRolloutConfiguration(maximumFileAge: .infinity), now: { clock.now })
        let local = CodexLocalQuota(identity: identity, source: source, stateDirectory: state, now: { clock.now })
        created.append(local)
        return (local, profile)
    }

    private func waitForDisplay(_ local: CodexLocalQuota, accountKey: String? = "me@example.com",
                                file: StaticString = #filePath, line: UInt = #line) -> QuotaDisplayModel? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let model = local.freshDisplay(accountKey: accountKey) { return model }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("the local log never produced a fresh display", file: file, line: line)
        return nil
    }

    func testFreshLogForTheLoginProducesMergedWindows() throws {
        try writeRollout(line(at: 0, fiveHourUsed: 30, sevenDayUsed: 10))
        let clock = MutableDate(base.addingTimeInterval(30))
        let (local, _) = makeLocal(clock: clock)
        XCTAssertNil(local.freshDisplay(accountKey: "me@example.com"), "nothing before the source has started")
        local.start()
        let model = try XCTUnwrap(waitForDisplay(local))
        XCTAssertEqual(model.windows.first { $0.kind == .fiveHour }?.usedPercentage, 30)
        XCTAssertEqual(model.windows.first { $0.kind == .sevenDay }?.usedPercentage, 10)
    }

    func testStaleLogOtherLoginAndSignedOutAccountsGetNoDisplay() throws {
        try writeRollout(line(at: 0, fiveHourUsed: 30, sevenDayUsed: 10))
        let clock = MutableDate(base.addingTimeInterval(30))
        let (local, profile) = makeLocal(clock: clock)
        local.start()
        _ = try XCTUnwrap(waitForDisplay(local))

        XCTAssertNil(local.freshDisplay(accountKey: "someone-else@example.com"), "the log belongs to the signed-in login only")
        XCTAssertNil(local.freshDisplay(accountKey: nil))

        clock.advance(by: 200)
        XCTAssertNil(local.freshDisplay(accountKey: "me@example.com"), "an event older than two minutes does not answer a refresh")

        clock.advance(by: -200)
        profile.set(nil)
        clock.advance(by: 1)
        XCTAssertNil(local.freshDisplay(accountKey: "me@example.com"), "signed out")
    }

    func testAPassedResetTimeSendsTheRefreshToTheServer() throws {
        // 5-hour window resets at +10_000 s; the event itself is fresh but the reset time has passed.
        try writeRollout(line(at: 9_990, fiveHourUsed: 30, sevenDayUsed: 10, fiveHourReset: 1_800_010_000))
        let clock = MutableDate(base.addingTimeInterval(9_995))
        let (local, _) = makeLocal(clock: clock)
        local.start()
        _ = try XCTUnwrap(waitForDisplay(local))
        clock.advance(by: 20) // past the reset time, still inside the two-minute freshness
        XCTAssertNil(local.freshDisplay(accountKey: "me@example.com"),
                     "only an official reading can confirm a reset")
    }

    func testAccountSwitchDropsTheOldLoginsReadings() throws {
        try writeRollout(line(at: 0, fiveHourUsed: 30, sevenDayUsed: 10))
        let clock = MutableDate(base.addingTimeInterval(30))
        let (local, profile) = makeLocal(clock: clock)
        local.start()
        _ = try XCTUnwrap(waitForDisplay(local))

        profile.set("other@example.com")
        clock.advance(by: 1)
        let switched = local.freshDisplay(accountKey: "other@example.com")
        XCTAssertNil(switched, "the previous login's log is not attributed to the new login")
    }

    func testOverlayReplacesPercentagesAndResetTimesButKeepsWhatALogCannotCarry() throws {
        let now = base
        let fiveHour = OfficialQuotaWindow(kind: .fiveHour, remaining: 90, label: "5h", daysText: "5 hours",
                                           reset: "old", durationSeconds: 18_000, resetAt: now.addingTimeInterval(600))
        let sevenDay = OfficialQuotaWindow(kind: .sevenDay, remaining: 80, label: "7d", daysText: "7 days",
                                           reset: "old", durationSeconds: 604_800, resetAt: now.addingTimeInterval(86_400))
        let other = OfficialQuotaWindow(kind: .other, remaining: 55, label: "extra", daysText: "n/a", reset: nil,
                                        durationSeconds: nil)
        let card = CodexBankedResetCard(id: "c", resetType: "codex_rate_limits", titleText: "t", expiresAt: nil, expiresText: nil)
        let output = OfficialQuotaResponseParser.Output(windows: [fiveHour, sevenDay, other])
        let display = QuotaDisplayModel(
            windows: [
                QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 40, resetsAt: now.addingTimeInterval(3_600),
                                   isEstimated: false, state: .inProgress, hoverTextKey: "x"),
                QuotaWindowDisplay(kind: .sevenDay, usedPercentage: 25, resetsAt: nil,
                                   isEstimated: false, state: .inProgress, hoverTextKey: "x")
            ], isEstimated: false, state: .inProgress, hoverTextKey: "x")

        let overlaid = try XCTUnwrap(output.overlaid(with: display, now: now, bankedReset: CodexBankedReset(cards: [card])))
        XCTAssertEqual(overlaid.windows.map(\.remaining), [60, 75, 55])
        XCTAssertEqual(overlaid.windows[0].resetAt, now.addingTimeInterval(3_600))
        XCTAssertNotEqual(overlaid.windows[0].reset, "old")
        XCTAssertEqual(overlaid.windows[1].resetAt, now.addingTimeInterval(86_400), "a log without a reset time keeps the last known one")
        XCTAssertEqual(overlaid.windows[2], other)
        XCTAssertEqual(overlaid.windows.map(\.label), ["5h", "7d", "extra"])
        XCTAssertEqual(overlaid.bankedReset?.availableCount, 1)
        XCTAssertFalse(overlaid.bankedResetNeedsCreditList)
    }

    func testOverlayWithoutAMatchingWindowReturnsNil() {
        let other = OfficialQuotaWindow(kind: .other, remaining: 55, label: "extra", daysText: "n/a", reset: nil, durationSeconds: nil)
        let display = QuotaDisplayModel(
            windows: [QuotaWindowDisplay(kind: .fiveHour, usedPercentage: 40, isEstimated: false,
                                         state: .inProgress, hoverTextKey: "x")],
            isEstimated: false, state: .inProgress, hoverTextKey: "x")
        XCTAssertNil(OfficialQuotaResponseParser.Output(windows: [other]).overlaid(with: display, now: base, bankedReset: nil))
    }
}
